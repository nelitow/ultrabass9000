import Foundation

/// Per-device delay lines, shared with the real-time render thread.
///
/// Aligning devices means holding the early ones back until the latest one catches up, so every
/// device needs its own delay and the delay has to be changeable while audio is playing.
final class DelayBank {
    static let maxDevices = RenderControlBlock.maxDevices
    static let maxChannels = 2
    /// Two seconds at 48 kHz, one at 96 kHz.
    ///
    /// Sized in frames, not seconds, so the usable delay shrinks as the sample rate rises. A
    /// 48,000-frame buffer would give exactly 500 ms at 96 kHz — the slider maximum, with no
    /// headroom at all — so the capacity is doubled and callers derive the real limit from
    /// `maximumDelaySeconds(sampleRate:)` rather than assuming 500 ms is always available.
    static let capacityFrames = 96_000

    /// Longest delay this bank can hold at a given rate, leaving one frame of headroom.
    static func maximumDelaySeconds(sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(capacityFrames - 1) / sampleRate
    }

    /// Frames spent fading out before a delay change and fading back in after it — about 5 ms each
    /// way at 48 kHz.
    static let fadeFrames: Int32 = 240

    private static let perChannel = capacityFrames
    private static let perDevice = maxChannels * capacityFrames

    /// `[device][channel][frame]` ring buffers.
    let buffer: UnsafeMutablePointer<Float>
    /// Shared write cursor per device; both channels advance together.
    let writeIndex: UnsafeMutablePointer<Int32>
    /// What the UI asked for.
    let targetDelayFrames: UnsafeMutablePointer<Int32>
    /// What the render thread is currently applying.
    let activeDelayFrames: UnsafeMutablePointer<Int32>
    /// 0 idle, 1 fading out toward a change, 2 fading back in after it.
    let fadeState: UnsafeMutablePointer<Int32>
    let fadeCounter: UnsafeMutablePointer<Int32>

    init() {
        let total = Self.maxDevices * Self.perDevice
        buffer = .allocate(capacity: total)
        writeIndex = .allocate(capacity: Self.maxDevices)
        targetDelayFrames = .allocate(capacity: Self.maxDevices)
        activeDelayFrames = .allocate(capacity: Self.maxDevices)
        fadeState = .allocate(capacity: Self.maxDevices)
        fadeCounter = .allocate(capacity: Self.maxDevices)

        buffer.initialize(repeating: 0, count: total)
        writeIndex.initialize(repeating: 0, count: Self.maxDevices)
        targetDelayFrames.initialize(repeating: 0, count: Self.maxDevices)
        activeDelayFrames.initialize(repeating: 0, count: Self.maxDevices)
        fadeState.initialize(repeating: 0, count: Self.maxDevices)
        fadeCounter.initialize(repeating: 0, count: Self.maxDevices)
    }

    deinit {
        buffer.deallocate()
        writeIndex.deallocate()
        targetDelayFrames.deallocate()
        activeDelayFrames.deallocate()
        fadeState.deallocate()
        fadeCounter.deallocate()
    }

    // MARK: - Main-thread writes

    /// Requests a new delay. The render thread fades out, applies it, and fades back in.
    func setDelay(frames: Int, deviceIndex: Int) {
        guard deviceIndex >= 0, deviceIndex < Self.maxDevices else { return }
        targetDelayFrames[deviceIndex] = Int32(min(max(frames, 0), Self.capacityFrames - 1))
    }

    /// Applies a delay without the fade, for use when no audio is in flight.
    ///
    /// At activation the lines are empty and nothing is playing, so fading would only mute the
    /// first 10 ms of the session for no benefit.
    func setDelayImmediately(frames: Int, deviceIndex: Int) {
        guard deviceIndex >= 0, deviceIndex < Self.maxDevices else { return }
        let clamped = Int32(min(max(frames, 0), Self.capacityFrames - 1))
        targetDelayFrames[deviceIndex] = clamped
        activeDelayFrames[deviceIndex] = clamped
        fadeState[deviceIndex] = 0
        fadeCounter[deviceIndex] = 0
    }

    func delay(deviceIndex: Int) -> Int {
        guard deviceIndex >= 0, deviceIndex < Self.maxDevices else { return 0 }
        return Int(targetDelayFrames[deviceIndex])
    }

    /// Clears every line. Called when the device set changes, so a reassigned slot does not replay
    /// the previous device's audio out of its delay buffer.
    func reset() {
        buffer.update(repeating: 0, count: Self.maxDevices * Self.perDevice)
        writeIndex.update(repeating: 0, count: Self.maxDevices)
        activeDelayFrames.update(repeating: 0, count: Self.maxDevices)
        fadeState.update(repeating: 0, count: Self.maxDevices)
        fadeCounter.update(repeating: 0, count: Self.maxDevices)
    }

    // MARK: - Real-time processing

    /// RT-SAFE. Delays one stereo frame in place.
    ///
    /// A delay change moves the read pointer, which would step discontinuously through the signal
    /// and click. Rather than crossfading two read pointers, the line fades to silence, jumps, and
    /// fades back — delay changes are user-initiated and rare, and 10 ms of dip is far less
    /// objectionable than a click through a full-range speaker.
    @inline(__always)
    static func processFrame(left: inout Float,
                             right: inout Float,
                             bank: DelayBank,
                             deviceIndex: Int) {
        guard deviceIndex >= 0, deviceIndex < maxDevices else { return }

        let deviceBase = deviceIndex * perDevice
        let write = Int(bank.writeIndex[deviceIndex])

        bank.buffer[deviceBase + write] = left
        bank.buffer[deviceBase + perChannel + write] = right

        // Advance first, so a zero delay reads back exactly what was just written.
        let nextWrite = (write + 1) % capacityFrames
        bank.writeIndex[deviceIndex] = Int32(nextWrite)

        var gain: Float = 1
        switch bank.fadeState[deviceIndex] {
        case 1:
            bank.fadeCounter[deviceIndex] -= 1
            if bank.fadeCounter[deviceIndex] <= 0 {
                bank.activeDelayFrames[deviceIndex] = bank.targetDelayFrames[deviceIndex]
                bank.fadeState[deviceIndex] = 2
                bank.fadeCounter[deviceIndex] = fadeFrames
                gain = 0
            } else {
                gain = Float(bank.fadeCounter[deviceIndex]) / Float(fadeFrames)
            }
        case 2:
            bank.fadeCounter[deviceIndex] -= 1
            if bank.fadeCounter[deviceIndex] <= 0 {
                bank.fadeState[deviceIndex] = 0
                bank.fadeCounter[deviceIndex] = 0
                gain = 1
            } else {
                gain = 1 - Float(bank.fadeCounter[deviceIndex]) / Float(fadeFrames)
            }
        default:
            if bank.activeDelayFrames[deviceIndex] != bank.targetDelayFrames[deviceIndex] {
                bank.fadeState[deviceIndex] = 1
                bank.fadeCounter[deviceIndex] = fadeFrames
            }
        }

        let delay = Int(bank.activeDelayFrames[deviceIndex])
        let read = (write + capacityFrames - delay) % capacityFrames
        left = bank.buffer[deviceBase + read] * gain
        right = bank.buffer[deviceBase + perChannel + read] * gain
    }
}
