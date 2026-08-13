import XCTest
@testable import UltraBass9000

final class DeviceProcessingTests: XCTestCase {

    private let sampleRate: Double = 48_000

    // MARK: - Compilation

    func testNeutralProcessingCompilesToNothing() {
        XCTAssertTrue(DeviceProcessing.neutral.compile(sampleRate: sampleRate).isEmpty)
        XCTAssertTrue(DeviceProcessing.neutral.isNeutral)
    }

    /// A band at 0 dB is mathematically transparent, so compiling it would spend a biquad per
    /// sample per channel per device to multiply by one.
    func testFlatBandsAreDroppedRatherThanCompiledToIdentity() {
        var processing = DeviceProcessing.neutral
        processing.bands[2].gainDB = 6
        XCTAssertEqual(processing.compile(sampleRate: sampleRate).count, 1)
    }

    func testDisabledBandsAreDropped() {
        var processing = DeviceProcessing.neutral
        processing.bands[1].gainDB = 6
        processing.bands[1].isEnabled = false
        XCTAssertTrue(processing.compile(sampleRate: sampleRate).isEmpty)
    }

    func testDisablingTheEQKeepsTheFiltersRunning() {
        var processing = DeviceProcessing.neutral
        processing.bands[2].gainDB = 9
        processing.eqEnabled = false
        processing.highPass.isEnabled = true
        let chain = processing.compile(sampleRate: sampleRate)
        XCTAssertEqual(chain.count, 1)
        XCTAssertFalse(processing.isNeutral)
    }

    func testFiltersCompileInSignalOrderAfterTheEQ() {
        var processing = DeviceProcessing.neutral
        processing.bands[0].gainDB = 3
        processing.highPass.isEnabled = true
        processing.lowPass.isEnabled = true
        processing.bandPass.isEnabled = true

        let chain = processing.compile(sampleRate: sampleRate)
        XCTAssertEqual(chain.count, 4)

        // The three filters occupy the last three slots, in HP, LP, BP order.
        let expectedHighPass = BiquadDesign.highPass(frequency: processing.highPass.frequency,
                                                     q: processing.highPass.q,
                                                     sampleRate: sampleRate)
        XCTAssertEqual(chain[1], expectedHighPass)
    }

    func testEveryBandAndFilterFitsWithinTheHardwareSectionLimit() {
        var processing = DeviceProcessing.neutral
        for index in processing.bands.indices { processing.bands[index].gainDB = 6 }
        processing.highPass.isEnabled = true
        processing.lowPass.isEnabled = true
        processing.bandPass.isEnabled = true
        XCTAssertLessThanOrEqual(processing.compile(sampleRate: sampleRate).count, FilterBank.maxSections)
    }

    // MARK: - Response

    func testResponseIsFlatWhenNothingIsEngaged() {
        let response = DeviceProcessing.neutral.magnitudeResponse(at: [50, 500, 5_000],
                                                                  sampleRate: sampleRate)
        XCTAssertEqual(response, [0, 0, 0])
    }

    func testResponseReflectsAnEngagedBand() {
        var processing = DeviceProcessing.neutral
        processing.bands[2] = EQBand(id: 2, kind: .peaking, frequency: 1_000, gainDB: 8, q: 2,
                                     isEnabled: true)
        let response = processing.magnitudeResponse(at: [1_000], sampleRate: sampleRate)
        XCTAssertEqual(response[0], 8, accuracy: 0.1)
    }

    /// The drawn curve has to include the filters, not just the EQ, or the user sees a flat line
    /// while hearing a high-pass.
    func testResponseIncludesTheFilterSections() {
        var processing = DeviceProcessing.neutral
        processing.highPass = FilterSetting(isEnabled: true, frequency: 1_000, q: 0.7071)
        let response = processing.magnitudeResponse(at: [100, 1_000], sampleRate: sampleRate)
        XCTAssertLessThan(response[0], -35)
        XCTAssertEqual(response[1], -3.01, accuracy: 0.15)
    }

    // MARK: - Normalisation and persistence

    func testNormaliseRepairsAPreferenceFileWrittenByAnOlderBuild() {
        let truncated = DeviceProcessing(eqEnabled: true,
                                         bands: [EQBand(id: 0, kind: .peaking, frequency: 500,
                                                        gainDB: 3, q: 1, isEnabled: true)],
                                         highPass: FilterSetting(isEnabled: false, frequency: 80),
                                         lowPass: FilterSetting(isEnabled: false, frequency: 12_000),
                                         bandPass: FilterSetting(isEnabled: false, frequency: 1_000))
        let repaired = truncated.normalised
        XCTAssertEqual(repaired.bands.count, DeviceProcessing.bandCount)
        XCTAssertEqual(repaired.bands.map(\.id), Array(0..<DeviceProcessing.bandCount))
        // The surviving band keeps its settings rather than being reset.
        XCTAssertEqual(repaired.bands[0].frequency, 500)
        XCTAssertEqual(repaired.bands[0].gainDB, 3)
    }

    func testNormaliseClampsOutOfRangeValuesFromADrag() {
        var processing = DeviceProcessing.neutral
        processing.bands[0].frequency = 500_000
        processing.bands[0].gainDB = 200
        processing.bands[0].q = -4
        let repaired = processing.normalised
        XCTAssertEqual(repaired.bands[0].frequency, EQBand.frequencyRange.upperBound)
        XCTAssertEqual(repaired.bands[0].gainDB, EQBand.gainRange.upperBound)
        XCTAssertEqual(repaired.bands[0].q, EQBand.qRange.lowerBound)
    }

    func testProcessingSurvivesAnEncodeDecodeRoundTrip() throws {
        var processing = DeviceProcessing.neutral
        processing.bands[3] = EQBand(id: 3, kind: .highShelf, frequency: 6_000, gainDB: -4.5,
                                     q: 1.2, isEnabled: true)
        processing.lowPass = FilterSetting(isEnabled: true, frequency: 8_000, q: 1.1)

        let data = try JSONEncoder().encode(["device": processing])
        let decoded = try JSONDecoder().decode([String: DeviceProcessing].self, from: data)
        XCTAssertEqual(decoded["device"], processing)
    }

    func testActiveFilterNamesReportOnlyWhatIsEngaged() {
        var processing = DeviceProcessing.neutral
        XCTAssertTrue(processing.activeFilterNames.isEmpty)
        processing.highPass.isEnabled = true
        processing.bandPass.isEnabled = true
        XCTAssertEqual(processing.activeFilterNames, ["HP", "BP"])
    }
}
