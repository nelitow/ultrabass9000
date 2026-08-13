import XCTest
@testable import UltraBass9000

/// The response curve is the one output a user will act on — deciding a crossover point from it —
/// so it has to recover a filter it was never told about. Each test builds a synthetic "device" by
/// putting the sweep through a known filter, then checks the measurement finds that filter.
final class ResponseAnalyzerTests: XCTestCase {

    private let sampleRate: Double = 48_000

    private lazy var sweep: [Float] = SyncSignal.logarithmicSweep(duration: 0.6,
                                                                  from: 30,
                                                                  to: 16_000,
                                                                  sampleRate: sampleRate)

    /// Runs a signal through a biquad chain, as a device and room would.
    private func filtered(_ input: [Float], through chain: [BiquadCoefficients]) -> [Float] {
        var output = input
        for coefficients in chain {
            var z1: Float = 0
            var z2: Float = 0
            for index in output.indices {
                let x = output[index]
                let y = coefficients.b0 * x + z1
                z1 = coefficients.b1 * x - coefficients.a1 * y + z2
                z2 = coefficients.b2 * x - coefficients.a2 * y
                output[index] = y
            }
        }
        return output
    }

    private func decibels(_ points: [ResponsePoint], near frequency: Double) -> Double? {
        points.min { abs($0.frequency - frequency) < abs($1.frequency - frequency) }?.decibels
    }

    // MARK: - Baseline

    func testAnIdenticalRecordingMeasuresFlat() {
        let points = ResponseAnalyzer.response(recorded: sweep, reference: sweep,
                                               sampleRate: sampleRate)
        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertEqual(point.decibels, 0, accuracy: 0.5, "at \(point.frequency) Hz")
        }
    }

    /// A device that is simply quieter is not a device with a different response. Level is removed
    /// so two devices at different volumes can be compared on one plot.
    func testOverallLevelDoesNotChangeTheShape() {
        let quiet = sweep.map { $0 * 0.05 }
        let points = ResponseAnalyzer.response(recorded: quiet, reference: sweep,
                                               sampleRate: sampleRate)
        for point in points {
            XCTAssertEqual(point.decibels, 0, accuracy: 0.5, "at \(point.frequency) Hz")
        }
    }

    func testEmptyInputProducesNoCurveRatherThanCrashing() {
        XCTAssertTrue(ResponseAnalyzer.response(recorded: [], reference: sweep,
                                                sampleRate: sampleRate).isEmpty)
        XCTAssertTrue(ResponseAnalyzer.response(recorded: sweep, reference: [],
                                                sampleRate: sampleRate).isEmpty)
        XCTAssertTrue(ResponseAnalyzer.response(recorded: sweep, reference: sweep,
                                                sampleRate: 0).isEmpty)
    }

    // MARK: - Recovering a known response

    /// The headline case: a device with no bass. This is what tells the user their laptop speakers
    /// roll off and their subwoofer does not.
    func testRecoversAHighPassedDevice() {
        let chain = BiquadDesign.highPassCascade(frequency: 500, order: 4, sampleRate: sampleRate)
        let recorded = filtered(sweep, through: chain)
        let points = ResponseAnalyzer.response(recorded: recorded, reference: sweep,
                                               sampleRate: sampleRate)

        // Well below the corner it must read clearly down; well above, level.
        let low = try? XCTUnwrap(decibels(points, near: 100))
        let high = try? XCTUnwrap(decibels(points, near: 4_000))
        XCTAssertNotNil(low)
        XCTAssertNotNil(high)
        XCTAssertLessThan((low ?? 0) - (high ?? 0), -20)
    }

    func testRecoversALowPassedDevice() {
        let chain = BiquadDesign.lowPassCascade(frequency: 1_000, order: 4, sampleRate: sampleRate)
        let recorded = filtered(sweep, through: chain)
        let points = ResponseAnalyzer.response(recorded: recorded, reference: sweep,
                                               sampleRate: sampleRate)

        let low = decibels(points, near: 200) ?? 0
        let high = decibels(points, near: 8_000) ?? 0
        XCTAssertGreaterThan(low - high, 20)
    }

    /// The measured slope should follow the real one, not merely go down.
    func testMeasuredRolloffTracksTheActualFilterSlope() {
        let chain = BiquadDesign.lowPassCascade(frequency: 500, order: 2, sampleRate: sampleRate)
        let recorded = filtered(sweep, through: chain)
        let points = ResponseAnalyzer.response(recorded: recorded, reference: sweep,
                                               sampleRate: sampleRate)

        // One octave apart, both inside the stopband: a 12 dB/oct filter should show ~12 dB.
        let atTwo = decibels(points, near: 2_000) ?? 0
        let atFour = decibels(points, near: 4_000) ?? 0
        XCTAssertEqual(atTwo - atFour, 12, accuracy: 4)
    }

    func testRecoversAMidrangePeak() {
        let peak = BiquadDesign.peaking(frequency: 1_000, gainDB: 12, q: 2, sampleRate: sampleRate)
        let recorded = filtered(sweep, through: [peak])
        let points = ResponseAnalyzer.response(recorded: recorded, reference: sweep,
                                               sampleRate: sampleRate)

        let atPeak = decibels(points, near: 1_000) ?? 0
        let away = decibels(points, near: 200) ?? 0
        XCTAssertGreaterThan(atPeak - away, 8)
    }

    /// Two devices measured against the same reference must be comparable to each other — that
    /// comparison is the whole reason the feature exists.
    func testTwoDevicesCanBeComparedAgainstEachOther() {
        let woofer = filtered(sweep, through: BiquadDesign.lowPassCascade(frequency: 200, order: 4,
                                                                          sampleRate: sampleRate))
        let tweeter = filtered(sweep, through: BiquadDesign.highPassCascade(frequency: 2_000, order: 4,
                                                                            sampleRate: sampleRate))
        let wooferCurve = ResponseAnalyzer.response(recorded: woofer, reference: sweep,
                                                    sampleRate: sampleRate)
        let tweeterCurve = ResponseAnalyzer.response(recorded: tweeter, reference: sweep,
                                                     sampleRate: sampleRate)

        // At 80 Hz the woofer wins; at 8 kHz the tweeter does.
        XCTAssertGreaterThan((decibels(wooferCurve, near: 80) ?? 0),
                             (decibels(tweeterCurve, near: 80) ?? 0) + 20)
        XCTAssertGreaterThan((decibels(tweeterCurve, near: 8_000) ?? 0),
                             (decibels(wooferCurve, near: 8_000) ?? 0) + 20)
    }

    // MARK: - Band layout

    func testBandsAreLogarithmicallySpacedAcrossTheAudibleRange() {
        let points = ResponseAnalyzer.response(recorded: sweep, reference: sweep,
                                               sampleRate: sampleRate)
        XCTAssertGreaterThan(points.count, 30)

        let ratios = zip(points, points.dropFirst()).map { $1.frequency / $0.frequency }
        let expected = pow(2.0, 1.0 / Double(ResponseAnalyzer.bandsPerOctave))
        for ratio in ratios {
            XCTAssertEqual(ratio, expected, accuracy: 0.001)
        }
        XCTAssertGreaterThanOrEqual(points.first?.frequency ?? 0, ResponseAnalyzer.lowestFrequency)
        XCTAssertLessThanOrEqual(points.last?.frequency ?? 0, ResponseAnalyzer.highestFrequency)
    }

    /// Frequencies the sweep never contained carry no information, and dividing by that near-zero
    /// excitation would produce a large, confident, meaningless number.
    func testBandsOutsideTheSweepAreOmittedRatherThanInvented() {
        let narrow = SyncSignal.logarithmicSweep(duration: 0.6, from: 500, to: 2_000,
                                                 sampleRate: sampleRate)
        let points = ResponseAnalyzer.response(recorded: narrow, reference: narrow,
                                               sampleRate: sampleRate)
        XCTAssertFalse(points.isEmpty)
        // Nothing reported an octave outside the swept range.
        XCTAssertTrue(points.allSatisfy { $0.frequency > 200 && $0.frequency < 5_000 },
                      "reported \(points.map(\.frequency))")
    }
}
