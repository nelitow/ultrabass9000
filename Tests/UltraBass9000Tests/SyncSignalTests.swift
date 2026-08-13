import XCTest
@testable import UltraBass9000

/// Acoustic alignment is only as good as its arrival detection, and a detector that latches onto a
/// reflection or a burst of room noise produces a confidently wrong delay — the worst outcome,
/// because the user cannot see that it is wrong.
final class SyncSignalTests: XCTestCase {

    private let sampleRate: Double = 48_000

    /// Deterministic noise, so a failure is reproducible rather than "sometimes".
    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
    }

    private func recording(containing reference: [Float],
                           atOffset offset: Int,
                           length: Int,
                           amplitude: Float = 1,
                           noiseLevel: Float = 0,
                           seed: UInt64 = 12_345) -> [Float] {
        var noise = Noise(seed: seed)
        var samples = [Float](repeating: 0, count: length)
        for index in 0..<length {
            samples[index] = noiseLevel * noise.next()
        }
        for index in 0..<reference.count where offset + index < length {
            samples[offset + index] += amplitude * reference[index]
        }
        return samples
    }

    // MARK: - Sweep generation

    func testSweepHasTheRequestedLength() {
        let sweep = SyncSignal.logarithmicSweep(duration: 0.25, sampleRate: sampleRate)
        XCTAssertEqual(sweep.count, Int(0.25 * sampleRate))
    }

    /// A sweep that starts at full amplitude begins with a step, which is an audible click and a
    /// broadband smear across the measurement.
    func testSweepStartsAndEndsAtSilence() {
        let sweep = SyncSignal.logarithmicSweep(sampleRate: sampleRate)
        XCTAssertEqual(sweep.first ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(sweep.last ?? 1, 0, accuracy: 0.01)
        XCTAssertGreaterThan(sweep.map(abs).max() ?? 0, 0.9)
    }

    func testSweepIsFiniteEverywhere() {
        let sweep = SyncSignal.logarithmicSweep(sampleRate: sampleRate)
        XCTAssertTrue(sweep.allSatisfy(\.isFinite))
    }

    func testDegenerateSweepParametersProduceNothingRatherThanGarbage() {
        XCTAssertTrue(SyncSignal.logarithmicSweep(duration: 0, sampleRate: sampleRate).isEmpty)
        XCTAssertTrue(SyncSignal.logarithmicSweep(sampleRate: 0).isEmpty)
        XCTAssertTrue(SyncSignal.logarithmicSweep(from: 8_000, to: 200, sampleRate: sampleRate).isEmpty)
    }

    // MARK: - Arrival detection

    func testFindsAKnownOffsetExactly() {
        let sweep = SyncSignal.logarithmicSweep(duration: 0.2, sampleRate: sampleRate)
        for offset in [0, 1, 733, 12_000] {
            let capture = recording(containing: sweep, atOffset: offset, length: sweep.count + 20_000)
            let detection = SyncSignal.findOffset(reference: sweep, in: capture)
            XCTAssertEqual(detection?.offsetFrames, offset, "offset \(offset)")
            XCTAssertGreaterThan(detection?.confidence ?? 0, 0.9)
        }
    }

    /// A speaker across the room arrives quiet. Level must not affect the reported time.
    func testAttenuationDoesNotMoveTheDetectedOffset() {
        let sweep = SyncSignal.logarithmicSweep(duration: 0.2, sampleRate: sampleRate)
        let capture = recording(containing: sweep, atOffset: 5_000,
                                length: sweep.count + 20_000, amplitude: 0.02)
        let detection = SyncSignal.findOffset(reference: sweep, in: capture)
        XCTAssertEqual(detection?.offsetFrames, 5_000)
    }

    func testSurvivesRoomNoiseAtRealisticLevels() {
        let sweep = SyncSignal.logarithmicSweep(duration: 0.3, sampleRate: sampleRate)
        let capture = recording(containing: sweep, atOffset: 8_000, length: sweep.count + 30_000,
                                amplitude: 0.1, noiseLevel: 0.05)
        let detection = SyncSignal.findOffset(reference: sweep, in: capture)
        // Within a millisecond is far tighter than the ear can resolve.
        XCTAssertNotNil(detection)
        XCTAssertLessThan(abs((detection?.offsetFrames ?? 0) - 8_000), 48)
        XCTAssertGreaterThan(detection?.confidence ?? 0, SyncSignal.confidenceThreshold)
    }

    /// A device that produced nothing — muted, unplugged, or headphones the microphone cannot hear
    /// — must be rejected rather than reported at whatever lag the noise happened to favour.
    func testPureNoiseIsRejectedByTheConfidenceThreshold() {
        let sweep = SyncSignal.logarithmicSweep(duration: 0.3, sampleRate: sampleRate)
        var noise = Noise(seed: 99)
        let capture = (0..<(sweep.count + 30_000)).map { _ in noise.next() * 0.2 }
        let detection = SyncSignal.findOffset(reference: sweep, in: capture)
        XCTAssertLessThan(detection?.confidence ?? 0, SyncSignal.confidenceThreshold)
    }

    func testSilentRecordingReturnsNothing() {
        let sweep = SyncSignal.logarithmicSweep(duration: 0.2, sampleRate: sampleRate)
        let capture = [Float](repeating: 0, count: sweep.count + 1_000)
        XCTAssertNil(SyncSignal.findOffset(reference: sweep, in: capture))
    }

    func testRecordingShorterThanTheReferenceReturnsNothing() {
        let sweep = SyncSignal.logarithmicSweep(duration: 0.2, sampleRate: sampleRate)
        XCTAssertNil(SyncSignal.findOffset(reference: sweep, in: Array(sweep.prefix(100))))
        XCTAssertNil(SyncSignal.findOffset(reference: [], in: sweep))
    }

    // MARK: - Turning arrivals into delays

    func testEveryDeviceIsHeldBackToMatchTheSlowest() {
        let delays = SyncSignal.alignmentDelays(relativeLatencies: [0.010, 0.034, 0.022])
        for (actual, want) in zip(delays, [0.024, 0, 0.012]) {
            XCTAssertEqual(actual, want, accuracy: 1e-12)
        }
    }

    func testAlreadyAlignedDevicesGetNoDelay() {
        XCTAssertEqual(SyncSignal.alignmentDelays(relativeLatencies: [0.05, 0.05]), [0, 0])
    }

    func testSingleDeviceNeedsNoDelay() {
        XCTAssertEqual(SyncSignal.alignmentDelays(relativeLatencies: [0.1234]), [0])
        XCTAssertEqual(SyncSignal.alignmentDelays(relativeLatencies: []), [])
    }

    /// The whole method rests on this: microphone latency, ADC buffering, the gap between starting
    /// the recorder and starting playback, and any bias in the correlation are one constant shared
    /// by every device, so they vanish in the differences. This is why the measurement has to be a
    /// single unbroken recording rather than a start/stop per device.
    func testAConstantMeasurementBiasCancelsOut() {
        let latencies = [0.010, 0.034, 0.022]
        let unbiased = SyncSignal.alignmentDelays(relativeLatencies: latencies)
        let biased = SyncSignal.alignmentDelays(relativeLatencies: latencies.map { $0 + 0.1618 })
        for (a, b) in zip(unbiased, biased) {
            XCTAssertEqual(a, b, accuracy: 1e-12)
        }
    }

    // MARK: - Mixed sample rates

    /// The built-in microphone can sit at 44.1 kHz while the output aggregate runs at 48 kHz.
    /// Frame counts from the two sides are not comparable, so everything meets in seconds.
    func testRelativeLatencyIsCorrectAcrossDifferentCaptureAndPlaybackRates() {
        // Scheduled one second into playback at 48 kHz, heard 1.02 s into capture at 44.1 kHz.
        let latency = SyncSignal.relativeLatencySeconds(arrivalFrames: Int(1.02 * 44_100),
                                                        captureSampleRate: 44_100,
                                                        scheduledPlaybackFrames: 48_000,
                                                        playbackSampleRate: 48_000)
        XCTAssertEqual(latency ?? 0, 0.02, accuracy: 1e-4)
    }

    func testRelativeLatencyRejectsNonsenseSampleRates() {
        XCTAssertNil(SyncSignal.relativeLatencySeconds(arrivalFrames: 100, captureSampleRate: 0,
                                                        scheduledPlaybackFrames: 0,
                                                        playbackSampleRate: 48_000))
        XCTAssertNil(SyncSignal.relativeLatencySeconds(arrivalFrames: 100, captureSampleRate: 48_000,
                                                        scheduledPlaybackFrames: 0,
                                                        playbackSampleRate: 0))
    }

    /// End to end at mismatched rates: three devices scheduled 1.5 s apart, each heard after its
    /// own latency plus a shared constant, must come back with the right alignment.
    func testEndToEndAlignmentAtMismatchedRates() {
        let playbackRate = 48_000.0
        let captureRate = 44_100.0
        let sharedBias = 0.031          // mic latency, ADC buffering, recorder start offset
        let trueLatencies = [0.004, 0.180, 0.045]

        let relatives = trueLatencies.enumerated().map { index, latency -> Double in
            let scheduledPlaybackFrames = Int(Double(index) * 1.5 * playbackRate)
            let scheduledSeconds = Double(scheduledPlaybackFrames) / playbackRate
            let arrivalFrames = Int((scheduledSeconds + latency + sharedBias) * captureRate)
            return SyncSignal.relativeLatencySeconds(arrivalFrames: arrivalFrames,
                                                     captureSampleRate: captureRate,
                                                     scheduledPlaybackFrames: scheduledPlaybackFrames,
                                                     playbackSampleRate: playbackRate) ?? 0
        }

        let delays = SyncSignal.alignmentDelays(relativeLatencies: relatives)
        let expected = SyncSignal.alignmentDelays(relativeLatencies: trueLatencies)
        for (actual, want) in zip(delays, expected) {
            XCTAssertEqual(actual, want, accuracy: 1e-4)
        }
    }
}
