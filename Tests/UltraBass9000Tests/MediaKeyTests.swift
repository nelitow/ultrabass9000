import XCTest
@testable import UltraBass9000

/// The volume keys arrive bit-packed into a system-defined event, a layout no API describes. It is
/// worth pinning down here, where it can be checked without Accessibility permission or an event
/// tap: swallowing the wrong key would break brightness and playback for the whole machine.
final class MediaKeyDecoderTests: XCTestCase {

    /// Builds the `data1` payload macOS sends: key code in the high 16 bits, flags in the low ones,
    /// with 0xA in the flag's high byte for a press and 0xB for a release.
    private func data1(keyCode: Int, isDown: Bool, isRepeat: Bool = false) -> Int {
        let state = isDown ? 0xA : 0xB
        return (keyCode << 16) | (state << 8) | (isRepeat ? 1 : 0)
    }

    private let subtype = MediaKeyDecoder.auxiliaryKeySubtype

    // MARK: - The three keys

    func testDecodesEachVolumeKey() {
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: subtype, data1: data1(keyCode: 0, isDown: true))?.key,
                       .volumeUp)
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: subtype, data1: data1(keyCode: 1, isDown: true))?.key,
                       .volumeDown)
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: subtype, data1: data1(keyCode: 7, isDown: true))?.key,
                       .mute)
    }

    func testDistinguishesPressFromRelease() {
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: subtype, data1: data1(keyCode: 0, isDown: true))?.isDown,
                       true)
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: subtype, data1: data1(keyCode: 0, isDown: false))?.isDown,
                       false)
    }

    func testDetectsAutoRepeat() {
        let held = MediaKeyDecoder.decode(subtype: subtype,
                                          data1: data1(keyCode: 1, isDown: true, isRepeat: true))
        XCTAssertEqual(held?.isRepeat, true)
        let single = MediaKeyDecoder.decode(subtype: subtype, data1: data1(keyCode: 1, isDown: true))
        XCTAssertEqual(single?.isRepeat, false)
    }

    // MARK: - Everything else must pass through

    /// Brightness, play/pause, next and previous all arrive on the same subtype. Claiming them
    /// would break the rest of the keyboard for the whole machine, not only for this app.
    func testOtherMediaKeysAreNotClaimed() {
        for keyCode in [2, 3, 4, 6, 16, 17, 18, 19, 20] {
            XCTAssertNil(MediaKeyDecoder.decode(subtype: subtype, data1: data1(keyCode: keyCode, isDown: true)),
                         "claimed key code \(keyCode)")
        }
    }

    func testOtherSubtypesAreNotClaimed() {
        for other in [0, 1, 6, 7, 9, 11] where other != subtype {
            XCTAssertNil(MediaKeyDecoder.decode(subtype: other, data1: data1(keyCode: 0, isDown: true)),
                         "claimed subtype \(other)")
        }
    }
}

/// Steps have to feel like the system's, or the keys will seem broken even while working.
final class VolumeStepTests: XCTestCase {

    func testSixteenPressesGoFromSilenceToFull() {
        var gain = 0.0
        for _ in 0..<16 {
            gain = VolumeStep.nudged(gain: gain, up: true, fine: false)
        }
        XCTAssertEqual(gain, 1, accuracy: 0.001)
    }

    func testSixteenPressesDownReachSilence() {
        var gain = 1.0
        for _ in 0..<16 {
            gain = VolumeStep.nudged(gain: gain, up: false, fine: false)
        }
        XCTAssertEqual(gain, 0, accuracy: 0.001)
    }

    func testVolumeNeverLeavesItsRange() {
        var gain = 1.0
        for _ in 0..<40 { gain = VolumeStep.nudged(gain: gain, up: true, fine: false) }
        XCTAssertEqual(gain, 1, accuracy: 0.001)

        gain = 0
        for _ in 0..<40 { gain = VolumeStep.nudged(gain: gain, up: false, fine: false) }
        XCTAssertEqual(gain, 0, accuracy: 0.001)
    }

    func testFineStepsAreAQuarterOfCoarseOnes() {
        let start = 0.5
        let coarse = VolumeStep.fraction(fromLinear: VolumeStep.nudged(gain: start, up: true, fine: false))
            - VolumeStep.fraction(fromLinear: start)
        let fine = VolumeStep.fraction(fromLinear: VolumeStep.nudged(gain: start, up: true, fine: true))
            - VolumeStep.fraction(fromLinear: start)
        XCTAssertEqual(coarse / fine, 4, accuracy: 0.01)
    }

    /// Stepping in fader fraction rather than in linear amplitude is what makes the steps sound
    /// evenly spaced. In linear terms the same step is inaudible near zero and enormous near one.
    func testStepsAreEvenInDecibelsRatherThanAmplitude() {
        let low = VolumeStep.nudged(gain: VolumeStep.linear(fromFraction: 0.2), up: true, fine: false)
        let high = VolumeStep.nudged(gain: VolumeStep.linear(fromFraction: 0.8), up: true, fine: false)

        let lowStepDB = 20 * log10(low / VolumeStep.linear(fromFraction: 0.2))
        let highStepDB = 20 * log10(high / VolumeStep.linear(fromFraction: 0.8))
        XCTAssertEqual(lowStepDB, highStepDB, accuracy: 0.01)
    }

    func testFractionAndLinearAreInverses() {
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            let round = VolumeStep.fraction(fromLinear: VolumeStep.linear(fromFraction: fraction))
            XCTAssertEqual(round, fraction, accuracy: 0.001)
        }
    }
}
