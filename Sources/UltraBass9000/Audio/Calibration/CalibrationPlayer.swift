import Foundation

/// The scheduled test-tone program played during acoustic alignment, shared with the render thread.
///
/// One continuous program rather than a play/stop per device. Every sweep sits at a known frame
/// offset within the same timeline, and the microphone records the whole thing in one unbroken
/// pass, so every measurement carries the *same* unknown constant — recorder start offset, ADC
/// buffering, microphone latency — which then cancels when the arrivals are differenced. Starting
/// and stopping per device would make that constant different every time and destroy the result.
final class CalibrationPlayer {
    /// Sweeps are short; this is a generous ceiling on how many devices can be measured at once.
    static let maxSegments = 32
    /// Longest sweep the player will hold, in frames.
    static let maxSignalFrames = 96_000

    /// The sweep itself, mono, generated at the playback sample rate.
    let signal: UnsafeMutablePointer<Float>
    let signalFrames: UnsafeMutablePointer<Int32>

    /// Program frame at which each segment's sweep begins.
    let segmentStart: UnsafeMutablePointer<Int32>
    /// Which output device that segment addresses.
    let segmentDevice: UnsafeMutablePointer<Int32>
    let segmentCount: UnsafeMutablePointer<Int32>

    /// Total program length, including the tail after the last sweep.
    let programFrames: UnsafeMutablePointer<Int32>
    /// Render-thread playhead.
    let position: UnsafeMutablePointer<Int32>
    /// 1 while the program is playing. The render thread clears it when the program ends.
    let isActive: UnsafeMutablePointer<UInt32>

    /// Playback level for the sweep. Loud enough to be heard across a room over normal background
    /// noise, quiet enough not to startle anyone or drive a speaker into distortion.
    static let amplitude: Float = 0.35

    init() {
        signal = .allocate(capacity: Self.maxSignalFrames)
        signalFrames = .allocate(capacity: 1)
        segmentStart = .allocate(capacity: Self.maxSegments)
        segmentDevice = .allocate(capacity: Self.maxSegments)
        segmentCount = .allocate(capacity: 1)
        programFrames = .allocate(capacity: 1)
        position = .allocate(capacity: 1)
        isActive = .allocate(capacity: 1)

        signal.initialize(repeating: 0, count: Self.maxSignalFrames)
        signalFrames.initialize(to: 0)
        segmentStart.initialize(repeating: 0, count: Self.maxSegments)
        segmentDevice.initialize(repeating: -1, count: Self.maxSegments)
        segmentCount.initialize(to: 0)
        programFrames.initialize(to: 0)
        position.initialize(to: 0)
        isActive.initialize(to: 0)
    }

    deinit {
        signal.deallocate()
        signalFrames.deallocate()
        segmentStart.deallocate()
        segmentDevice.deallocate()
        segmentCount.deallocate()
        programFrames.deallocate()
        position.deallocate()
        isActive.deallocate()
    }

    // MARK: - Main-thread scheduling

    /// A scheduled sweep: which device plays it, and where it sits in the program.
    struct Segment: Equatable {
        let deviceIndex: Int
        let startFrame: Int
    }

    /// Loads a program. Returns the segments actually scheduled, in play order.
    ///
    /// - Parameters:
    ///   - sweep: the test signal, generated at the playback sample rate.
    ///   - deviceIndices: devices to measure, in the order they will be played.
    ///   - gapFrames: silence between the start of one sweep and the start of the next. Must exceed
    ///     the sweep length plus the longest latency being measured, or a slow device's arrival
    ///     would land inside the next device's window and be attributed to the wrong one.
    ///   - leadInFrames: silence before the first sweep, so the recorder is certainly running and
    ///     settled before anything is played.
    @discardableResult
    func schedule(sweep: [Float],
                  deviceIndices: [Int],
                  gapFrames: Int,
                  leadInFrames: Int) -> [Segment] {
        let sweepCount = min(sweep.count, Self.maxSignalFrames)
        guard sweepCount > 0, !deviceIndices.isEmpty else { return [] }

        for index in 0..<sweepCount { signal[index] = sweep[index] }
        signalFrames.pointee = Int32(sweepCount)

        let count = min(deviceIndices.count, Self.maxSegments)
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        for index in 0..<count {
            let start = leadInFrames + index * gapFrames
            segmentStart[index] = Int32(start)
            segmentDevice[index] = Int32(deviceIndices[index])
            segments.append(Segment(deviceIndex: deviceIndices[index], startFrame: start))
        }
        segmentCount.pointee = Int32(count)

        // Tail long enough for the last sweep to finish and travel to the microphone.
        let lastStart = leadInFrames + (count - 1) * gapFrames
        programFrames.pointee = Int32(lastStart + sweepCount + gapFrames)
        position.pointee = 0
        return segments
    }

    func begin() {
        position.pointee = 0
        isActive.pointee = 1
    }

    func cancel() {
        isActive.pointee = 0
        position.pointee = 0
    }

    var isFinished: Bool { isActive.pointee == 0 }

    /// How far through the program the render thread has got, 0...1.
    var progress: Double {
        let total = Double(programFrames.pointee)
        guard total > 0 else { return 0 }
        return min(1, Double(position.pointee) / total)
    }

    // MARK: - Real-time playback

    /// RT-SAFE. Writes this device's share of the program into one output buffer.
    ///
    /// Segments never overlap, so the search is one pass over at most 32 entries per buffer rather
    /// than per frame.
    @inline(__always)
    static func render(into samples: UnsafeMutablePointer<Float>,
                       frameCount: Int,
                       channelCount: Int,
                       deviceIndex: Int,
                       player: CalibrationPlayer,
                       startPosition: Int) {
        for frame in 0..<(frameCount * channelCount) { samples[frame] = 0 }

        let sweepFrames = Int(player.signalFrames.pointee)
        guard sweepFrames > 0 else { return }
        let segments = Int(player.segmentCount.pointee)

        for segment in 0..<segments {
            guard Int(player.segmentDevice[segment]) == deviceIndex else { continue }
            let start = Int(player.segmentStart[segment])
            let end = start + sweepFrames
            // Does this segment overlap the block we are about to fill?
            guard end > startPosition, start < startPosition + frameCount else { continue }

            for frame in 0..<frameCount {
                let programFrame = startPosition + frame
                guard programFrame >= start, programFrame < end else { continue }
                let value = player.signal[programFrame - start] * amplitude
                let base = frame * channelCount
                samples[base] = value
                if channelCount > 1 { samples[base + 1] = value }
            }
        }
    }
}
