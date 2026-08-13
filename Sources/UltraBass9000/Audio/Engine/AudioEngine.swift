import CoreAudio
import Foundation
import Observation
import os

enum EngineStatus: Equatable {
    case idle
    case starting
    case running
    case failed(String)

    var isActive: Bool {
        switch self {
        case .running, .starting: return true
        case .idle, .failed: return false
        }
    }
}

/// Non-fatal conditions worth surfacing rather than logging into the void.
enum EngineDiagnostic: Equatable, Identifiable {
    /// The tap has produced nothing but digital silence for long enough that a denied
    /// audio-capture permission is the likeliest explanation. Core Audio offers no way to ask.
    case permissionLikelyDenied
    case noOutputsSelected
    case deviceDisappeared(String)

    var id: String {
        switch self {
        case .permissionLikelyDenied: return "permission"
        case .noOutputsSelected: return "no-outputs"
        case .deviceDisappeared(let name): return "gone-\(name)"
        }
    }

    var title: String {
        switch self {
        case .permissionLikelyDenied: return "No audio is reaching UltraBass"
        case .noOutputsSelected: return "Pick at least one output"
        case .deviceDisappeared(let name): return "\(name) disappeared"
        }
    }

    var detail: String {
        switch self {
        case .permissionLikelyDenied:
            return "The system tap is returning silence. Grant UltraBass 9000 audio recording access in System Settings › Privacy & Security › Microphone, then start again."
        case .noOutputsSelected:
            return "Choose the devices you want to play to in the sidebar."
        case .deviceDisappeared(let name):
            return "\(name) was removed from the output set because it is no longer connected."
        }
    }
}

/// Owns the capture → process → fan-out pipeline and everything the UI binds to.
@MainActor
@Observable
final class AudioEngine {

    let registry: AudioDeviceRegistry

    private(set) var status: EngineStatus = .idle
    private(set) var diagnostics: [EngineDiagnostic] = []

    /// Ordered. Index 0 becomes the aggregate's clock source, so the order is meaningful and the
    /// UI has to expose it.
    var selectedOutputUIDs: [String] = [] {
        didSet {
            guard selectedOutputUIDs != oldValue else { return }
            persist()
            if status.isActive { restart() }
        }
    }

    var masterGain: Float = 1 {
        didSet {
            control.masterGain.pointee = max(0, min(1, masterGain))
            persist()
        }
    }

    var isMasterMuted: Bool = false {
        didSet {
            control.masterMuted.pointee = isMasterMuted ? 1 : 0
            persist()
        }
    }

    /// Republished at meter rate so views observing it redraw.
    private(set) var peakLevels: [String: Float] = [:]

    var activeDevices: [AudioDevice] {
        selectedOutputUIDs.compactMap { registry.device(uid: $0) }
    }

    // MARK: - Private state

    private let control = RenderControlBlock()
    private var tap: ProcessTap?
    private var output: AggregateOutput?
    private var plan: AggregatePlan?
    /// Invalidated from `deinit`, which is nonisolated.
    nonisolated(unsafe) private var meterTimer: Timer?
    private var deviceGains: [String: Float] = [:]
    private var deviceMutes: [String: Bool] = [:]
    private var sampleRate: Double = 48_000
    private var layoutVerified = false

    private let logger = Logger(subsystem: "com.nelitojr.UltraBass9000", category: "AudioEngine")
    private let defaults = UserDefaults.standard

    init(registry: AudioDeviceRegistry) {
        self.registry = registry
        restore()
        control.masterGain.pointee = masterGain
        control.masterMuted.pointee = isMasterMuted ? 1 : 0
        startMeterTimer()

        // Development affordance: `open UltraBass9000.app --args -UB9KAutoStart YES` brings the
        // engine up against the persisted selection without a click, so the Core Audio path can be
        // exercised from a script. Does nothing unless the flag is passed.
        if defaults.bool(forKey: "UB9KAutoStart") {
            Task { @MainActor [weak self] in self?.start() }
        }
    }

    deinit {
        meterTimer?.invalidate()
    }

    // MARK: - Selection

    func toggleSelection(uid: String) {
        if let index = selectedOutputUIDs.firstIndex(of: uid) {
            selectedOutputUIDs.remove(at: index)
        } else {
            selectedOutputUIDs.append(uid)
        }
    }

    /// Reorders the output set. Index 0 is the clock source, so this is not cosmetic.
    ///
    /// Implemented here rather than using SwiftUI's `move(fromOffsets:toOffset:)` so the audio
    /// layer stays free of any UI framework import.
    func moveSelection(fromOffsets: IndexSet, toOffset: Int) {
        let moved = fromOffsets.sorted().compactMap { index -> String? in
            index < selectedOutputUIDs.count ? selectedOutputUIDs[index] : nil
        }
        guard !moved.isEmpty else { return }
        // Count removals before the insertion point first: removing them shifts the target left.
        let insertionShift = fromOffsets.filter { $0 < toOffset }.count
        var reordered = selectedOutputUIDs
        for index in fromOffsets.sorted(by: >) where index < reordered.count {
            reordered.remove(at: index)
        }
        let destination = min(max(0, toOffset - insertionShift), reordered.count)
        reordered.insert(contentsOf: moved, at: destination)
        selectedOutputUIDs = reordered
    }

    // MARK: - Per-device parameters

    func gain(for uid: String) -> Float { deviceGains[uid] ?? 1 }

    func setGain(_ gain: Float, for uid: String) {
        let clamped = max(0, min(1, gain))
        deviceGains[uid] = clamped
        if let index = deviceIndex(for: uid) {
            control.setGain(clamped, deviceIndex: index)
        }
        persist()
    }

    func isMuted(_ uid: String) -> Bool { deviceMutes[uid] ?? false }

    func setMuted(_ muted: Bool, for uid: String) {
        deviceMutes[uid] = muted
        if let index = deviceIndex(for: uid) {
            control.setMuted(muted, deviceIndex: index)
        }
        persist()
    }

    func peak(for uid: String) -> Float { peakLevels[uid] ?? 0 }

    // MARK: - Lifecycle

    func start() {
        guard !status.isActive else { return }
        diagnostics.removeAll()

        guard !selectedOutputUIDs.isEmpty else {
            diagnostics = [.noOutputsSelected]
            return
        }
        status = .starting

        do {
            try activate()
            status = .running
        } catch {
            logger.error("Start failed: \(error.localizedDescription, privacy: .public)")
            shutdownPipeline()
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        shutdownPipeline()
        control.resetMeters()
        peakLevels = [:]
        status = .idle
    }

    private func restart() {
        guard status.isActive else { return }
        stop()
        start()
    }

    // MARK: - Pipeline

    private func activate() throws {
        layoutVerified = false

        // Exclude ourselves: we play the processed result back out, and a global tap would
        // otherwise capture our own output and feed it round again.
        let excluded = ProcessTap.selfProcessObjectID.map { [$0] } ?? []
        let tap = try ProcessTap(excludedProcessObjectIDs: excluded)
        self.tap = tap

        if let format = tap.streamDescription, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }

        var facts: [String: PlannerDevice] = [:]
        for device in registry.devices where device.canOutput {
            facts[device.uid] = PlannerDevice(device)
        }
        // A device the user picked earlier may be gone by now. Report it rather than silently
        // producing a different setup than the one on screen.
        let missing = selectedOutputUIDs.filter { facts[$0] == nil }
        for uid in missing {
            diagnostics.append(.deviceDisappeared(uid))
        }

        let tapSourceIsVirtual = registry.defaultOutputDevice?.isVirtual ?? false
        guard let plan = AggregatePlanner.plan(requestedUIDs: selectedOutputUIDs,
                                               facts: facts,
                                               tapSourceIsVirtual: tapSourceIsVirtual) else {
            throw CoreAudioError(operation: "No usable output devices in the current selection",
                                 status: kAudioHardwareIllegalOperationError)
        }
        self.plan = plan
        control.apply(plan: plan)
        applyStoredParameters(to: plan)

        let output = try AggregateOutput(plan: plan, tapUUID: tap.uuid, control: control)
        self.output = output
        try output.start()

        logger.info("""
            Engine running: \(plan.subDevices.count, privacy: .public) sub-devices, \
            \(plan.totalOutputStreams, privacy: .public) output streams, \
            sampleRate=\(self.sampleRate, privacy: .public)
            """)
    }

    private func shutdownPipeline() {
        // Order matters: the aggregate references the tap, so the tap has to die last.
        output?.teardown()
        output = nil
        tap?.invalidate()
        tap = nil
        plan = nil
    }

    private func applyStoredParameters(to plan: AggregatePlan) {
        for (index, subDevice) in plan.subDevices.enumerated() where index < RenderControlBlock.maxDevices {
            control.setGain(deviceGains[subDevice.uid] ?? 1, deviceIndex: index)
            control.setMuted(deviceMutes[subDevice.uid] ?? false, deviceIndex: index)
        }
    }

    private func deviceIndex(for uid: String) -> Int? {
        plan?.subDevices.firstIndex { $0.uid == uid }
    }

    // MARK: - Metering and watchdog

    private func startMeterTimer() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func tickMeters() {
        guard let plan, status == .running else {
            if !peakLevels.isEmpty { peakLevels = [:] }
            return
        }
        var levels: [String: Float] = [:]
        levels.reserveCapacity(plan.subDevices.count)
        for (index, subDevice) in plan.subDevices.enumerated() where index < RenderControlBlock.maxDevices {
            levels[subDevice.uid] = control.peak(deviceIndex: index)
        }
        peakLevels = levels
        // Decay after sampling so a transient still shows for at least one frame.
        control.decayPeaks(by: 0.72)

        verifyBufferLayout(against: plan)
        checkForSilentTap()
    }

    /// Confirms the HAL laid the aggregate out the way the plan assumed.
    ///
    /// A stacked aggregate is supposed to give one output buffer per sub-device stream. If it does
    /// not, per-device gain, metering and — later — EQ and delay are being applied to the wrong
    /// device, which is far more confusing to debug from the symptom than from a log line.
    private func verifyBufferLayout(against plan: AggregatePlan) {
        guard !layoutVerified, control.renderCycles.pointee > 0 else { return }
        layoutVerified = true

        let observed = Int(control.observedOutputBuffers.pointee)
        let expected = plan.totalOutputStreams
        logger.info("""
            Observed layout: stacked=\(plan.isStacked, privacy: .public) \
            buffers=\(observed, privacy: .public) \
            firstBufferChannels=\(Int(self.control.observedOutputChannels.pointee), privacy: .public) \
            tapChannels=\(Int(self.control.observedTapChannels.pointee), privacy: .public) \
            expectedBuffers=\(expected, privacy: .public) \
            expectedChannels=\(plan.totalOutputChannels, privacy: .public)
            """)
        if observed == expected {
            logger.info("Buffer layout confirmed: \(observed, privacy: .public) output buffers")
        } else {
            logger.warning("""
                Aggregate layout mismatch: expected \(expected, privacy: .public) output buffers \
                for \(plan.subDevices.count, privacy: .public) sub-devices, HAL delivered \
                \(observed, privacy: .public). Per-device processing may be routed incorrectly.
                """)
        }
    }

    /// Five seconds of pure digital silence while the engine believes it is running is the only
    /// evidence available that audio-capture permission was refused.
    private func checkForSilentTap() {
        guard !diagnostics.contains(.permissionLikelyDenied) else { return }
        let silentFrames = control.silentInputFrames.pointee
        guard control.renderCycles.pointee > 0 else { return }
        if Double(silentFrames) > sampleRate * 5 {
            diagnostics.append(.permissionLikelyDenied)
        }
    }

    // MARK: - Persistence

    private enum Key {
        static let selection = "selectedOutputUIDs"
        static let gains = "deviceGains"
        static let mutes = "deviceMutes"
        static let masterGain = "masterGain"
        static let masterMuted = "masterMuted"
    }

    private func persist() {
        defaults.set(selectedOutputUIDs, forKey: Key.selection)
        defaults.set(deviceGains, forKey: Key.gains)
        defaults.set(deviceMutes, forKey: Key.mutes)
        defaults.set(masterGain, forKey: Key.masterGain)
        defaults.set(isMasterMuted, forKey: Key.masterMuted)
    }

    private func restore() {
        selectedOutputUIDs = defaults.stringArray(forKey: Key.selection) ?? []
        deviceGains = (defaults.dictionary(forKey: Key.gains) as? [String: Float]) ?? [:]
        deviceMutes = (defaults.dictionary(forKey: Key.mutes) as? [String: Bool]) ?? [:]
        if defaults.object(forKey: Key.masterGain) != nil {
            masterGain = defaults.float(forKey: Key.masterGain)
        }
        isMasterMuted = defaults.bool(forKey: Key.masterMuted)
    }
}
