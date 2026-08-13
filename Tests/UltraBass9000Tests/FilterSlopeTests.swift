import XCTest
@testable import UltraBass9000

/// A slope control is only honest if the filter actually falls at the rate printed on it. These
/// measure the response an octave apart and check the difference against the label.
final class FilterSlopeTests: XCTestCase {

    private let sampleRate: Double = 48_000

    /// Tolerance scales with the slope.
    ///
    /// A bilinear-transformed low-pass carries a zero at Nyquist, so its measured rolloff is always
    /// slightly steeper than the analog asymptote it is named after, and the excess grows with
    /// order. That is correct behaviour for a digital filter, not an error to design out — the
    /// assertion just has to allow for it.
    private func tolerance(for slope: FilterSlope) -> Double {
        max(1.0, Double(slope.rawValue) * 0.06)
    }

    private func decibels(_ chain: [BiquadCoefficients], at frequency: Double) -> Double {
        let omega = 2 * .pi * frequency / sampleRate
        let linear = chain.reduce(1.0) { $0 * $1.magnitude(atAngularFrequency: omega) }
        return linear > 0 ? 20 * log10(linear) : -300
    }

    // MARK: - Slope is what it says

    func testHighPassFallsAtItsStatedRatePerOctave() {
        for slope in FilterSlope.allCases {
            let chain = BiquadDesign.highPassCascade(frequency: 1_000,
                                                     order: slope.order,
                                                     sampleRate: sampleRate)
            // Two and one octaves below the corner, deep enough to be in the asymptote.
            let lower = decibels(chain, at: 250)
            let upper = decibels(chain, at: 500)
            XCTAssertEqual(upper - lower, Double(slope.rawValue), accuracy: tolerance(for: slope),
                           "\(slope.displayName) high-pass")
        }
    }

    func testLowPassFallsAtItsStatedRatePerOctave() {
        for slope in FilterSlope.allCases {
            let chain = BiquadDesign.lowPassCascade(frequency: 1_000,
                                                    order: slope.order,
                                                    sampleRate: sampleRate)
            let lower = decibels(chain, at: 2_000)
            let upper = decibels(chain, at: 4_000)
            XCTAssertEqual(lower - upper, Double(slope.rawValue), accuracy: tolerance(for: slope),
                           "\(slope.displayName) low-pass")
        }
    }

    /// Every Butterworth order passes through −3 dB at its corner. Giving each section Q = 0.707
    /// instead of the correct per-section Q would droop well past that.
    func testEveryOrderIsThreeDecibelsDownAtTheCorner() {
        for slope in FilterSlope.allCases {
            let highPass = BiquadDesign.highPassCascade(frequency: 1_000, order: slope.order,
                                                        sampleRate: sampleRate)
            let lowPass = BiquadDesign.lowPassCascade(frequency: 1_000, order: slope.order,
                                                      sampleRate: sampleRate)
            XCTAssertEqual(decibels(highPass, at: 1_000), -3.01, accuracy: 0.25, slope.displayName)
            XCTAssertEqual(decibels(lowPass, at: 1_000), -3.01, accuracy: 0.25, slope.displayName)
        }
    }

    /// A maximally flat passband is the entire point of Butterworth; a wrong Q shows up here as
    /// ripple long before it shows up in the slope.
    func testPassbandStaysFlat() {
        let chain = BiquadDesign.lowPassCascade(frequency: 10_000, order: 8, sampleRate: sampleRate)
        for probe in [50.0, 200, 800, 2_000] {
            XCTAssertEqual(decibels(chain, at: probe), 0, accuracy: 0.15, "at \(probe) Hz")
        }
    }

    func testSectionCountMatchesTheOrder() {
        XCTAssertEqual(FilterSlope.db6.sectionCount, 1)
        XCTAssertEqual(FilterSlope.db12.sectionCount, 1)
        XCTAssertEqual(FilterSlope.db24.sectionCount, 2)
        XCTAssertEqual(FilterSlope.db36.sectionCount, 3)
        XCTAssertEqual(FilterSlope.db48.sectionCount, 4)

        for slope in FilterSlope.allCases {
            let chain = BiquadDesign.lowPassCascade(frequency: 1_000, order: slope.order,
                                                    sampleRate: sampleRate)
            XCTAssertEqual(chain.count, slope.sectionCount, slope.displayName)
            XCTAssertTrue(chain.allSatisfy(\.isStable), slope.displayName)
        }
    }

    // MARK: - Band-pass

    private func bandChain(_ setting: BandPassSetting) -> [BiquadCoefficients] {
        var processing = DeviceProcessing.neutral
        processing.bandPass = setting
        return processing.compile(sampleRate: sampleRate)
    }

    func testBandPassIsThreeDecibelsDownAtBothEdges() {
        let chain = bandChain(BandPassSetting(isEnabled: true, lowFrequency: 200,
                                              highFrequency: 4_000, slope: .db12))
        XCTAssertEqual(decibels(chain, at: 200), -3.01, accuracy: 0.3)
        XCTAssertEqual(decibels(chain, at: 4_000), -3.01, accuracy: 0.3)
    }

    func testBandPassPassesTheMiddleUntouched() {
        let chain = bandChain(BandPassSetting(isEnabled: true, lowFrequency: 200,
                                              highFrequency: 4_000, slope: .db24))
        XCTAssertEqual(decibels(chain, at: 900), 0, accuracy: 0.3)
    }

    func testBandPassRejectsOutsideAtTheStatedSlope() {
        let chain = bandChain(BandPassSetting(isEnabled: true, lowFrequency: 500,
                                              highFrequency: 2_000, slope: .db24))
        // An octave apart, below the lower edge.
        XCTAssertEqual(decibels(chain, at: 250) - decibels(chain, at: 125), 24, accuracy: 1.5)
        // An octave apart, above the upper edge. Both probes stay well below Nyquist — measuring
        // past it does not describe a steeper filter, it describes nothing at all.
        //
        // Wider tolerance on this side, and only in one direction: the low-pass half carries a zero
        // at Nyquist, so the closer a probe sits to it the steeper the measured rolloff becomes.
        // The filter is never shallower than its label, which is the property that matters.
        let upperSlope = decibels(chain, at: 4_000) - decibels(chain, at: 8_000)
        XCTAssertGreaterThanOrEqual(upperSlope, 24 - 1.5)
        XCTAssertLessThanOrEqual(upperSlope, 24 * 1.25)
    }

    func testWiderBandsPassMoreThanNarrowOnes() {
        let wide = bandChain(BandPassSetting(isEnabled: true, lowFrequency: 100,
                                             highFrequency: 10_000, slope: .db12))
        let narrow = bandChain(BandPassSetting(isEnabled: true, lowFrequency: 900,
                                               highFrequency: 1_100, slope: .db12))
        XCTAssertEqual(decibels(wide, at: 300), 0, accuracy: 0.5)
        XCTAssertLessThan(decibels(narrow, at: 300), -15)
    }

    // MARK: - Edge handling

    /// Dragging the upper edge below the lower one would silently turn a band-pass into a notch —
    /// filters do not care that the user meant a band.
    func testReversedEdgesAreOrderedRatherThanInverted() {
        let reversed = BandPassSetting(isEnabled: true, lowFrequency: 5_000, highFrequency: 300)
        let clamped = reversed.clamped
        XCTAssertEqual(clamped.lowFrequency, 300)
        XCTAssertEqual(clamped.highFrequency, 5_000)
    }

    func testCollapsedBandKeepsAMinimumWidth() {
        let collapsed = BandPassSetting(isEnabled: true, lowFrequency: 1_000, highFrequency: 1_000)
        XCTAssertGreaterThan(collapsed.clamped.highFrequency, collapsed.clamped.lowFrequency)
        XCTAssertGreaterThan(collapsed.widthInOctaves, 0)
    }

    func testWidthIsReportedInOctaves() {
        let band = BandPassSetting(isEnabled: true, lowFrequency: 500, highFrequency: 4_000)
        XCTAssertEqual(band.widthInOctaves, 3, accuracy: 0.001)
    }

    // MARK: - Budget and migration

    /// Every filter at its steepest must still fit the render thread's fixed-size chain.
    func testWorstCaseConfigurationFitsTheSectionBudget() {
        var processing = DeviceProcessing.neutral
        for index in processing.bands.indices { processing.bands[index].gainDB = 6 }
        processing.highPass = FilterSetting(isEnabled: true, frequency: 40, slope: .db48)
        processing.lowPass = FilterSetting(isEnabled: true, frequency: 18_000, slope: .db48)
        processing.bandPass = BandPassSetting(isEnabled: true, lowFrequency: 100,
                                              highFrequency: 8_000, slope: .db48)

        XCTAssertEqual(processing.sectionCount, processing.compile(sampleRate: sampleRate).count)
        XCTAssertLessThanOrEqual(processing.sectionCount, FilterBank.maxSections)
    }

    /// Settings saved by the build that had a centre frequency and a Q must survive the upgrade as
    /// an equivalent pair of edges, rather than being discarded.
    func testLegacyCentreAndQBandPassMigratesToEdges() throws {
        let legacy = """
        {"isEnabled":true,"frequency":1000,"q":1.0}
        """.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(BandPassSetting.self, from: legacy)

        XCTAssertTrue(migrated.isEnabled)
        // One octave wide around 1 kHz.
        XCTAssertEqual(migrated.lowFrequency, 1_000 / pow(2, 0.5), accuracy: 1)
        XCTAssertEqual(migrated.highFrequency, 1_000 * pow(2, 0.5), accuracy: 1)
    }

    func testLegacyFilterSettingWithoutSlopeGetsASensibleDefault() throws {
        let legacy = """
        {"isEnabled":true,"frequency":120,"q":0.7071}
        """.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(FilterSetting.self, from: legacy)
        XCTAssertEqual(migrated.frequency, 120)
        XCTAssertEqual(migrated.slope, .db12)
    }

    func testBandPassSurvivesAnEncodeDecodeRoundTrip() throws {
        let band = BandPassSetting(isEnabled: true, lowFrequency: 120,
                                   highFrequency: 3_500, slope: .db36)
        let data = try JSONEncoder().encode(band)
        XCTAssertEqual(try JSONDecoder().decode(BandPassSetting.self, from: data), band)
    }
}
