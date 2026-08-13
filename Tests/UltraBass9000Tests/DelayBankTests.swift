import XCTest
@testable import UltraBass9000

/// A delay that is off by a few frames is inaudible; one that is off by a buffer is the difference
/// between "in sync" and "slap echo". These pin the arithmetic down exactly.
final class DelayBankTests: XCTestCase {

    /// Pushes an impulse followed by silence and returns what comes back out.
    private func impulseResponse(bank: DelayBank,
                                 deviceIndex: Int = 0,
                                 frames: Int) -> [Float] {
        var output = [Float]()
        output.reserveCapacity(frames)
        for frame in 0..<frames {
            var left: Float = frame == 0 ? 1 : 0
            var right: Float = frame == 0 ? -1 : 0
            DelayBank.processFrame(left: &left, right: &right, bank: bank, deviceIndex: deviceIndex)
            output.append(left)
        }
        return output
    }

    func testZeroDelayPassesTheSignalThroughUnchanged() {
        let bank = DelayBank()
        bank.setDelayImmediately(frames: 0, deviceIndex: 0)
        let response = impulseResponse(bank: bank, frames: 8)
        XCTAssertEqual(response[0], 1)
        XCTAssertEqual(response.dropFirst().max(), 0)
    }

    func testDelayShiftsTheSignalByExactlyThatManyFrames() {
        for delay in [1, 7, 64, 1_000] {
            let bank = DelayBank()
            bank.setDelayImmediately(frames: delay, deviceIndex: 0)
            let response = impulseResponse(bank: bank, frames: delay + 4)
            XCTAssertEqual(response[delay], 1, "delay \(delay)")
            XCTAssertEqual(response[0..<delay].max(), 0, "leading frames should be silent")
        }
    }

    func testChannelsAreDelayedIndependentlyButEqually() {
        let bank = DelayBank()
        bank.setDelayImmediately(frames: 16, deviceIndex: 0)
        var lefts = [Float]()
        var rights = [Float]()
        for frame in 0..<24 {
            var left: Float = frame == 0 ? 1 : 0
            var right: Float = frame == 0 ? -1 : 0
            DelayBank.processFrame(left: &left, right: &right, bank: bank, deviceIndex: 0)
            lefts.append(left)
            rights.append(right)
        }
        XCTAssertEqual(lefts[16], 1)
        XCTAssertEqual(rights[16], -1)
    }

    func testDevicesHaveIndependentDelayLines() {
        let bank = DelayBank()
        bank.setDelayImmediately(frames: 0, deviceIndex: 0)
        bank.setDelayImmediately(frames: 32, deviceIndex: 1)

        var device0 = [Float]()
        var device1 = [Float]()
        for frame in 0..<40 {
            var l0: Float = frame == 0 ? 1 : 0
            var r0: Float = 0
            DelayBank.processFrame(left: &l0, right: &r0, bank: bank, deviceIndex: 0)
            device0.append(l0)

            var l1: Float = frame == 0 ? 1 : 0
            var r1: Float = 0
            DelayBank.processFrame(left: &l1, right: &r1, bank: bank, deviceIndex: 1)
            device1.append(l1)
        }
        XCTAssertEqual(device0[0], 1)
        XCTAssertEqual(device1[32], 1)
        XCTAssertEqual(device1[0], 0)
    }

    // MARK: - Live changes

    /// Moving the read pointer mid-stream would step discontinuously through the waveform and
    /// click. The fade exists to prevent exactly that, so assert the output stays continuous.
    func testChangingDelayWhilePlayingProducesNoDiscontinuity() {
        let bank = DelayBank()
        bank.setDelayImmediately(frames: 100, deviceIndex: 0)

        var previous: Float = 0
        var largestJump: Float = 0
        for frame in 0..<4_000 {
            // A steady tone: any pointer jump shows up immediately as a step.
            var left = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000))
            var right = left
            if frame == 1_000 { bank.setDelay(frames: 900, deviceIndex: 0) }
            DelayBank.processFrame(left: &left, right: &right, bank: bank, deviceIndex: 0)
            if frame > 100 {
                largestJump = max(largestJump, abs(left - previous))
            }
            previous = left
        }
        // A 440 Hz tone at 48 kHz moves at most ~0.06 per frame; a pointer jump would be far larger.
        XCTAssertLessThan(largestJump, 0.1)
    }

    func testDelayChangeIsFullyAppliedOnceTheFadeCompletes() {
        let bank = DelayBank()
        bank.setDelayImmediately(frames: 10, deviceIndex: 0)
        bank.setDelay(frames: 200, deviceIndex: 0)

        // Run past both fade halves.
        for _ in 0..<(Int(DelayBank.fadeFrames) * 2 + 16) {
            var left: Float = 0
            var right: Float = 0
            DelayBank.processFrame(left: &left, right: &right, bank: bank, deviceIndex: 0)
        }
        XCTAssertEqual(bank.activeDelayFrames[0], 200)
        XCTAssertEqual(bank.fadeState[0], 0)
    }

    // MARK: - Bounds

    func testDelayIsClampedToTheBufferCapacity() {
        let bank = DelayBank()
        bank.setDelay(frames: DelayBank.capacityFrames * 4, deviceIndex: 0)
        XCTAssertEqual(bank.delay(deviceIndex: 0), DelayBank.capacityFrames - 1)
    }

    func testNegativeDelayIsClampedToZero() {
        let bank = DelayBank()
        bank.setDelay(frames: -500, deviceIndex: 0)
        XCTAssertEqual(bank.delay(deviceIndex: 0), 0)
    }

    func testOutOfRangeDeviceIndexIsIgnoredRatherThanCorruptingMemory() {
        let bank = DelayBank()
        bank.setDelay(frames: 100, deviceIndex: DelayBank.maxDevices + 5)
        bank.setDelay(frames: 100, deviceIndex: -1)
        var left: Float = 1, right: Float = 1
        DelayBank.processFrame(left: &left, right: &right, bank: bank, deviceIndex: -1)
        DelayBank.processFrame(left: &left, right: &right, bank: bank, deviceIndex: DelayBank.maxDevices)
        XCTAssertEqual(left, 1)
    }

    func testResetClearsBufferedAudioSoAReassignedSlotStaysSilent() {
        let bank = DelayBank()
        bank.setDelayImmediately(frames: 50, deviceIndex: 0)
        for _ in 0..<20 {
            var left: Float = 1, right: Float = 1
            DelayBank.processFrame(left: &left, right: &right, bank: bank, deviceIndex: 0)
        }
        bank.reset()

        var output = [Float]()
        for _ in 0..<60 {
            var left: Float = 0, right: Float = 0
            DelayBank.processFrame(left: &left, right: &right, bank: bank, deviceIndex: 0)
            output.append(left)
        }
        XCTAssertEqual(output.map(abs).max(), 0)
    }
}
