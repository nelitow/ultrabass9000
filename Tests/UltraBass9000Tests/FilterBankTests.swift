import XCTest
@testable import UltraBass9000

/// Exercises `FilterBank.processFrame` — the exact function the real-time thread runs — by pushing
/// sine waves through it and measuring the gain that comes out. A coefficient set can be perfect
/// while the difference equation that consumes it is wrong; only measuring the output catches that.
final class FilterBankTests: XCTestCase {

    private let sampleRate: Double = 48_000

    /// Steady-state gain of a device's chain at one frequency, measured rather than predicted.
    ///
    /// The first half of the run is discarded so the filter's transient has decayed and what
    /// remains is genuinely steady state.
    private func measuredGain(chain: [BiquadCoefficients],
                              frequency: Double,
                              deviceIndex: Int = 0,
                              frames: Int = 16_384) -> Double {
        let bank = FilterBank()
        var chains = [[BiquadCoefficients]](repeating: [], count: deviceIndex + 1)
        chains[deviceIndex] = chain
        bank.publish(chains)

        let activeBank = Int(bank.activeBank.pointee)
        let coefficientBase = FilterBank.coefficientOffset(bank: activeBank, device: deviceIndex, section: 0)
        let stateBase = FilterBank.stateOffset(device: deviceIndex, section: 0, channel: 0)
        let sectionCount = Int(bank.sectionCounts[activeBank * FilterBank.maxDevices + deviceIndex])

        var inputEnergy = 0.0
        var outputEnergy = 0.0
        let settleFrames = frames / 2

        for frame in 0..<frames {
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            let sample = Float(sin(phase))
            var left = sample
            var right = sample
            FilterBank.processFrame(left: &left,
                                    right: &right,
                                    coefficients: bank.coefficients,
                                    state: bank.state,
                                    coefficientBase: coefficientBase,
                                    stateBase: stateBase,
                                    sectionCount: sectionCount)
            guard frame >= settleFrames else { continue }
            inputEnergy += Double(sample) * Double(sample)
            outputEnergy += Double(left) * Double(left)
        }

        guard inputEnergy > 0 else { return 0 }
        return (outputEnergy / inputEnergy).squareRoot()
    }

    private func measuredDecibels(chain: [BiquadCoefficients], frequency: Double) -> Double {
        let gain = measuredGain(chain: chain, frequency: frequency)
        return gain > 0 ? 20 * log10(gain) : -200
    }

    // MARK: - The difference equation matches the predicted response

    func testEmptyChainIsUnityGain() {
        XCTAssertEqual(measuredGain(chain: [], frequency: 1_000), 1, accuracy: 1e-5)
    }

    func testMeasuredPeakingGainMatchesPredictedResponse() {
        for gain in [-12.0, -3, 6, 12] {
            let filter = BiquadDesign.peaking(frequency: 1_000, gainDB: gain, q: 1, sampleRate: sampleRate)
            XCTAssertEqual(measuredDecibels(chain: [filter], frequency: 1_000), gain, accuracy: 0.15,
                           "peaking \(gain) dB")
        }
    }

    func testMeasuredLowPassMatchesPredictedResponse() {
        let filter = BiquadDesign.lowPass(frequency: 1_000, q: 0.7071, sampleRate: sampleRate)
        for probe in [200.0, 1_000, 4_000] {
            let omega = 2 * .pi * probe / sampleRate
            let predicted = 20 * log10(filter.magnitude(atAngularFrequency: omega))
            XCTAssertEqual(measuredDecibels(chain: [filter], frequency: probe), predicted, accuracy: 0.2,
                           "at \(probe) Hz")
        }
    }

    /// Cascaded sections multiply, so a chain's dB response is the sum of its parts. If the state
    /// indexing were wrong, sections would share memory and this would diverge badly.
    func testCascadedSectionsSumInDecibels() {
        let low = BiquadDesign.peaking(frequency: 200, gainDB: 6, q: 1, sampleRate: sampleRate)
        let high = BiquadDesign.peaking(frequency: 200, gainDB: 4, q: 1, sampleRate: sampleRate)
        let measured = measuredDecibels(chain: [low, high], frequency: 200)
        XCTAssertEqual(measured, 10, accuracy: 0.25)
    }

    func testFullEightSectionChainRemainsWellBehaved() {
        let chain = (0..<8).map { index in
            BiquadDesign.peaking(frequency: 100 * pow(2, Double(index)),
                                 gainDB: 3,
                                 q: 1,
                                 sampleRate: sampleRate)
        }
        let measured = measuredDecibels(chain: chain, frequency: 1_600)
        XCTAssertGreaterThan(measured, 2.0)
        XCTAssertLessThan(measured, 8.0)
    }

    // MARK: - State isolation

    /// Every device has its own filter memory. Sharing it would make one device's bass leak into
    /// another's, which is the kind of bug that sounds like "something is a bit weird".
    func testDevicesDoNotShareFilterState() {
        let bank = FilterBank()
        let filter = BiquadDesign.lowPass(frequency: 500, q: 0.7071, sampleRate: sampleRate)
        bank.publish([[filter], []])

        let activeBank = Int(bank.activeBank.pointee)

        // Drive device 0 hard so its state is far from zero.
        var left: Float = 0, right: Float = 0
        for _ in 0..<2_000 {
            left = 1
            right = 1
            FilterBank.processFrame(left: &left, right: &right,
                                    coefficients: bank.coefficients, state: bank.state,
                                    coefficientBase: FilterBank.coefficientOffset(bank: activeBank, device: 0, section: 0),
                                    stateBase: FilterBank.stateOffset(device: 0, section: 0, channel: 0),
                                    sectionCount: 1)
        }

        // Device 1 has no sections, so it must pass its input through untouched.
        var otherLeft: Float = 0.25, otherRight: Float = -0.25
        FilterBank.processFrame(left: &otherLeft, right: &otherRight,
                                coefficients: bank.coefficients, state: bank.state,
                                coefficientBase: FilterBank.coefficientOffset(bank: activeBank, device: 1, section: 0),
                                stateBase: FilterBank.stateOffset(device: 1, section: 0, channel: 0),
                                sectionCount: 0)
        XCTAssertEqual(otherLeft, 0.25)
        XCTAssertEqual(otherRight, -0.25)
    }

    func testLeftAndRightChannelsDoNotShareFilterState() {
        let bank = FilterBank()
        let filter = BiquadDesign.lowPass(frequency: 500, q: 0.7071, sampleRate: sampleRate)
        bank.publish([[filter]])
        let activeBank = Int(bank.activeBank.pointee)
        let coefficientBase = FilterBank.coefficientOffset(bank: activeBank, device: 0, section: 0)
        let stateBase = FilterBank.stateOffset(device: 0, section: 0, channel: 0)

        // Opposite-polarity inputs must stay opposite: shared state would mix them together.
        var left: Float = 0, right: Float = 0
        for frame in 0..<512 {
            let sample = Float(sin(2 * Double.pi * 100 * Double(frame) / sampleRate))
            left = sample
            right = -sample
            FilterBank.processFrame(left: &left, right: &right,
                                    coefficients: bank.coefficients, state: bank.state,
                                    coefficientBase: coefficientBase, stateBase: stateBase,
                                    sectionCount: 1)
            XCTAssertEqual(left, -right, accuracy: 1e-6, "channels diverged at frame \(frame)")
        }
    }

    // MARK: - Double buffering

    func testPublishFlipsBanksSoReadersNeverSeeAHalfWrittenChain() {
        let bank = FilterBank()
        let first = Int(bank.activeBank.pointee)
        bank.publish([[BiquadDesign.peaking(frequency: 1_000, gainDB: 6, q: 1, sampleRate: sampleRate)]])
        let second = Int(bank.activeBank.pointee)
        XCTAssertNotEqual(first, second)

        bank.publish([[BiquadDesign.peaking(frequency: 1_000, gainDB: 3, q: 1, sampleRate: sampleRate)]])
        XCTAssertEqual(Int(bank.activeBank.pointee), first)
    }

    func testPublishClearsDevicesThatNoLongerHaveAChain() {
        let bank = FilterBank()
        bank.publish([[BiquadDesign.peaking(frequency: 1_000, gainDB: 6, q: 1, sampleRate: sampleRate)],
                      [BiquadDesign.lowPass(frequency: 500, q: 1, sampleRate: sampleRate)]])
        bank.publish([[BiquadDesign.peaking(frequency: 1_000, gainDB: 6, q: 1, sampleRate: sampleRate)]])

        let activeBank = Int(bank.activeBank.pointee)
        XCTAssertEqual(bank.sectionCounts[activeBank * FilterBank.maxDevices + 1], 0)
    }

    func testChainLongerThanTheHardwareLimitIsTruncatedNotOverflowed() {
        let bank = FilterBank()
        let tooMany = (0..<32).map { _ in
            BiquadDesign.peaking(frequency: 1_000, gainDB: 1, q: 1, sampleRate: sampleRate)
        }
        bank.publish([tooMany])
        let activeBank = Int(bank.activeBank.pointee)
        XCTAssertEqual(Int(bank.sectionCounts[activeBank * FilterBank.maxDevices]), FilterBank.maxSections)
    }

    func testResetStateClearsFilterMemory() {
        let bank = FilterBank()
        let filter = BiquadDesign.lowPass(frequency: 500, q: 0.7071, sampleRate: sampleRate)
        bank.publish([[filter]])
        let activeBank = Int(bank.activeBank.pointee)
        let coefficientBase = FilterBank.coefficientOffset(bank: activeBank, device: 0, section: 0)
        let stateBase = FilterBank.stateOffset(device: 0, section: 0, channel: 0)

        var left: Float = 1, right: Float = 1
        for _ in 0..<100 {
            left = 1
            right = 1
            FilterBank.processFrame(left: &left, right: &right,
                                    coefficients: bank.coefficients, state: bank.state,
                                    coefficientBase: coefficientBase, stateBase: stateBase,
                                    sectionCount: 1)
        }
        XCTAssertNotEqual(bank.state[stateBase], 0)

        bank.resetState()
        XCTAssertEqual(bank.state[stateBase], 0)
        XCTAssertEqual(bank.state[stateBase + 1], 0)
    }
}
