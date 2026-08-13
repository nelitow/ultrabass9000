import CoreAudio
import Foundation
import os

/// A system-wide Core Audio process tap: every process's output, captured as a stereo mixdown,
/// with the original playback path muted so we become the only thing that reaches the speakers.
///
/// Owning the tap is separate from consuming it. The tap only produces audio once it is listed in
/// an aggregate device's tap list (`AggregateOutput`), which is why this type does nothing but
/// create, describe, and destroy.
final class ProcessTap {
    /// Caller-generated. The HAL never hands this back — the same UUID has to be threaded into the
    /// aggregate description as `kAudioSubTapUIDKey`, so it is the source of truth.
    let uuid: UUID
    private(set) var objectID: AudioObjectID = .unknown

    private let logger = Logger(subsystem: "com.nelitojr.UltraBass9000", category: "ProcessTap")

    /// Creates a global tap over every process except the ones named.
    ///
    /// - Parameter excludedProcessObjectIDs: audio process objects to leave untapped. Our own
    ///   process belongs here: we play the processed result back out, and tapping that would close
    ///   a feedback loop.
    init(excludedProcessObjectIDs: [AudioObjectID]) throws {
        let uuid = UUID()
        self.uuid = uuid

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcessObjectIDs)
        description.uuid = uuid
        description.name = "UltraBass9000 System Tap"
        // Mute the tapped processes' own path. Without this every app plays twice: once through
        // the normal output and once through ours, comb-filtered against itself.
        description.muteBehavior = .mutedWhenTapped
        // Private keeps the tap invisible to other processes and is required by the
        // `kAudioAggregateDeviceTapAutoStartKey` aggregate that will wrap it.
        description.isPrivate = true

        var tapID = AudioObjectID.unknown
        try caTry("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tapID))
        guard tapID.isValid else {
            throw CoreAudioError(operation: "AudioHardwareCreateProcessTap returned an invalid object",
                                 status: kAudioHardwareBadObjectError)
        }
        objectID = tapID
        logger.info("Created global process tap \(tapID, privacy: .public) uuid=\(uuid.uuidString, privacy: .public)")
    }

    /// The tap's negotiated stream format. Read after creation; the HAL decides the sample rate.
    var streamDescription: AudioStreamBasicDescription? {
        try? objectID.read(.global(kAudioTapPropertyFormat), as: AudioStreamBasicDescription.self)
    }

    /// Best-effort teardown. Must run *after* the aggregate that references this tap is destroyed.
    func invalidate() {
        guard objectID.isValid else { return }
        let status = AudioHardwareDestroyProcessTap(objectID)
        if status != noErr {
            logger.error("AudioHardwareDestroyProcessTap failed: \(CoreAudioError.describe(status), privacy: .public)")
        }
        objectID = .unknown
    }

    deinit { invalidate() }
}

// MARK: - Process object lookup

extension ProcessTap {
    /// Translates a BSD process id into the audio process object the tap API speaks in.
    ///
    /// Returns `nil` rather than throwing when the process has no audio object yet — a process that
    /// has never played a sample simply is not in the HAL's process list, which is not an error.
    static func audioProcessObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress.global(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var objectID = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(.system,
                                                &address,
                                                UInt32(MemoryLayout<pid_t>.size),
                                                &pid,
                                                &size,
                                                &objectID)
        guard status == noErr, objectID.isValid else { return nil }
        return objectID
    }

    /// Our own audio process object, when we have one.
    static var selfProcessObjectID: AudioObjectID? {
        audioProcessObjectID(for: getpid())
    }
}
