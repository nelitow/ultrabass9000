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

/// What auto-sync concluded about one device.
///
/// Carried through explicitly rather than letting the UI rejoin results to devices by display name.
/// A name-based join silently mislabels a device whenever the join misses, and the failure looks
/// like a device that was measured and needs no correction — indistinguishable, on screen, from one
/// that was never heard at all.
struct CalibrationResult: Equatable, Identifiable {
    let uid: String
    let deviceName: String
    let delayMilliseconds: Double
    let confidence: Double
    /// False when the sweep was not heard clearly enough to trust — headphones, a device that is
    /// not physically connected to speakers, or a room too noisy at that moment.
    let wasMeasured: Bool

    var id: String { uid }
}

enum CalibrationState: Equatable {
    case idle
    case preparing
    case measuring(deviceName: String, index: Int, total: Int)
    case analysing
    case failed(String)
    case succeeded(results: [CalibrationResult], spreadMilliseconds: Double)

    var isRunning: Bool {
        switch self {
        case .preparing, .measuring, .analysing: return true
        case .idle, .failed, .succeeded: return false
        }
    }
}

/// Non-fatal conditions worth surfacing rather than logging into the void.
enum EngineDiagnostic: Equatable, Identifiable {
    /// Advisory, not a fault: nothing has been captured *yet*. Offered once, and only while the tap
    /// has never delivered a sample, since the first one proves capture permission for good.
    case noAudioYet
    case noOutputsSelected
    case deviceDisappeared(String)

    var id: String {
        switch self {
        case .noAudioYet: return "no-audio-yet"
        case .noOutputsSelected: return "no-outputs"
        case .deviceDisappeared(let name): return "gone-\(name)"
        }
    }

    /// Advisories are informational and should not be dressed as warnings.
    var isAdvisory: Bool {
        switch self {
        case .noAudioYet: return true
        case .noOutputsSelected, .deviceDisappeared: return false
        }
    }

    var title: String {
        switch self {
        case .noAudioYet: return "Nothing captured yet"
        case .noOutputsSelected: return "Pick at least one output"
        case .deviceDisappeared(let name): return "\(name) disappeared"
        }
    }

    var detail: String {
        switch self {
        case .noAudioYet:
            return "Play something to check the routing. If the meters stay flat while audio is playing, UltraBass 9000 may not be allowed to record audio. Check System Settings › Privacy & Security."
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

    /// Frequency response measured at the listening position by the last auto-sync, per device.
    ///
    /// Comparable between devices, not meaningful in absolute terms: the built-in microphone has a
    /// response of its own, and below roughly 300 Hz a single position measures the room as much as
    /// the speaker. What it answers reliably is which device produces what, and where two of them
    /// should hand over.
    private(set) var measuredResponses: [String: [ResponsePoint]] = [:]

    func measuredResponse(for uid: String) -> [ResponsePoint] { measuredResponses[uid] ?? [] }

    var hasMeasuredResponses: Bool { measuredResponses.values.contains { !$0.isEmpty } }

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
    /// Set the first time the tap delivers a non-silent sample, which proves capture permission.
    private var hasEverReceivedAudio = false

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
        // Deferred: dragging an EQ handle calls this on every mouse move, and encoding the whole
        // processing dictionary to JSON and writing it to UserDefaults sixty times a second is
        // enough main-thread work to make the curve stutter while it is being dragged.
        schedulePersist()
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

    // MARK: - Test beat

    /// Plays a repeating transient on every device at once, so alignment can be judged by ear.
    ///
    /// Numbers say the devices are 4 ms apart. This says whether that sounds like one hit or two,
    /// which is the question actually being asked.
    private(set) var isBeatPlaying = false

    func toggleBeat() {
        isBeatPlaying ? stopBeat() : startBeat()
    }

    func startBeat() {
        guard status == .running, !isBeatPlaying else { return }
        control.beat.load(waveform: TestBeat.waveform(sampleRate: sampleRate), sampleRate: sampleRate)
        control.beat.start()
        isBeatPlaying = true
    }

    func stopBeat() {
        control.beat.stop()
        isBeatPlaying = false
    }

    // MARK: - Acoustic calibration

    private(set) var calibration: CalibrationState = .idle

    func startCalibration() {
        guard !calibration.isRunning else { return }
        // Calibration takes over the output entirely; a beat still running would be measured as
        // part of the room.
        stopBeat()
        guard let plan else {
            calibration = .failed(AcousticCalibrator.CalibrationError.engineNotRunning.localizedDescription)
            return
        }

        let devices = plan.subDevices.map { subDevice -> (uid: String, name: String) in
            (subDevice.uid, registry.device(uid: subDevice.uid)?.name ?? subDevice.uid)
        }
        // Sweeps, not devices. Each device is swept once per pass, and the progress index counts
        // sweeps, so counting the total in devices produced "Sweep 9 of 3".
        let total = devices.count * AcousticCalibrator.passes
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
        // A device that was not heard keeps whatever delay it already had. Zeroing it would quietly
        // undo a manual offset the user dialled in precisely because it cannot be measured.
        applyDelays()
        persist()

        for measurement in outcome.measurements where !measurement.response.isEmpty {
            measuredResponses[measurement.uid] = measurement.response
        }

        let results = outcome.measurements.map { measurement in
            CalibrationResult(uid: measurement.uid,
                              deviceName: measurement.deviceName,
                              delayMilliseconds: measurement.succeeded
                                  ? measurement.delaySeconds * 1000
                                  : (deviceDelays[measurement.uid]?.milliseconds ?? 0),
                              confidence: Double(measurement.confidence),
                              wasMeasured: measurement.succeeded)
        }
        calibration = .succeeded(results: results,
                                 spreadMilliseconds: outcome.spreadSeconds * 1000)
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
        stopBeat()
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

    /// Decides whether the app has any business complaining about silence.
    ///
    /// There is no API to ask whether audio-capture permission was granted; a refused tap just
    /// delivers zeros forever, which looks exactly like nobody playing anything. Two approaches
    /// were tried and rejected:
    ///
    /// - Warning after N seconds of silence. Fires constantly during normal use, and a warning that
    ///   cries wolf is worse than none.
    /// - Warning when silence coincides with another process running output.
    ///   `kAudioProcessPropertyIsRunningOutput` reports an open output *stream*, not audible sound;
    ///   two processes report true on a completely idle machine, so this is the first test all over
    ///   again wearing a disguise.
    ///
    /// What remains is the one asymmetry that holds: once the tap has delivered a single non-silent
    /// sample, permission is proven and the question is settled forever. So the hint is offered only
    /// while the tap has *never* produced audio, and it is advisory rather than an error.
    private func checkForSilentTap() {
        guard !hasEverReceivedAudio else { return }

        if control.silentInputFrames.pointee == 0, control.renderCycles.pointee > 0 {
            hasEverReceivedAudio = true
            diagnostics.removeAll { $0 == .noAudioYet }
            return
        }

        guard !diagnostics.contains(.noAudioYet) else { return }
        guard Double(control.silentInputFrames.pointee) > sampleRate * 20 else { return }
        diagnostics.append(.noAudioYet)
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
        static let responses = "measuredResponses"
    }

    /// Suppresses writes while `restore()` is assigning to observed properties.
    ///
    /// Without this, the first assignment in `restore()` fires `didSet` → `persist()`, which writes
    /// the still-empty gains, mutes and EQ back over the saved values — so everything loaded after
    /// that first line reads what we just clobbered. Settings appeared to save and then silently
    /// reset on every launch.
    private var isRestoring = false

    private var persistTask: Task<Void, Never>?

    /// Coalesces rapid settings changes into one write shortly after the user stops moving.
    private func schedulePersist() {
        guard !isRestoring else { return }
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

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
        // Measured curves outlive the session that produced them. Re-running auto-sync costs
        // sixteen seconds of sitting still, which is not a reasonable price for quitting the app.
        if let encoded = try? JSONEncoder().encode(measuredResponses) {
            defaults.set(encoded, forKey: Key.responses)
        }
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
        if let data = defaults.data(forKey: Key.responses),
           let decoded = try? JSONDecoder().decode([String: [ResponsePoint]].self, from: data) {
            measuredResponses = decoded
        }
        syncEnabled = defaults.object(forKey: Key.syncEnabled) == nil
            ? true
            : defaults.bool(forKey: Key.syncEnabled)
    }
}
