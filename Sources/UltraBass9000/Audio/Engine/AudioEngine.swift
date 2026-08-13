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

/// How long one device is held back so it lines up with the slowest one.
struct DeviceDelay: Codable, Equatable {
    var milliseconds: Double = 0
    /// True when the value came from acoustic calibration rather than being dialled in by hand.
    var isAutomatic: Bool = false

    static let none = DeviceDelay()
}

enum CalibrationState: Equatable {
    case idle
    case preparing
    case measuring(deviceName: String, index: Int, total: Int)
    case analysing
    case failed(String)
    case succeeded(alignedDeviceCount: Int, spreadMilliseconds: Double, skipped: [String])

    var isRunning: Bool {
        switch self {
        case .preparing, .measuring, .analysing: return true
        case .idle, .failed, .succeeded: return false
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

    /// Per-device envelope history, oldest first. Republished at meter rate.
    private(set) var waveforms: [String: [WaveformSample]] = [:]

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
    private var deviceProcessing: [String: DeviceProcessing] = [:]
    private var deviceDelays: [String: DeviceDelay] = [:]
    private var activeCalibrator: AcousticCalibrator?
    private var calibrationTask: Task<Void, Never>?
    private var sampleRate: Double = 48_000
    private var layoutVerified = false
    private var meterLogTicks = 0

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
            Task { @MainActor [weak self] in
                self?.start()
                // `-UB9KCalibrate YES` additionally runs one acoustic measurement and logs it, so
                // the whole calibration path can be exercised from a script.
                guard self?.defaults.bool(forKey: "UB9KCalibrate") == true else { return }
                try? await Task.sleep(for: .seconds(2))
                self?.startCalibration()
            }
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

    func waveform(for uid: String) -> [WaveformSample] { waveforms[uid] ?? [] }

    // MARK: - EQ and filters

    func processing(for uid: String) -> DeviceProcessing {
        deviceProcessing[uid] ?? .neutral
    }

    func setProcessing(_ processing: DeviceProcessing, for uid: String) {
        deviceProcessing[uid] = processing.normalised
        publishFilters()
        persist()
    }

    func resetProcessing(for uid: String) {
        deviceProcessing[uid] = .neutral
        publishFilters()
        persist()
    }

    /// Combined dB response of the device's whole chain, for drawing the curve.
    ///
    /// Computed from the same `DeviceProcessing` the render thread is running, at the same sample
    /// rate, so what is drawn is what is heard rather than an idealised approximation.
    func magnitudeResponse(for uid: String, at frequencies: [Double]) -> [Double] {
        processing(for: uid).magnitudeResponse(at: frequencies, sampleRate: sampleRate)
    }

    // MARK: - Delay and synchronisation

    /// Master switch. Off means every delay line is bypassed and the app runs at its lowest latency.
    var syncEnabled: Bool = true {
        didSet {
            guard syncEnabled != oldValue else { return }
            applyDelays()
            persist()
        }
    }

    /// The largest delay currently in effect — the latency that being in sync costs everything.
    ///
    /// Surfaced rather than hidden because it is the real trade-off of this feature: aligning to a
    /// pair of AirPods can put a fifth of a second between a key press and its sound.
    var syncLatencyMilliseconds: Double {
        guard syncEnabled, let plan else { return 0 }
        return plan.subDevices.map { deviceDelays[$0.uid]?.milliseconds ?? 0 }.max() ?? 0
    }

    /// Upper bound on a single delay, which shrinks as the sample rate rises because the delay
    /// buffer is a fixed number of frames.
    var maximumDelayMilliseconds: Double {
        min(500, DelayBank.maximumDelaySeconds(sampleRate: sampleRate) * 1000)
    }

    func delay(for uid: String) -> DeviceDelay { deviceDelays[uid] ?? .none }

    func setDelayMilliseconds(_ milliseconds: Double, for uid: String) {
        let clamped = min(max(0, milliseconds), maximumDelayMilliseconds)
        deviceDelays[uid] = DeviceDelay(milliseconds: clamped, isAutomatic: false)
        applyDelays()
        persist()
    }

    func clearDelay(for uid: String) {
        deviceDelays[uid] = nil
        applyDelays()
        persist()
    }

    /// Pushes the stored delays to the render thread.
    ///
    /// `immediately` skips the click-avoiding fade, which is only safe when no audio is flowing —
    /// at activation, where the lines are empty anyway.
    private func applyDelays(immediately: Bool = false) {
        guard let plan else { return }
        for (index, subDevice) in plan.subDevices.enumerated() where index < DelayBank.maxDevices {
            let milliseconds = syncEnabled ? (deviceDelays[subDevice.uid]?.milliseconds ?? 0) : 0
            let frames = Int((milliseconds / 1000) * sampleRate)
            if immediately {
                control.delays.setDelayImmediately(frames: frames, deviceIndex: index)
            } else {
                control.delays.setDelay(frames: frames, deviceIndex: index)
            }
        }
    }

    // MARK: - Acoustic calibration

    private(set) var calibration: CalibrationState = .idle

    func startCalibration() {
        guard !calibration.isRunning else { return }
        guard let plan else {
            calibration = .failed(AcousticCalibrator.CalibrationError.engineNotRunning.localizedDescription)
            return
        }

        let devices = plan.subDevices.map { subDevice -> (uid: String, name: String) in
            (subDevice.uid, registry.device(uid: subDevice.uid)?.name ?? subDevice.uid)
        }
        let total = devices.count
        let calibrator = AcousticCalibrator(control: control)
        activeCalibrator = calibrator
        calibration = .preparing
        logger.info("Calibration requested for \(devices.map(\.name), privacy: .public)")

        calibrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outcome = try await calibrator.run(
                    devices: devices,
                    playbackSampleRate: self.sampleRate,
                    isEngineRunning: self.status == .running,
                    onProgress: { index, name in
                        Task { @MainActor [weak self] in
                            self?.calibration = .measuring(deviceName: name, index: index, total: total)
                        }
                    })
                self.calibration = .analysing
                self.apply(outcome: outcome)
            } catch {
                self.logger.error("Calibration failed: \(error.localizedDescription, privacy: .public)")
                self.calibration = .failed(error.localizedDescription)
            }
            self.activeCalibrator = nil
        }
    }

    func cancelCalibration() {
        activeCalibrator?.cancel()
        calibrationTask?.cancel()
        calibrationTask = nil
        activeCalibrator = nil
        if calibration.isRunning { calibration = .idle }
    }

    private func apply(outcome: AcousticCalibrator.Outcome) {
        for measurement in outcome.succeeded {
            deviceDelays[measurement.uid] = DeviceDelay(
                milliseconds: min(measurement.delaySeconds * 1000, maximumDelayMilliseconds),
                isAutomatic: true)
        }
        applyDelays()
        persist()

        calibration = .succeeded(alignedDeviceCount: outcome.succeeded.count,
                                 spreadMilliseconds: outcome.spreadSeconds * 1000,
                                 skipped: outcome.skipped.map(\.deviceName))
    }

    /// Compiles every active device's chain and hands the whole set to the render thread at once.
    private func publishFilters() {
        guard let plan else { return }
        let chains = plan.subDevices.map { subDevice in
            processing(for: subDevice.uid).compile(sampleRate: sampleRate)
        }
        control.filters.publish(chains)
        publishedSectionCounts = chains.map(\.count)
    }

    /// Sections compiled per device at the last publish. Logged at activation and useful when a
    /// filter appears to do nothing — an empty chain means the settings never reached the engine.
    private(set) var publishedSectionCounts: [Int] = []

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
            sampleRate=\(self.sampleRate, privacy: .public), \
            filterSections=\(self.publishedSectionCounts, privacy: .public)
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
        publishFilters()
        applyDelays(immediately: true)
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
            if !waveforms.isEmpty { waveforms = [:] }
            return
        }
        var levels: [String: Float] = [:]
        var envelopes: [String: [WaveformSample]] = [:]
        levels.reserveCapacity(plan.subDevices.count)
        envelopes.reserveCapacity(plan.subDevices.count)
        for (index, subDevice) in plan.subDevices.enumerated() where index < RenderControlBlock.maxDevices {
            levels[subDevice.uid] = control.peak(deviceIndex: index)
            envelopes[subDevice.uid] = control.waveforms.snapshot(deviceIndex: index)
        }
        peakLevels = levels
        waveforms = envelopes
        logMetersIfRequested(plan: plan)
        // Decay after sampling so a transient still shows for at least one frame.
        control.decayPeaks(by: 0.72)

        verifyBufferLayout(against: plan)
        checkForSilentTap()
    }

    /// Development affordance: `-UB9KLogMeters YES` prints the running peak per device once a
    /// second. Comparing two devices' levels is how per-device processing gets verified from a
    /// script, since the on-screen meters decay faster than a screenshot can catch them.
    private func logMetersIfRequested(plan: AggregatePlan) {
        guard defaults.bool(forKey: "UB9KLogMeters") else { return }
        meterLogTicks += 1
        guard meterLogTicks % 30 == 0 else { return }
        let summary = plan.subDevices.enumerated().map { index, subDevice in
            let peak = control.peak(deviceIndex: index)
            let db = peak > 0.00001 ? 20 * log10(peak) : -100
            return String(format: "%@=%.1fdB", subDevice.uid.prefix(24).description, db)
        }
        logger.info("Meters: \(summary.joined(separator: "  "), privacy: .public)")
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
        static let processing = "deviceProcessing"
        static let delays = "deviceDelays"
        static let syncEnabled = "syncEnabled"
    }

    /// Suppresses writes while `restore()` is assigning to observed properties.
    ///
    /// Without this, the first assignment in `restore()` fires `didSet` → `persist()`, which writes
    /// the still-empty gains, mutes and EQ back over the saved values — so everything loaded after
    /// that first line reads what we just clobbered. Settings appeared to save and then silently
    /// reset on every launch.
    private var isRestoring = false

    private func persist() {
        guard !isRestoring else { return }
        defaults.set(selectedOutputUIDs, forKey: Key.selection)
        defaults.set(deviceGains, forKey: Key.gains)
        defaults.set(deviceMutes, forKey: Key.mutes)
        defaults.set(masterGain, forKey: Key.masterGain)
        defaults.set(isMasterMuted, forKey: Key.masterMuted)
        if let encoded = try? JSONEncoder().encode(deviceProcessing) {
            defaults.set(encoded, forKey: Key.processing)
        }
        if let encoded = try? JSONEncoder().encode(deviceDelays) {
            defaults.set(encoded, forKey: Key.delays)
        }
        defaults.set(syncEnabled, forKey: Key.syncEnabled)
    }

    private func restore() {
        isRestoring = true
        defer { isRestoring = false }

        selectedOutputUIDs = defaults.stringArray(forKey: Key.selection) ?? []
        deviceGains = (defaults.dictionary(forKey: Key.gains) as? [String: Float]) ?? [:]
        deviceMutes = (defaults.dictionary(forKey: Key.mutes) as? [String: Bool]) ?? [:]
        if defaults.object(forKey: Key.masterGain) != nil {
            masterGain = defaults.float(forKey: Key.masterGain)
        }
        isMasterMuted = defaults.bool(forKey: Key.masterMuted)

        // `normalised` repairs anything an older build wrote — a shorter band array, a stale slot
        // index — rather than discarding the user's settings on a schema change.
        if let data = defaults.data(forKey: Key.processing),
           let decoded = try? JSONDecoder().decode([String: DeviceProcessing].self, from: data) {
            deviceProcessing = decoded.mapValues(\.normalised)
        }
        if let data = defaults.data(forKey: Key.delays),
           let decoded = try? JSONDecoder().decode([String: DeviceDelay].self, from: data) {
            deviceDelays = decoded
        }
        syncEnabled = defaults.object(forKey: Key.syncEnabled) == nil
            ? true
            : defaults.bool(forKey: Key.syncEnabled)
    }
}
