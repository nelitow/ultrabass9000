import CoreAudio
import Foundation

/// How many processes currently hold an open output stream.
///
/// Measured, not assumed: `kAudioProcessPropertyIsRunningOutput` reports whether a process has an
/// active output *stream*, not whether it is producing sound. On an idle machine two processes
/// already report true, so this cannot be used to decide "something is playing, therefore our tap
/// should be hearing it" — that test would fire on every quiet moment.
///
/// Kept because it is still useful context in a diagnostic log, and to document the finding so the
/// next person does not reach for the same dead end.
enum SystemAudioActivity {

    static func processesRunningOutput() -> Int {
        guard let processes = try? AudioObjectID.system
            .readArray(.global(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
        else { return 0 }

        let ownProcess = ProcessTap.selfProcessObjectID
        return processes.filter { process in
            guard process != ownProcess else { return false }
            let isRunningOutput = (try? process
                .read(.global(kAudioProcessPropertyIsRunningOutput), as: UInt32.self)) ?? 0
            return isRunningOutput != 0
        }.count
    }
}
