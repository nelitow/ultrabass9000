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
        /// What this device and the room did to the sweep, relative to the other devices measured
        /// in the same pass. Empty when the sweep was not heard well enough to mean anything.
        let response: [ResponsePoint]
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
        case playbackDidNotRun
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
            case .playbackDidNotRun:
                return "The test tones never reached the output devices. Stop and start playback, then try again."
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
    /// How many times the whole device sequence is played.
    ///
    /// One pass is enough to find an arrival time. It is not enough for a frequency response: a
    /// single microphone position in a real room produces comb filtering, and a passing noise ruins
    /// exactly one sweep. Three passes combined by median throw out the ruined one instead of
    /// averaging it in.
    static let passes = 3

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
        let sweepCount = devices.count * Self.passes
        let programSeconds = Self.leadInSeconds
            + Double(sweepCount - 1) * Self.gapSeconds
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

        // Every device, `passes` times over, in the same order each pass.
        let sequence = (0..<Self.passes).flatMap { _ in Array(devices.indices) }
        let segments = control.calibration.schedule(sweep: playbackSweep,
                                                    deviceIndices: sequence,
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
        var timedOut = false
        let deadline = Date().addingTimeInterval(programSeconds + 5)
        while !control.calibration.isFinished {
            try checkCancelled()
            if Date() > deadline {
                timedOut = true
                break
            }

            let position = Int(control.calibration.position.pointee)
            while announced < segments.count, position >= segments[announced].startFrame {
                // Index `devices` through the segment, never through the sweep counter. With
                // several passes there are more sweeps than devices, and treating the two as the
                // same number reads past the end of the device list.
                let deviceIndex = segments[announced].deviceIndex
                announced += 1
                if devices.indices.contains(deviceIndex) {
                    onProgress(announced, devices[deviceIndex].name)
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try checkCancelled()

        // Let the tail of the last sweep finish travelling to the microphone.
        try await Task.sleep(for: .milliseconds(400))
        await stopOffMainThread(recorder)

        let capture = recorder.recording()
        let playedFrames = Int(control.calibration.position.pointee)
        let expectedFrames = Int(control.calibration.programFrames.pointee)
        logger.info("""
            Captured \(capture.count, privacy: .public) frames \
            (\(Double(capture.count) / recorder.sampleRate, privacy: .public) s), \
            peak=\(recorder.peakLevel, privacy: .public), \
            played=\(playedFrames, privacy: .public)/\(expectedFrames, privacy: .public) frames, \
            timedOut=\(timedOut, privacy: .public)
            """)

        // A program that did not reach its end means the output device's IOProc was not running, so
        // nothing was ever played. Reporting that as "the room was too quiet" would send the user
        // hunting for the wrong problem.
        guard !timedOut, playedFrames >= expectedFrames else {
            throw CalibrationError.playbackDidNotRun
        }
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

    // MARK: - Combining passes

    static func median<T: Comparable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Median across passes, band by band.
    ///
    /// Every pass uses the same reference sweep, so every pass reports the same band centres and the
    /// curves line up index for index. Bands are matched by frequency anyway rather than by
    /// position, so a pass that dropped a band cannot silently shift the rest.
    static func medianResponse(_ curves: [[ResponsePoint]]) -> [ResponsePoint] {
        let usable = curves.filter { !$0.isEmpty }
        guard let first = usable.first else { return [] }
        guard usable.count > 1 else { return first }

        var byFrequency: [Double: [Double]] = [:]
        for curve in usable {
            for point in curve {
                byFrequency[point.frequency, default: []].append(point.decibels)
            }
        }
        return first.compactMap { point in
            guard let values = byFrequency[point.frequency],
                  let value = median(values) else { return nil }
            return ResponsePoint(frequency: point.frequency, decibels: value)
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
        // Timing correlates against the band-limited sweep; the response still uses the full one.
        let timingReference = SyncSignal.bandLimitedForTiming(reference, sampleRate: captureSampleRate)

        var relativeLatencies: [Double?] = []
        var confidences: [Float] = []
        var responses: [[ResponsePoint]] = []

        for segment in segments {
            let windowStart = Int(Double(segment.startFrame) * rateRatio)
            let windowEnd = min(capture.count, windowStart + windowFrames + reference.count)
            guard windowStart >= 0, windowEnd - windowStart > reference.count else {
                relativeLatencies.append(nil)
                confidences.append(0)
                responses.append([])
                continue
            }

            let window = Array(capture[windowStart..<windowEnd])
            let timingWindow = SyncSignal.bandLimitedForTiming(window, sampleRate: captureSampleRate)
            guard let detection = SyncSignal.findOffset(reference: timingReference, in: timingWindow) else {
                relativeLatencies.append(nil)
                confidences.append(0)
                responses.append([])
                continue
            }

            let arrivalFrames = windowStart + detection.offsetFrames
            let latency = SyncSignal.relativeLatencySeconds(arrivalFrames: arrivalFrames,
                                                            captureSampleRate: captureSampleRate,
                                                            scheduledPlaybackFrames: segment.startFrame,
                                                            playbackSampleRate: playbackSampleRate)
            relativeLatencies.append(latency)
            confidences.append(detection.confidence)

            // Frequency response, measured from the same capture, starting at the arrival that was
            // just located. A tail beyond the sweep length is included deliberately: the room's
            // decay is part of what reaches the listener and part of what the curve should show.
            if detection.confidence >= SyncSignal.confidenceThreshold {
                let tail = Int(0.15 * captureSampleRate)
                let responseStart = arrivalFrames
                let responseEnd = min(capture.count, responseStart + reference.count + tail)
                if responseEnd > responseStart {
                    responses.append(ResponseAnalyzer.response(
                        recorded: Array(capture[responseStart..<responseEnd]),
                        reference: reference,
                        sampleRate: captureSampleRate))
                } else {
                    responses.append([])
                }
            } else {
                responses.append([])
            }
        }

        // Collapse the passes. Each device was swept `passes` times, so there are several
        // measurements per device and one result is wanted.
        //
        // Median rather than mean throughout. The failure mode of a room measurement is not gentle
        // noise on every pass, it is one pass wrecked by a cough, a chair, or a notification. A mean
        // folds that in; a median discards it.
        var perDeviceLatency: [Int: Double] = [:]
        var perDeviceConfidence: [Int: Float] = [:]
        var perDeviceResponse: [Int: [ResponsePoint]] = [:]

        for deviceIndex in devices.indices {
            let passes = segments.indices.filter { segments[$0].deviceIndex == deviceIndex }
            guard !passes.isEmpty else { continue }

            perDeviceConfidence[deviceIndex] = Self.median(passes.map { confidences[$0] }) ?? 0

            let trusted = passes.filter { confidences[$0] >= SyncSignal.confidenceThreshold }
            if let latency = Self.median(trusted.compactMap { relativeLatencies[$0] }) {
                perDeviceLatency[deviceIndex] = latency
            }
            perDeviceResponse[deviceIndex] = Self.medianResponse(trusted.map { responses[$0] })
        }

        // Only devices heard confidently take part in the alignment. One that was not heard must
        // not drag every other device's delay with it.
        let alignedIndices = devices.indices.filter {
            perDeviceLatency[$0] != nil
                && (perDeviceConfidence[$0] ?? 0) >= SyncSignal.confidenceThreshold
        }
        let trustedLatencies = alignedIndices.compactMap { perDeviceLatency[$0] }
        let alignment = SyncSignal.alignmentDelays(relativeLatencies: trustedLatencies)

        var delayByDevice: [Int: Double] = [:]
        for (position, deviceIndex) in alignedIndices.enumerated() {
            delayByDevice[deviceIndex] = alignment[position]
        }

        var measurements: [Measurement] = []
        for deviceIndex in devices.indices {
            let device = devices[deviceIndex]
            measurements.append(Measurement(uid: device.uid,
                                            deviceName: device.name,
                                            confidence: perDeviceConfidence[deviceIndex] ?? 0,
                                            relativeLatencySeconds: perDeviceLatency[deviceIndex] ?? 0,
                                            delaySeconds: delayByDevice[deviceIndex] ?? 0,
                                            response: perDeviceResponse[deviceIndex] ?? []))
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
