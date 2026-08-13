import AVFoundation
import CoreAudio
import Foundation
import os

/// Measures how far apart the selected output devices arrive at the listening position, by playing
/// a short sweep from each in turn and listening on the built-in microphone.
///
/// The result is only valid where the microphone is. Alignment is computed for the Mac's position,
/// which is the sweet spot the user gets. Headphones and earbuds cannot be measured at all — the
/// microphone cannot hear them — and are reported as skipped rather than guessed at.
@MainActor
final class AcousticCalibrator {

    struct Measurement: Equatable {
        let uid: String
        let deviceName: String
        /// Normalised correlation peak. Below `SyncSignal.confidenceThreshold` the measurement is
        /// not trusted and no delay is applied.
        let confidence: Float
        /// Device latency plus the constant shared by every measurement in this run.
        let relativeLatencySeconds: Double
        /// Delay to apply so this device lines up with the slowest one.
        let delaySeconds: Double
        var succeeded: Bool { confidence >= SyncSignal.confidenceThreshold }
    }

    struct Outcome: Equatable {
        let measurements: [Measurement]
        /// Gap between the earliest and latest device that was successfully measured.
        let spreadSeconds: Double
        var succeeded: [Measurement] { measurements.filter(\.succeeded) }
        var skipped: [Measurement] { measurements.filter { !$0.succeeded } }
    }

    enum CalibrationError: LocalizedError {
        case engineNotRunning
        case noInputDevice
        case microphoneAccessDenied
        case noDevicesToMeasure
        case microphoneSilent
        case cancelled

        var errorDescription: String? {
            switch self {
            case .engineNotRunning:
                return "Start playback before running auto-sync."
            case .noInputDevice:
                return "No microphone is available."
            case .microphoneAccessDenied:
                return "UltraBass 9000 needs microphone access to hear the test tones. Grant it in System Settings › Privacy & Security › Microphone, then try again."
            case .noDevicesToMeasure:
                return "Select at least two output devices to align."
            case .microphoneSilent:
                return "The microphone recorded nothing but silence. Check that the built-in microphone is not muted or covered."
            case .cancelled:
                return "Auto-sync was cancelled."
            }
        }
    }

    // MARK: - Timing

    /// Long enough for a sharp correlation peak, short enough not to be annoying.
    static let sweepDuration: Double = 0.4
    /// Start-to-start spacing between sweeps. Must exceed the sweep plus the largest latency being
    /// measured plus the shared constant, or a slow device's arrival lands in the next device's
    /// search window and gets attributed to the wrong device.
    static let gapSeconds: Double = 1.5
    /// Silence before the first sweep, so the recorder is certainly running and settled.
    static let leadInSeconds: Double = 0.6

    private let logger = Logger(subsystem: "com.nelitojr.UltraBass9000", category: "Calibration")
    private let control: RenderControlBlock
    private var recorder: MicrophoneRecorder?
    private var isCancelled = false

    init(control: RenderControlBlock) {
        self.control = control
    }

    func cancel() {
        isCancelled = true
        control.calibration.cancel()
        if let recorder {
            DispatchQueue.global(qos: .userInitiated).async { recorder.stop() }
        }
    }

    // MARK: - Running a measurement

    /// - Parameters:
    ///   - devices: UID and display name per device, in plan order. Index in this array is the
    ///     device index the render thread uses.
    ///   - playbackSampleRate: rate of the output aggregate.
    ///   - onProgress: called as each device begins playing, 1-based.
    func run(devices: [(uid: String, name: String)],
             playbackSampleRate: Double,
             isEngineRunning: Bool,
             onProgress: @escaping (Int, String) -> Void) async throws -> Outcome {
        isCancelled = false

        guard isEngineRunning else { throw CalibrationError.engineNotRunning }
        guard devices.count >= 1 else { throw CalibrationError.noDevicesToMeasure }
        guard let inputDeviceID = MicrophoneRecorder.defaultInputDeviceID else {
            throw CalibrationError.noInputDevice
        }

        // Ask for microphone access through AVFoundation *before* touching the HAL.
        //
        // Not politeness — necessity. `AudioDeviceStart` blocks its caller until the HAL's IO
        // thread reports running, and on an unauthorised input device that thread waits for TCC,
        // which needs the main thread to put a prompt on screen. Calling it from the main actor
        // therefore deadlocks the app outright. Resolving permission first, asynchronously, means
        // the HAL call has nothing left to wait for.
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CalibrationError.microphoneAccessDenied
        }
        try checkCancelled()

        let leadInFrames = Int(Self.leadInSeconds * playbackSampleRate)
        let gapFrames = Int(Self.gapSeconds * playbackSampleRate)
        let programSeconds = Self.leadInSeconds
            + Double(devices.count - 1) * Self.gapSeconds
            + Self.sweepDuration + Self.gapSeconds

        let recorder = try MicrophoneRecorder(deviceID: inputDeviceID,
                                              capacitySeconds: programSeconds + 2)
        self.recorder = recorder
        defer {
            // Dispatched, not called inline: this also runs on the error and cancellation paths,
            // where the recorder may still be running, and `AudioDeviceStop` would block the main
            // thread exactly as `AudioDeviceStart` does.
            let running = recorder
            DispatchQueue.global(qos: .userInitiated).async { running.stop() }
            self.recorder = nil
            control.calibration.cancel()
        }

        // Two signals from the same definition. The played sweep must be at the playback rate or it
        // comes out at the wrong pitch and duration; the correlation reference must be at the
        // capture rate or its frequency trajectory will not match what was recorded.
        let playbackSweep = SyncSignal.logarithmicSweep(duration: Self.sweepDuration,
                                                        sampleRate: playbackSampleRate)
        let referenceSweep = SyncSignal.logarithmicSweep(duration: Self.sweepDuration,
                                                         sampleRate: recorder.sampleRate)
        guard !playbackSweep.isEmpty, !referenceSweep.isEmpty else {
            throw CalibrationError.noDevicesToMeasure
        }

        let segments = control.calibration.schedule(sweep: playbackSweep,
                                                    deviceIndices: Array(devices.indices),
                                                    gapFrames: gapFrames,
                                                    leadInFrames: leadInFrames)
        guard !segments.isEmpty else { throw CalibrationError.noDevicesToMeasure }

        // Off the main actor: `AudioDeviceStart` blocks until the HAL's IO thread is running, and
        // blocking the main thread on it is what deadlocked this code the first time.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try recorder.start()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // Let the input settle before the first sweep; the lead-in covers the rest.
        try await Task.sleep(for: .milliseconds(200))
        try checkCancelled()
        control.calibration.begin()

        logger.info("""
            Calibration started: \(devices.count, privacy: .public) devices, \
            playback=\(playbackSampleRate, privacy: .public) Hz, \
            capture=\(recorder.sampleRate, privacy: .public) Hz
            """)

        var announced = 0
        let deadline = Date().addingTimeInterval(programSeconds + 5)
        while !control.calibration.isFinished {
            try checkCancelled()
            if Date() > deadline { break }

            let position = Int(control.calibration.position.pointee)
            while announced < segments.count, position >= segments[announced].startFrame {
                announced += 1
                onProgress(announced, devices[announced - 1].name)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try checkCancelled()

        // Let the tail of the last sweep finish travelling to the microphone.
        try await Task.sleep(for: .milliseconds(400))
        await stopOffMainThread(recorder)

        let capture = recorder.recording()
        logger.info("""
            Captured \(capture.count, privacy: .public) frames \
            (\(Double(capture.count) / recorder.sampleRate, privacy: .public) s), \
            peak=\(recorder.peakLevel, privacy: .public)
            """)
        guard recorder.peakLevel > 0.0005 else { throw CalibrationError.microphoneSilent }

        return analyse(capture: capture,
                       captureSampleRate: recorder.sampleRate,
                       reference: referenceSweep,
                       segments: segments,
                       devices: devices,
                       playbackSampleRate: playbackSampleRate,
                       gapFrames: gapFrames)
    }

    private func checkCancelled() throws {
        if isCancelled { throw CalibrationError.cancelled }
    }

    /// `AudioDeviceStop` blocks the same way `AudioDeviceStart` does, so it is kept off the main
    /// thread too. After this, `deinit` finds the recorder already stopped and does nothing.
    private func stopOffMainThread(_ recorder: MicrophoneRecorder) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                recorder.stop()
                continuation.resume()
            }
        }
    }

    // MARK: - Analysis

    /// Correlates each device's search window and turns the arrivals into delays.
    ///
    /// Every sweep in the program is identical, so correlating the whole recording would simply
    /// find the loudest one. Each device is searched only within its own scheduled window.
    func analyse(capture: [Float],
                 captureSampleRate: Double,
                 reference: [Float],
                 segments: [CalibrationPlayer.Segment],
                 devices: [(uid: String, name: String)],
                 playbackSampleRate: Double,
                 gapFrames: Int) -> Outcome {
        let rateRatio = captureSampleRate / playbackSampleRate
        let windowFrames = Int(Double(gapFrames) * rateRatio)

        var relativeLatencies: [Double?] = []
        var confidences: [Float] = []

        for segment in segments {
            let windowStart = Int(Double(segment.startFrame) * rateRatio)
            let windowEnd = min(capture.count, windowStart + windowFrames + reference.count)
            guard windowStart >= 0, windowEnd - windowStart > reference.count else {
                relativeLatencies.append(nil)
                confidences.append(0)
                continue
            }

            let window = Array(capture[windowStart..<windowEnd])
            guard let detection = SyncSignal.findOffset(reference: reference, in: window) else {
                relativeLatencies.append(nil)
                confidences.append(0)
                continue
            }

            let arrivalFrames = windowStart + detection.offsetFrames
            let latency = SyncSignal.relativeLatencySeconds(arrivalFrames: arrivalFrames,
                                                            captureSampleRate: captureSampleRate,
                                                            scheduledPlaybackFrames: segment.startFrame,
                                                            playbackSampleRate: playbackSampleRate)
            relativeLatencies.append(latency)
            confidences.append(detection.confidence)
        }

        // Only trusted measurements take part in the alignment. A device that was not heard must
        // not drag every other device's delay with it.
        var trustedIndices: [Int] = []
        var trustedLatencies: [Double] = []
        for index in relativeLatencies.indices {
            if let latency = relativeLatencies[index],
               confidences[index] >= SyncSignal.confidenceThreshold {
                trustedIndices.append(index)
                trustedLatencies.append(latency)
            }
        }

        let alignment = SyncSignal.alignmentDelays(relativeLatencies: trustedLatencies)
        var delayByIndex: [Int: Double] = [:]
        for (position, index) in trustedIndices.enumerated() {
            delayByIndex[index] = alignment[position]
        }

        var measurements: [Measurement] = []
        for (index, segment) in segments.enumerated() {
            let device = devices[segment.deviceIndex]
            measurements.append(Measurement(uid: device.uid,
                                            deviceName: device.name,
                                            confidence: confidences[index],
                                            relativeLatencySeconds: relativeLatencies[index] ?? 0,
                                            delaySeconds: delayByIndex[index] ?? 0))
        }

        let spread = (trustedLatencies.max() ?? 0) - (trustedLatencies.min() ?? 0)
        for measurement in measurements {
            logger.info("""
                \(measurement.deviceName, privacy: .public): \
                confidence=\(measurement.confidence, privacy: .public) \
                latency=\(measurement.relativeLatencySeconds * 1000, privacy: .public) ms \
                delay=\(measurement.delaySeconds * 1000, privacy: .public) ms
                """)
        }
        return Outcome(measurements: measurements, spreadSeconds: max(0, spread))
    }
}
