import CoreAudio
import Foundation
import os

/// Records the built-in microphone into one linear buffer for the duration of a calibration.
///
/// Deliberately not a ring buffer: the whole point is a single unbroken take whose sample zero is a
/// fixed reference for every arrival time in it.
final class MicrophoneRecorder {

    private let logger = Logger(subsystem: "com.nelitojr.UltraBass9000", category: "MicrophoneRecorder")

    let deviceID: AudioDeviceID
    let sampleRate: Double
    private let capacityFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    /// Frames captured so far. Written by the input IOProc, read by the main thread.
    private let writtenFrames: UnsafeMutablePointer<Int32>

    private var procID: AudioDeviceIOProcID?
    private var isRunning = false
    private let ioQueue = DispatchQueue(label: "com.nelitojr.UltraBass9000.mic", qos: .userInitiated)

    /// - Throws: if the device has no input channels or Core Audio refuses the IOProc.
    init(deviceID: AudioDeviceID, capacitySeconds: Double) throws {
        self.deviceID = deviceID

        let channels = (try? deviceID.channelCount(scope: kAudioObjectPropertyScopeInput)) ?? 0
        guard channels > 0 else {
            throw CoreAudioError(operation: "Input device has no input channels",
                                 status: kAudioHardwareBadDeviceError)
        }

        let rate: Float64 = (try? deviceID.read(.global(kAudioDevicePropertyNominalSampleRate))) ?? 48_000
        sampleRate = rate > 0 ? rate : 48_000
        capacityFrames = max(1, Int(capacitySeconds * sampleRate))

        storage = .allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0, count: capacityFrames)
        writtenFrames = .allocate(capacity: 1)
        writtenFrames.initialize(to: 0)

        let storage = self.storage
        let writtenFrames = self.writtenFrames
        let capacity = capacityFrames

        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, deviceID, ioQueue) {
            _, inputData, _, _, _ in
            // RT-SAFE. Raw pointers only; no allocation, no logging, no weak references.
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard buffers.count > 0 else { return }
            let buffer = buffers[0]
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { return }

            let channelCount = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            let samples = data.assumingMemoryBound(to: Float.self)

            var written = Int(writtenFrames.pointee)
            guard written < capacity else { return }
            let available = min(frames, capacity - written)
            for frame in 0..<available {
                // Channel 0 only. A mono take is all the correlation needs, and mixing channels
                // would comb-filter the direct arrival against itself on a stereo mic array.
                storage[written + frame] = samples[frame * channelCount]
            }
            written += available
            writtenFrames.pointee = Int32(written)
        }
        try caTry("AudioDeviceCreateIOProcIDWithBlock (microphone)", status)
        procID = newProcID
    }

    deinit {
        stop()
        if let procID, deviceID.isValid {
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        storage.deallocate()
        writtenFrames.deallocate()
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning, let procID else { return }
        writtenFrames.pointee = 0
        try caTry("AudioDeviceStart (microphone)", AudioDeviceStart(deviceID, procID))
        isRunning = true
        logger.info("Recording from device \(self.deviceID, privacy: .public) at \(self.sampleRate, privacy: .public) Hz")
    }

    func stop() {
        guard isRunning, let procID else { return }
        let status = AudioDeviceStop(deviceID, procID)
        if status != noErr {
            logger.error("AudioDeviceStop (microphone): \(CoreAudioError.describe(status), privacy: .public)")
        }
        isRunning = false
    }

    // MARK: - Reading

    var capturedFrames: Int { Int(writtenFrames.pointee) }

    var isFull: Bool { capturedFrames >= capacityFrames }

    /// Everything captured so far, from the first sample of the take.
    func recording() -> [Float] {
        let count = min(capturedFrames, capacityFrames)
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: storage, count: count))
    }

    /// Peak level seen so far, for telling "microphone denied" apart from "room is quiet".
    var peakLevel: Float {
        let count = min(capturedFrames, capacityFrames)
        var peak: Float = 0
        for index in 0..<count {
            let magnitude = abs(storage[index])
            if magnitude > peak { peak = magnitude }
        }
        return peak
    }
}

// MARK: - Default input device

extension MicrophoneRecorder {
    static var defaultInputDeviceID: AudioDeviceID? {
        // The explicit `as:` is load-bearing — without it `try?` makes the inferred type
        // `AudioDeviceID?`, which is a different size from what the HAL writes.
        guard let id = try? AudioObjectID.system
            .read(.global(kAudioHardwarePropertyDefaultInputDevice), as: AudioDeviceID.self),
              id.isValid else { return nil }
        return id
    }
}
