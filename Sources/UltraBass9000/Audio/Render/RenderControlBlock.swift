import Foundation

/// Lock-free parameter block shared between the main thread and Core Audio's real-time IO thread.
///
/// The render callback may not allocate, lock, log, or send Objective-C messages, which rules out
/// arrays, dictionaries, and every Swift synchronisation primitive. What remains is plain memory:
/// naturally-aligned 32-bit loads and stores, which are atomic on both arm64 and x86-64. The UI
/// writes parameters, the render thread writes meters, and neither ever waits for the other.
///
/// A torn read is possible in principle — the UI could change gain between two buffers — but the
/// worst case is one buffer rendered with a slightly stale gain, which is inaudible under the
/// smoothing the render thread applies anyway.
final class RenderControlBlock {
    /// Ceilings, so every allocation happens once at construction.
    static let maxDevices = 16
    static let maxBuffers = 64

    let masterGain: UnsafeMutablePointer<Float>
    let masterMuted: UnsafeMutablePointer<UInt32>
    /// Set during teardown so a still-running callback emits silence rather than stale audio.
    let forceSilence: UnsafeMutablePointer<UInt32>

    let gains: UnsafeMutablePointer<Float>
    let mutes: UnsafeMutablePointer<UInt32>
    /// Written by the render thread, read by the UI. Decays toward zero so the meter falls.
    let peaks: UnsafeMutablePointer<Float>

    /// Output buffer index → sub-device index. Precomputed so the callback never searches.
    let bufferToDevice: UnsafeMutablePointer<Int32>
    let bufferCount: UnsafeMutablePointer<Int32>
    let deviceCount: UnsafeMutablePointer<Int32>

    /// Consecutive frames of digital silence seen on the tap input.
    ///
    /// There is no API to ask whether audio-capture permission was granted; a denied tap simply
    /// delivers zeros forever. Counting silence is the only available signal, so the UI can offer
    /// an explanation instead of leaving the user with a dead app.
    let silentInputFrames: UnsafeMutablePointer<UInt64>
    /// Monotonic count of callbacks executed — proof the IOProc is alive at all.
    let renderCycles: UnsafeMutablePointer<UInt64>
    /// How many output buffers the HAL actually delivered, recorded by the render thread.
    ///
    /// Compared against the plan on the main thread: a mismatch means the aggregate did not lay
    /// out the way `stacked` was expected to, which would silently misroute per-device processing.
    let observedOutputBuffers: UnsafeMutablePointer<Int32>
    /// Channels in the tapped input buffer, as delivered. Stereo unless Apple changes the mixdown.
    let observedTapChannels: UnsafeMutablePointer<Int32>
    /// Channels in the first output buffer. Together with `observedOutputBuffers` this distinguishes
    /// a mirrored aggregate (one buffer, one device's worth of channels) from a concatenated one
    /// (one buffer holding every device's channels end to end).
    let observedOutputChannels: UnsafeMutablePointer<Int32>

    /// Per-device biquad chains, double-buffered so a coefficient update is never seen half-applied.
    let filters = FilterBank()
    /// Per-device envelope history for the waveform displays.
    let waveforms = WaveformRing()
    /// Per-device delay lines used to align devices with different latencies.
    let delays = DelayBank()
    /// Scheduled test tones for acoustic alignment. Takes over the output while it runs.
    let calibration = CalibrationPlayer()

    init() {
        masterGain = .allocate(capacity: 1)
        masterMuted = .allocate(capacity: 1)
        forceSilence = .allocate(capacity: 1)
        gains = .allocate(capacity: Self.maxDevices)
        mutes = .allocate(capacity: Self.maxDevices)
        peaks = .allocate(capacity: Self.maxDevices)
        bufferToDevice = .allocate(capacity: Self.maxBuffers)
        bufferCount = .allocate(capacity: 1)
        deviceCount = .allocate(capacity: 1)
        silentInputFrames = .allocate(capacity: 1)
        renderCycles = .allocate(capacity: 1)
        observedOutputBuffers = .allocate(capacity: 1)
        observedTapChannels = .allocate(capacity: 1)
        observedOutputChannels = .allocate(capacity: 1)

        masterGain.initialize(to: 1)
        masterMuted.initialize(to: 0)
        forceSilence.initialize(to: 0)
        gains.initialize(repeating: 1, count: Self.maxDevices)
        mutes.initialize(repeating: 0, count: Self.maxDevices)
        peaks.initialize(repeating: 0, count: Self.maxDevices)
        bufferToDevice.initialize(repeating: 0, count: Self.maxBuffers)
        bufferCount.initialize(to: 0)
        deviceCount.initialize(to: 0)
        silentInputFrames.initialize(to: 0)
        renderCycles.initialize(to: 0)
        observedOutputBuffers.initialize(to: 0)
        observedTapChannels.initialize(to: 0)
        observedOutputChannels.initialize(to: 0)
    }

    deinit {
        masterGain.deallocate()
        masterMuted.deallocate()
        forceSilence.deallocate()
        gains.deallocate()
        mutes.deallocate()
        peaks.deallocate()
        bufferToDevice.deallocate()
        bufferCount.deallocate()
        deviceCount.deallocate()
        silentInputFrames.deallocate()
        renderCycles.deallocate()
        observedOutputBuffers.deallocate()
        observedTapChannels.deallocate()
        observedOutputChannels.deallocate()
    }

    // MARK: - Main-thread writes

    func apply(plan: AggregatePlan) {
        let map = plan.bufferToSubDeviceIndex
        let count = min(map.count, Self.maxBuffers)
        for index in 0..<count {
            bufferToDevice[index] = Int32(min(map[index], Self.maxDevices - 1))
        }
        bufferCount.pointee = Int32(count)
        deviceCount.pointee = Int32(min(plan.subDevices.count, Self.maxDevices))
        silentInputFrames.pointee = 0

        // Device slots are reassigned when the plan changes. Without clearing, a new device would
        // start by playing out the filter memory and waveform history of whatever used to sit here.
        filters.resetState()
        waveforms.reset()
        delays.reset()
    }

    func setGain(_ gain: Float, deviceIndex: Int) {
        guard deviceIndex >= 0, deviceIndex < Self.maxDevices else { return }
        gains[deviceIndex] = max(0, min(1, gain))
    }

    func setMuted(_ muted: Bool, deviceIndex: Int) {
        guard deviceIndex >= 0, deviceIndex < Self.maxDevices else { return }
        mutes[deviceIndex] = muted ? 1 : 0
    }

    func peak(deviceIndex: Int) -> Float {
        guard deviceIndex >= 0, deviceIndex < Self.maxDevices else { return 0 }
        return peaks[deviceIndex]
    }

    /// Decays every meter toward zero. Called from the UI refresh timer so the render thread does
    /// not need a time base of its own.
    func decayPeaks(by factor: Float) {
        for index in 0..<Self.maxDevices {
            peaks[index] *= factor
        }
    }

    func resetMeters() {
        peaks.update(repeating: 0, count: Self.maxDevices)
    }
}
