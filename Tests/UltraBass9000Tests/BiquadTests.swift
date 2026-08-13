import XCTest
@testable import UltraBass9000

/// Filter maths fails quietly: a wrong coefficient sounds "a bit off" rather than broken, and an
/// unstable one only reveals itself as a scream at full scale. These assert the actual response.
final class BiquadTests: XCTestCase {

    private let sampleRate: Double = 48_000

    private func decibels(_ coefficients: BiquadCoefficients, at frequency: Double) -> Double {
        let omega = 2 * .pi * frequency / sampleRate
        return 20 * log10(coefficients.magnitude(atAngularFrequency: omega))
    }

    // MARK: - Identity

    func testIdentityPassesEveryFrequencyUntouched() {
        for frequency in [20.0, 200, 2_000, 20_000] {
            XCTAssertEqual(decibels(.identity, at: frequency), 0, accuracy: 1e-9)
        }
    }

    // MARK: - Peaking

    func testPeakingHitsItsGainAtTheCentreFrequency() {
        for gain in [-18.0, -6, 3, 12] {
            let filter = BiquadDesign.peaking(frequency: 1_000, gainDB: gain, q: 1, sampleRate: sampleRate)
            XCTAssertEqual(decibels(filter, at: 1_000), gain, accuracy: 0.05,
                           "peaking at \(gain) dB")
        }
    }

    func testPeakingIsTransparentFarFromItsCentre() {
        let filter = BiquadDesign.peaking(frequency: 1_000, gainDB: 12, q: 2, sampleRate: sampleRate)
        XCTAssertEqual(decibels(filter, at: 40), 0, accuracy: 0.5)
        XCTAssertEqual(decibels(filter, at: 16_000), 0, accuracy: 0.5)
    }

    func testHigherQNarrowsThePeak() {
        let wide = BiquadDesign.peaking(frequency: 1_000, gainDB: 12, q: 0.5, sampleRate: sampleRate)
        let narrow = BiquadDesign.peaking(frequency: 1_000, gainDB: 12, q: 8, sampleRate: sampleRate)
        XCTAssertGreaterThan(decibels(wide, at: 500), decibels(narrow, at: 500))
        XCTAssertEqual(decibels(wide, at: 1_000), decibels(narrow, at: 1_000), accuracy: 0.05)
    }

    // MARK: - Low-pass and high-pass

    /// A Butterworth-Q low-pass is 3 dB down at its corner. That is the definition of the corner,
    /// and getting it wrong means every frequency readout in the UI lies.
    func testLowPassIsThreeDecibelsDownAtCorner() {
        let filter = BiquadDesign.lowPass(frequency: 1_000, q: 0.7071, sampleRate: sampleRate)
        XCTAssertEqual(decibels(filter, at: 1_000), -3.01, accuracy: 0.1)
    }

    func testLowPassPassesBelowAndRejectsAbove() {
        let filter = BiquadDesign.lowPass(frequency: 1_000, q: 0.7071, sampleRate: sampleRate)
        XCTAssertEqual(decibels(filter, at: 100), 0, accuracy: 0.15)
        XCTAssertLessThan(decibels(filter, at: 10_000), -35)
    }

    func testHighPassIsThreeDecibelsDownAtCorner() {
        let filter = BiquadDesign.highPass(frequency: 1_000, q: 0.7071, sampleRate: sampleRate)
        XCTAssertEqual(decibels(filter, at: 1_000), -3.01, accuracy: 0.1)
    }

    func testHighPassRejectsBelowAndPassesAbove() {
        let filter = BiquadDesign.highPass(frequency: 1_000, q: 0.7071, sampleRate: sampleRate)
        XCTAssertLessThan(decibels(filter, at: 100), -35)
        XCTAssertEqual(decibels(filter, at: 10_000), 0, accuracy: 0.15)
    }

    // MARK: - Band-pass

    /// The constant-peak-gain variant, so switching a band-pass on does not also change the level.
    func testBandPassIsUnityAtCentre() {
        let filter = BiquadDesign.bandPass(frequency: 1_000, q: 1, sampleRate: sampleRate)
        XCTAssertEqual(decibels(filter, at: 1_000), 0, accuracy: 0.05)
    }

    func testBandPassRejectsBothExtremes() {
        let filter = BiquadDesign.bandPass(frequency: 1_000, q: 2, sampleRate: sampleRate)
        XCTAssertLessThan(decibels(filter, at: 60), -20)
        XCTAssertLessThan(decibels(filter, at: 16_000), -20)
    }

    func testNotchRejectsItsCentre() {
        let filter = BiquadDesign.notch(frequency: 1_000, q: 8, sampleRate: sampleRate)
        XCTAssertLessThan(decibels(filter, at: 1_000), -40)
        XCTAssertEqual(decibels(filter, at: 100), 0, accuracy: 0.2)
    }

    // MARK: - Shelves

    func testLowShelfLiftsTheBottomAndLeavesTheTop() {
        let filter = BiquadDesign.lowShelf(frequency: 200, gainDB: 6, q: 0.7071, sampleRate: sampleRate)
        XCTAssertEqual(decibels(filter, at: 20), 6, accuracy: 0.4)
        XCTAssertEqual(decibels(filter, at: 200), 3, accuracy: 0.3)
        XCTAssertEqual(decibels(filter, at: 10_000), 0, accuracy: 0.2)
    }

    func testHighShelfLiftsTheTopAndLeavesTheBottom() {
        let filter = BiquadDesign.highShelf(frequency: 4_000, gainDB: 6, q: 0.7071, sampleRate: sampleRate)
        XCTAssertEqual(decibels(filter, at: 20_000), 6, accuracy: 0.4)
        XCTAssertEqual(decibels(filter, at: 4_000), 3, accuracy: 0.3)
        XCTAssertEqual(decibels(filter, at: 50), 0, accuracy: 0.2)
    }

    func testShelvesCutAsWellAsBoost() {
        let filter = BiquadDesign.lowShelf(frequency: 200, gainDB: -9, q: 0.7071, sampleRate: sampleRate)
        XCTAssertEqual(decibels(filter, at: 20), -9, accuracy: 0.4)
    }

    // MARK: - Robustness

    /// A user dragging a handle will reach both ends of every range, and a Bluetooth device can
    /// renegotiate to a lower sample rate underneath a filter that was designed for a higher one.
    func testEveryDesignStaysStableAcrossTheWholeParameterSweep() {
        let rates: [Double] = [44_100, 48_000, 96_000]
        let frequencies: [Double] = [1, 20, 1_000, 20_000, 44_100, 1_000_000]
        let qs: [Double] = [0.01, 0.1, 0.7071, 8, 18, 1_000]
        let gains: [Double] = [-24, -6, 0, 6, 24]

        for rate in rates {
            for frequency in frequencies {
                for q in qs {
                    let designs: [BiquadCoefficients] = [
                        BiquadDesign.lowPass(frequency: frequency, q: q, sampleRate: rate),
                        BiquadDesign.highPass(frequency: frequency, q: q, sampleRate: rate),
                        BiquadDesign.bandPass(frequency: frequency, q: q, sampleRate: rate),
                        BiquadDesign.notch(frequency: frequency, q: q, sampleRate: rate),
                    ] + gains.flatMap { gain in
                        [
                            BiquadDesign.peaking(frequency: frequency, gainDB: gain, q: q, sampleRate: rate),
                            BiquadDesign.lowShelf(frequency: frequency, gainDB: gain, q: q, sampleRate: rate),
                            BiquadDesign.highShelf(frequency: frequency, gainDB: gain, q: q, sampleRate: rate),
                        ]
                    }

                    for design in designs {
                        XCTAssertTrue(design.isStable,
                                      "unstable at rate=\(rate) f=\(frequency) q=\(q): \(design)")
                        XCTAssertTrue(design.b0.isFinite && design.b1.isFinite && design.b2.isFinite
                                        && design.a1.isFinite && design.a2.isFinite,
                                      "non-finite at rate=\(rate) f=\(frequency) q=\(q)")
                    }
                }
            }
        }
    }

    func testFrequencyAboveNyquistIsClampedRatherThanProducingGarbage() {
        let filter = BiquadDesign.lowPass(frequency: 96_000, q: 0.7071, sampleRate: sampleRate)
        XCTAssertTrue(filter.isStable)
        // Clamped just under Nyquist, so it should be very nearly a pass-through.
        XCTAssertEqual(decibels(filter, at: 1_000), 0, accuracy: 0.5)
    }

    func testZeroSampleRateFallsBackToIdentityInsteadOfCrashing() {
        let filter = BiquadDesign.peaking(frequency: 1_000, gainDB: 6, q: 1, sampleRate: 0)
        XCTAssertEqual(filter, .identity)
    }
}
