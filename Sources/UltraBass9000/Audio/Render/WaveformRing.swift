import Foundation

/// One column of a drawn waveform: the extremes of the signal over a short window.
struct WaveformSample: Equatable {
    var min: Float
    var max: Float

    static let silent = WaveformSample(min: 0, max: 0)
}

/// Per-device envelope history, written by the render thread and read by the UI.
///
/// Storing raw samples would mean shipping 48,000 floats per second per device to a view that can
/// only draw a few hundred pixels. Instead the render thread reduces each window of frames to its
/// minimum and maximum — which is what a waveform actually shows — and writes one column.
final class WaveformRing {
    static let maxDevices = RenderControlBlock.maxDevices
    /// Columns of history. At 48 kHz and 128 frames per column this is a little over a second.
    static let columns = 480
    static let framesPerColumn = 128

    /// `[device][column]` ring buffers.
    let minimums: UnsafeMutablePointer<Float>
    let maximums: UnsafeMutablePointer<Float>
    /// Next column to write, per device. Also tells the reader where "now" is.
    let writeIndex: UnsafeMutablePointer<UInt32>

    /// Accumulators for the column currently being filled. Render thread only.
    private let pendingMinimum: UnsafeMutablePointer<Float>
    private let pendingMaximum: UnsafeMutablePointer<Float>
    private let pendingFrames: UnsafeMutablePointer<Int32>

    init() {
        let total = Self.maxDevices * Self.columns
        minimums = .allocate(capacity: total)
        maximums = .allocate(capacity: total)
        writeIndex = .allocate(capacity: Self.maxDevices)
        pendingMinimum = .allocate(capacity: Self.maxDevices)
        pendingMaximum = .allocate(capacity: Self.maxDevices)
        pendingFrames = .allocate(capacity: Self.maxDevices)

        minimums.initialize(repeating: 0, count: total)
        maximums.initialize(repeating: 0, count: total)
        writeIndex.initialize(repeating: 0, count: Self.maxDevices)
        pendingMinimum.initialize(repeating: 0, count: Self.maxDevices)
        pendingMaximum.initialize(repeating: 0, count: Self.maxDevices)
        pendingFrames.initialize(repeating: 0, count: Self.maxDevices)
    }

    deinit {
        minimums.deallocate()
        maximums.deallocate()
        writeIndex.deallocate()
        pendingMinimum.deallocate()
        pendingMaximum.deallocate()
        pendingFrames.deallocate()
    }

    // MARK: - Real-time writes

    /// RT-SAFE. Folds one sample into the device's current column, emitting a column when full.
    @inline(__always)
    func accumulate(_ sample: Float, deviceIndex: Int) {
        guard deviceIndex >= 0, deviceIndex < Self.maxDevices else { return }

        if sample < pendingMinimum[deviceIndex] { pendingMinimum[deviceIndex] = sample }
        if sample > pendingMaximum[deviceIndex] { pendingMaximum[deviceIndex] = sample }
        pendingFrames[deviceIndex] &+= 1

        guard pendingFrames[deviceIndex] >= Int32(Self.framesPerColumn) else { return }

        let column = Int(writeIndex[deviceIndex]) % Self.columns
        let slot = deviceIndex * Self.columns + column
        minimums[slot] = pendingMinimum[deviceIndex]
        maximums[slot] = pendingMaximum[deviceIndex]

        writeIndex[deviceIndex] = UInt32((column + 1) % Self.columns)
        pendingMinimum[deviceIndex] = 0
        pendingMaximum[deviceIndex] = 0
        pendingFrames[deviceIndex] = 0
    }

    // MARK: - Main-thread reads

    /// Oldest column first, newest last, so the view can draw left to right without reindexing.
    ///
    /// The render thread may overwrite a column mid-copy. That costs one column of a 480-column
    /// waveform for one frame, which is invisible, and is worth avoiding a lock on the audio thread.
    func snapshot(deviceIndex: Int) -> [WaveformSample] {
        guard deviceIndex >= 0, deviceIndex < Self.maxDevices else { return [] }
        let start = Int(writeIndex[deviceIndex]) % Self.columns
        let base = deviceIndex * Self.columns

        var result = [WaveformSample]()
        result.reserveCapacity(Self.columns)
        for offset in 0..<Self.columns {
            let index = base + (start + offset) % Self.columns
            result.append(WaveformSample(min: minimums[index], max: maximums[index]))
        }
        return result
    }

    func reset() {
        let total = Self.maxDevices * Self.columns
        minimums.update(repeating: 0, count: total)
        maximums.update(repeating: 0, count: total)
        writeIndex.update(repeating: 0, count: Self.maxDevices)
        pendingMinimum.update(repeating: 0, count: Self.maxDevices)
        pendingMaximum.update(repeating: 0, count: Self.maxDevices)
        pendingFrames.update(repeating: 0, count: Self.maxDevices)
    }
}
