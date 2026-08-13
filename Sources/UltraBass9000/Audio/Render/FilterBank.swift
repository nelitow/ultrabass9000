import Foundation

/// Per-device biquad chains, shared with the real-time render thread.
///
/// Coefficients are double-buffered. The main thread fills the bank that is *not* in use and then
/// publishes it with a single 32-bit store; the render thread reads the index once per buffer and
/// uses that bank for the whole callback. Without this, a chain could be read halfway through an
/// update — five coefficients from two different filter designs — which is not merely wrong but
/// frequently unstable, and an unstable biquad is a full-scale squeal into someone's speakers.
final class FilterBank {
    static let maxDevices = RenderControlBlock.maxDevices
    /// Five EQ bands plus high-pass, low-pass and band-pass.
    static let maxSections = 8
    static let maxChannels = 2
    static let coefficientsPerSection = 5

    private static let bankStride = maxDevices * maxSections * coefficientsPerSection
    private static let stateCount = maxDevices * maxSections * maxChannels * 2

    /// Two banks of `[device][section][b0 b1 b2 a1 a2]`.
    let coefficients: UnsafeMutablePointer<Float>
    /// Active section count per device, per bank.
    let sectionCounts: UnsafeMutablePointer<Int32>
    /// 0 or 1. The only value the render thread needs to read to get a coherent set.
    let activeBank: UnsafeMutablePointer<UInt32>
    /// `z1`/`z2` per device, section and channel. Owned by the render thread.
    let state: UnsafeMutablePointer<Float>

    init() {
        coefficients = .allocate(capacity: 2 * Self.bankStride)
        sectionCounts = .allocate(capacity: 2 * Self.maxDevices)
        activeBank = .allocate(capacity: 1)
        state = .allocate(capacity: Self.stateCount)

        coefficients.initialize(repeating: 0, count: 2 * Self.bankStride)
        sectionCounts.initialize(repeating: 0, count: 2 * Self.maxDevices)
        activeBank.initialize(to: 0)
        state.initialize(repeating: 0, count: Self.stateCount)
    }

    deinit {
        coefficients.deallocate()
        sectionCounts.deallocate()
        activeBank.deallocate()
        state.deallocate()
    }

    // MARK: - Indexing

    /// Offset of one device's section block within a bank.
    @inline(__always)
    static func coefficientOffset(bank: Int, device: Int, section: Int) -> Int {
        bank * bankStride
            + device * (maxSections * coefficientsPerSection)
            + section * coefficientsPerSection
    }

    @inline(__always)
    static func stateOffset(device: Int, section: Int, channel: Int) -> Int {
        device * (maxSections * maxChannels * 2)
            + section * (maxChannels * 2)
            + channel * 2
    }

    // MARK: - Main-thread publishing

    /// Publishes a complete set of chains, one array per device in plan order.
    ///
    /// Writes the whole inactive bank — all devices — even when a single band moved. At
    /// 16 × 8 × 5 floats this is well under a microsecond, and it removes any question of the two
    /// banks disagreeing about a device nobody touched.
    func publish(_ chains: [[BiquadCoefficients]]) {
        let target = Int(activeBank.pointee) == 0 ? 1 : 0

        for device in 0..<Self.maxDevices {
            let chain = device < chains.count ? chains[device] : []
            let count = min(chain.count, Self.maxSections)
            for section in 0..<count {
                let offset = Self.coefficientOffset(bank: target, device: device, section: section)
                let coefficient = chain[section]
                coefficients[offset] = coefficient.b0
                coefficients[offset + 1] = coefficient.b1
                coefficients[offset + 2] = coefficient.b2
                coefficients[offset + 3] = coefficient.a1
                coefficients[offset + 4] = coefficient.a2
            }
            sectionCounts[target * Self.maxDevices + device] = Int32(count)
        }

        // Single store, and the only thing the render thread synchronises on.
        activeBank.pointee = UInt32(target)
    }

    /// Clears filter memory. Called when the device set changes, so a new device does not inherit
    /// the tail of whatever used to occupy its slot.
    func resetState() {
        state.update(repeating: 0, count: Self.stateCount)
    }

    // MARK: - Real-time processing

    /// RT-SAFE. Runs one stereo frame through a device's whole chain, in place.
    ///
    /// Transposed direct form II: one multiply-add pair per state variable, and the state stays
    /// bounded even when the input is loud. Lives here rather than inline in the render callback so
    /// tests exercise the exact arithmetic the audio thread runs, not a re-typed copy of it.
    @inline(__always)
    static func processFrame(left: inout Float,
                             right: inout Float,
                             coefficients: UnsafeMutablePointer<Float>,
                             state: UnsafeMutablePointer<Float>,
                             coefficientBase: Int,
                             stateBase: Int,
                             sectionCount: Int) {
        for section in 0..<sectionCount {
            let c = coefficientBase + section * coefficientsPerSection
            let b0 = coefficients[c]
            let b1 = coefficients[c + 1]
            let b2 = coefficients[c + 2]
            let a1 = coefficients[c + 3]
            let a2 = coefficients[c + 4]

            let leftState = stateBase + section * (maxChannels * 2)
            let outLeft = b0 * left + state[leftState]
            state[leftState] = b1 * left - a1 * outLeft + state[leftState + 1]
            state[leftState + 1] = b2 * left - a2 * outLeft
            left = outLeft

            let rightState = leftState + 2
            let outRight = b0 * right + state[rightState]
            state[rightState] = b1 * right - a1 * outRight + state[rightState + 1]
            state[rightState + 1] = b2 * right - a2 * outRight
            right = outRight
        }
    }
}
