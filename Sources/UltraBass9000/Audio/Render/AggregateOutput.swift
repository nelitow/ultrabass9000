import CoreAudio
import Foundation
import os

/// The private aggregate device that fans one tapped stream out to every selected output, plus the
/// IO callback that does the per-device work.
///
/// Only one of these exists while the engine runs. It owns the aggregate and the IOProc; it does
/// not own the tap, because Core Audio requires the tap to outlive the aggregate that references it.
final class AggregateOutput {

    private let logger = Logger(subsystem: "com.nelitojr.UltraBass9000", category: "AggregateOutput")
    private let control: RenderControlBlock
    private let plan: AggregatePlan

    private(set) var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false

    /// The queue handed to `AudioDeviceCreateIOProcIDWithBlock`. Note that the block does *not*
    /// actually execute here — Core Audio runs it on its own real-time HAL thread — but passing
    /// `nil` silently fails to register the block on macOS 26, so a real queue is mandatory.
    private let ioQueue = DispatchQueue(label: "com.nelitojr.UltraBass9000.io", qos: .userInteractive)

    init(plan: AggregatePlan, tapUUID: UUID, control: RenderControlBlock) throws {
        self.plan = plan
        self.control = control
        try createAggregate(tapUUID: tapUUID)
        try createIOProc()
        disableHardwareInputStreams()
    }

    deinit { teardown() }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning, let procID else { return }
        control.forceSilence.pointee = 0
        try caTry("AudioDeviceStart", AudioDeviceStart(aggregateID, procID))
        isRunning = true
        logger.info("Started aggregate \(self.aggregateID, privacy: .public)")
    }

    /// Best-effort teardown in the only order Core Audio tolerates:
    /// stop the proc, destroy the proc, destroy the aggregate, and only then may the caller destroy
    /// the tap. Getting this wrong leaks HAL resources or crashes in `coreaudiod`.
    func teardown() {
        control.forceSilence.pointee = 1

        if aggregateID.isValid, let procID {
            if isRunning {
                let status = AudioDeviceStop(aggregateID, procID)
                if status != noErr {
                    logger.error("AudioDeviceStop: \(CoreAudioError.describe(status), privacy: .public)")
                }
                isRunning = false
            }
            // Blocks until the in-flight IO cycle finishes, which is exactly the guarantee that
            // makes it safe to free anything the callback touched.
            let status = AudioDeviceDestroyIOProcID(aggregateID, procID)
            if status != noErr {
                logger.error("AudioDeviceDestroyIOProcID: \(CoreAudioError.describe(status), privacy: .public)")
            }
        }
        procID = nil

        if aggregateID.isValid {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr {
                logger.error("AudioHardwareDestroyAggregateDevice: \(CoreAudioError.describe(status), privacy: .public)")
            }
        }
        aggregateID = .unknown
    }

    // MARK: - Construction

    private func createAggregate(tapUUID: UUID) throws {
        let subDeviceEntries: [[String: Any]] = plan.subDevices.map { device in
            var entry: [String: Any] = [
                kAudioSubDeviceUIDKey: device.uid,
                kAudioSubDeviceDriftCompensationKey: device.driftCompensation,
            ]
            if device.extraOutputLatencyFrames > 0 {
                entry[kAudioSubDeviceExtraOutputLatencyKey] = device.extraOutputLatencyFrames
            }
            return entry
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "UltraBass 9000 Output",
            // A fresh UID every activation, so a stale aggregate left behind by a crash can never
            // collide with the new one.
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: plan.clockDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: plan.clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            // Unstacked, so each sub-device gets its own output buffer. Stacking is what Apple's
            // Multi-Output Device does, and it mirrors — one buffer fed to every device — which is
            // precisely the limitation this app exists to remove. See `AggregatePlan.isStacked`
            // for the measurements; the header's wording points the other way.
            kAudioAggregateDeviceIsStackedKey: plan.isStacked,
            // Must be false. The header describes this as making `AudioDeviceStart` "wait for the
            // first tap that receives audio", and with it on the IOProc does not run freely while
            // the system is silent. Calibration needs to play its own sweeps into a quiet system,
            // so the device has to be genuinely running whether or not anything is being tapped.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceEntries,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: plan.tapDriftCompensation,
                ]
            ],
        ]

        var deviceID = AudioObjectID.unknown
        try caTry("AudioHardwareCreateAggregateDevice",
                  AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID))
        guard deviceID.isValid else {
            throw CoreAudioError(operation: "AudioHardwareCreateAggregateDevice returned an invalid object",
                                 status: kAudioHardwareBadObjectError)
        }
        aggregateID = deviceID
        logger.info("""
            Created aggregate \(deviceID, privacy: .public) \
            subDevices=\(self.plan.subDevices.map(\.uid), privacy: .public) \
            clock=\(self.plan.clockDeviceUID, privacy: .public) \
            tapDrift=\(self.plan.tapDriftCompensation, privacy: .public)
            """)
    }

    private func createIOProc() throws {
        // Captured by the block: raw pointers only, never `self` and never a `weak` reference.
        // Reading a weak reference takes a global runtime lock, which is forbidden on the
        // real-time thread. Lifetime is guaranteed instead by teardown order —
        // AudioDeviceDestroyIOProcID blocks until the last callback returns.
        let control = self.control

        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) {
            _, inputData, _, outputData, _ in
            AggregateOutput.render(input: inputData, output: outputData, control: control)
        }
        try caTry("AudioDeviceCreateIOProcIDWithBlock", status)
        guard let newProcID else {
            throw CoreAudioError(operation: "AudioDeviceCreateIOProcIDWithBlock returned no proc",
                                 status: kAudioHardwareUnspecifiedError)
        }
        procID = newProcID
    }

    /// Tells the HAL this IOProc does not read the wrapped devices' hardware input streams.
    ///
    /// Without it, a duplex device such as a USB interface counts as microphone use and macOS
    /// raises a second, unnecessary permission prompt. Only the trailing input stream — the tap —
    /// is marked in use.
    private func disableHardwareInputStreams() {
        let inputStreamCount = (try? aggregateID.readArray(.input(kAudioDevicePropertyStreams),
                                                           of: AudioObjectID.self).count) ?? 0
        guard inputStreamCount > 1 else { return }

        // AudioHardwareIOProcStreamUsage is a variable-length C struct:
        //   { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[mNumberStreams]; }
        // The flexible array starts immediately after the count, at byte offset 12 on 64-bit.
        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalSize = headerSize + inputStreamCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalSize,
                                                   alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }

        // mIOProc identifies which IOProc this usage map applies to. The ID is an opaque C
        // function pointer, so reinterpreting it as a raw pointer is the only way to store it.
        let procPointer = procID.map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
        raw.storeBytes(of: procPointer, toByteOffset: 0, as: UnsafeMutableRawPointer?.self)
        raw.storeBytes(of: UInt32(inputStreamCount),
                       toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        let flags = raw.advanced(by: headerSize).bindMemory(to: UInt32.self, capacity: inputStreamCount)
        for index in 0..<inputStreamCount {
            flags[index] = index == inputStreamCount - 1 ? 1 : 0
        }

        var address = AudioObjectPropertyAddress.input(kAudioDevicePropertyIOProcStreamUsage)
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(totalSize), raw)
        if status != noErr {
            // Non-fatal: audio still flows, the user may just see an extra microphone prompt.
            logger.warning("Could not disable hardware input streams: \(CoreAudioError.describe(status), privacy: .public)")
        }
    }

    // MARK: - Diagnostics

    /// Output buffers the HAL actually delivered, available once the first render cycle has run.
    /// Zero means the callback has not fired yet.
    var observedBufferCount: Int { Int(control.observedOutputBuffers.pointee) }
}

// MARK: - Real-time render

extension AggregateOutput {

    /// RT-SAFE. Runs on Core Audio's real-time IO thread.
    ///
    /// Must not allocate, lock, log, send Objective-C messages, or touch Swift runtime machinery
    /// that can. Everything it reads is plain memory in `RenderControlBlock`.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               control: RenderControlBlock) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

        guard control.forceSilence.pointee == 0 else {
            silence(outputBuffers)
            return
        }

        control.renderCycles.pointee &+= 1
        control.observedOutputBuffers.pointee = Int32(outputBuffers.count)

        // Calibration owns the output entirely while it runs: no tap, no filters, no delay, no
        // fader. The measurement is only meaningful if what leaves the speaker is the exact signal
        // being correlated against, and if the delays being measured are not themselves applied.
        if control.calibration.isActive.pointee == 1 {
            renderCalibration(outputBuffers: outputBuffers, control: control)
            return
        }

        // The mutable cast is required by UnsafeMutableAudioBufferListPointer, but the input is
        // owned by Core Audio and only ever read here.
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard inputBuffers.count > 0 else {
            silence(outputBuffers)
            return
        }

        // The process tap is delivered as the trailing input buffer; anything before it belongs to
        // the wrapped hardware's own input streams, which we asked the HAL not to power on.
        let tap = inputBuffers[inputBuffers.count - 1]
        guard let tapData = tap.mData, tap.mNumberChannels > 0 else {
            silence(outputBuffers)
            return
        }
        let tapChannels = Int(tap.mNumberChannels)
        control.observedTapChannels.pointee = Int32(tapChannels)
        let tapFrames = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * tapChannels)
        guard tapFrames > 0 else {
            silence(outputBuffers)
            return
        }
        let tapSamples = tapData.assumingMemoryBound(to: Float.self)

        // Silence tracking feeds the "permission probably denied" diagnostic. A denied tap is
        // indistinguishable from real silence except by how long it lasts.
        var inputPeak: Float = 0
        for index in 0..<(tapFrames * tapChannels) {
            let magnitude = abs(tapSamples[index])
            if magnitude > inputPeak { inputPeak = magnitude }
        }
        if inputPeak < 1e-7 {
            control.silentInputFrames.pointee &+= UInt64(tapFrames)
        } else {
            control.silentInputFrames.pointee = 0
        }

        let masterGain = control.masterMuted.pointee == 1 ? 0 : control.masterGain.pointee
        let mappedBuffers = Int(control.bufferCount.pointee)

        // Read the coefficient bank exactly once for the whole callback. Re-reading per device
        // could straddle a publish and mix two generations of filter design together.
        let filters = control.filters
        let bank = Int(filters.activeBank.pointee) & 1
        let coefficients = filters.coefficients
        let filterState = filters.state
        let waveforms = control.waveforms
        let delays = control.delays

        // The beat replaces the tapped audio rather than mixing with it, so what is being judged is
        // one transient on every device and not a transient buried in whatever was playing.
        let beat = control.beat
        let beatIsActive = beat.isActive.pointee == 1
        let beatBase = Int(beat.position.pointee)

        for bufferIndex in 0..<outputBuffers.count {
            let buffer = outputBuffers[bufferIndex]
            guard let outputData = buffer.mData, buffer.mNumberChannels > 0 else { continue }

            let outputChannels = Int(buffer.mNumberChannels)
            if bufferIndex == 0 { control.observedOutputChannels.pointee = Int32(outputChannels) }
            let outputFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * outputChannels)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)

            // A buffer with no mapping is a device the plan did not account for. Silence is the
            // only safe output; anything else would be uninitialised memory played at full scale.
            guard bufferIndex < mappedBuffers else {
                memset(outputData, 0, Int(buffer.mDataByteSize))
                continue
            }
            let deviceIndex = Int(control.bufferToDevice[bufferIndex])
            let deviceMuted = control.mutes[deviceIndex] == 1
            let gain = deviceMuted ? 0 : masterGain * control.gains[deviceIndex]

            let sectionCount = Int(filters.sectionCounts[bank * FilterBank.maxDevices + deviceIndex])
            let coefficientBase = FilterBank.coefficientOffset(bank: bank, device: deviceIndex, section: 0)
            let stateBase = FilterBank.stateOffset(device: deviceIndex, section: 0, channel: 0)

            let frames = min(tapFrames, outputFrames)
            var devicePeak: Float = 0

            for frame in 0..<frames {
                let outBase = frame * outputChannels
                let inBase = frame * tapChannels

                // A vanishingly small offset keeps the filter state out of denormal range. Denormal
                // arithmetic can cost tens of times a normal multiply, which on a real-time thread
                // shows up as dropouts rather than as slowness.
                var left: Float
                var right: Float
                if beatIsActive {
                    let hit = BeatPlayer.sample(at: beatBase + frame, player: beat)
                    left = hit + 1e-20
                    right = hit + 1e-20
                } else {
                    left = tapSamples[inBase] + 1e-20
                    right = tapChannels > 1 ? tapSamples[inBase + 1] + 1e-20 : left
                }

                FilterBank.processFrame(left: &left,
                                        right: &right,
                                        coefficients: coefficients,
                                        state: filterState,
                                        coefficientBase: coefficientBase,
                                        stateBase: stateBase,
                                        sectionCount: sectionCount)

                // Delay sits after the filters and before the fader, so the meter and waveform show
                // what the device is actually emitting at this instant rather than what it will
                // emit once the delay has elapsed.
                DelayBank.processFrame(left: &left, right: &right,
                                       bank: delays, deviceIndex: deviceIndex)

                left *= gain
                right *= gain

                // Zero the whole frame first so surplus channels on a multichannel interface stay
                // quiet instead of repeating the stereo pair.
                for channel in 0..<outputChannels {
                    outputSamples[outBase + channel] = 0
                }
                outputSamples[outBase] = left
                if outputChannels > 1 { outputSamples[outBase + 1] = right }

                let magnitude = max(abs(left), abs(right))
                if magnitude > devicePeak { devicePeak = magnitude }
                waveforms.accumulate((left + right) * 0.5, deviceIndex: deviceIndex)
            }

            // Any frames the tap could not fill are silence, not stale audio.
            if frames < outputFrames {
                let writtenBytes = frames * outputChannels * MemoryLayout<Float>.size
                memset(outputData.advanced(by: writtenBytes), 0,
                       Int(buffer.mDataByteSize) - writtenBytes)
            }

            if deviceIndex < RenderControlBlock.maxDevices,
               devicePeak > control.peaks[deviceIndex] {
                control.peaks[deviceIndex] = devicePeak
            }
        }

        // Advanced once for the whole callback. Every output device just rendered the same span of
        // the same beat.
        if beatIsActive {
            beat.position.pointee = Int32((beatBase + tapFrames) % max(Int(beat.periodFrames.pointee), 1))
        }
    }

    /// RT-SAFE. Plays the scheduled calibration program instead of the tap.
    private static func renderCalibration(outputBuffers: UnsafeMutableAudioBufferListPointer,
                                          control: RenderControlBlock) {
        let player = control.calibration
        let startPosition = Int(player.position.pointee)
        let mappedBuffers = Int(control.bufferCount.pointee)
        var framesAdvanced = 0

        for bufferIndex in 0..<outputBuffers.count {
            let buffer = outputBuffers[bufferIndex]
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }

            let channelCount = Int(buffer.mNumberChannels)
            let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            let samples = data.assumingMemoryBound(to: Float.self)
            framesAdvanced = max(framesAdvanced, frameCount)

            guard bufferIndex < mappedBuffers else {
                memset(data, 0, Int(buffer.mDataByteSize))
                continue
            }
            let deviceIndex = Int(control.bufferToDevice[bufferIndex])

            CalibrationPlayer.render(into: samples,
                                     frameCount: frameCount,
                                     channelCount: channelCount,
                                     deviceIndex: deviceIndex,
                                     player: player,
                                     startPosition: startPosition)

            // Keep the meters alive so the user can see which device is currently sounding.
            var peak: Float = 0
            for index in 0..<(frameCount * channelCount) {
                let magnitude = abs(samples[index])
                if magnitude > peak { peak = magnitude }
            }
            if deviceIndex < RenderControlBlock.maxDevices, peak > control.peaks[deviceIndex] {
                control.peaks[deviceIndex] = peak
            }
        }

        // Advance once for the whole callback, not once per buffer — every output stream is
        // rendering the same slice of the same program timeline.
        let next = startPosition + framesAdvanced
        player.position.pointee = Int32(next)
        if next >= Int(player.programFrames.pointee) {
            player.isActive.pointee = 0
        }
    }

    private static func silence(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
}
