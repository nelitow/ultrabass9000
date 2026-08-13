import Foundation

/// Plays a repeating test beat in place of the tapped audio, shared with the render thread.
///
/// The beat deliberately runs through the whole per-device chain: filters, delay, then gain. It is
/// testing the configuration, not bypassing it. If two devices are aligned the hit sounds like one
/// event; if they are not, it sounds like a slap echo, which is far easier to hear than to see in a
/// number.
final class BeatPlayer {
    static let maxFrames = 96_000

    let samples: UnsafeMutablePointer<Float>
    let frameCount: UnsafeMutablePointer<Int32>
    /// Frames between hits.
    let periodFrames: UnsafeMutablePointer<Int32>
    /// Frames elapsed since the beat started. Advanced once per render callback.
    let position: UnsafeMutablePointer<Int32>
    let isActive: UnsafeMutablePointer<UInt32>

    /// Roughly 100 hits a minute. Slow enough to hear each one settle, quick enough to compare two
    /// settings without waiting.
    static let defaultPeriod: Double = 0.6

    init() {
        samples = .allocate(capacity: Self.maxFrames)
        frameCount = .allocate(capacity: 1)
        periodFrames = .allocate(capacity: 1)
        position = .allocate(capacity: 1)
        isActive = .allocate(capacity: 1)

        samples.initialize(repeating: 0, count: Self.maxFrames)
        frameCount.initialize(to: 0)
        periodFrames.initialize(to: 1)
        position.initialize(to: 0)
        isActive.initialize(to: 0)
    }

    deinit {
        samples.deallocate()
        frameCount.deallocate()
        periodFrames.deallocate()
        position.deallocate()
        isActive.deallocate()
    }

    // MARK: - Main thread

    func load(waveform: [Float], sampleRate: Double) {
        let count = min(waveform.count, Self.maxFrames)
        guard count > 0, sampleRate > 0 else {
            frameCount.pointee = 0
            return
        }
        for index in 0..<count { samples[index] = waveform[index] }
        frameCount.pointee = Int32(count)
        periodFrames.pointee = Int32(max(count, Int(Self.defaultPeriod * sampleRate)))
    }

    func start() {
        guard frameCount.pointee > 0 else { return }
        position.pointee = 0
        isActive.pointee = 1
    }

    func stop() {
        isActive.pointee = 0
        position.pointee = 0
    }

    // MARK: - Real-time

    /// RT-SAFE. The sample at an absolute frame position.
    ///
    /// Takes the frame rather than advancing internally, because the render callback walks every
    /// output device over the same block of time. A generator that advanced on each call would run
    /// at N times speed with N devices connected, and would drift further apart the more devices
    /// were added.
    @inline(__always)
    static func sample(at absoluteFrame: Int, player: BeatPlayer) -> Float {
        let period = Int(player.periodFrames.pointee)
        let count = Int(player.frameCount.pointee)
        guard period > 0, count > 0 else { return 0 }
        let phase = absoluteFrame % period
        return phase < count ? player.samples[phase] : 0
    }
}
