import Foundation

/// Everything the planner needs to know about one candidate output device.
///
/// A plain value type with no Core Audio dependency, so the planning rules — which are where the
/// subtle multi-device bugs live — can be tested without any hardware.
struct PlannerDevice: Equatable {
    let uid: String
    let outputChannels: Int
    /// Number of *output streams*. The IO callback receives one `AudioBuffer` per stream, so this
    /// is what determines where a device's audio lands in the output buffer list.
    let outputStreamCount: Int
    let isBluetooth: Bool
    let isAggregate: Bool
    /// Sub-device UIDs when this device is itself a user aggregate, in order.
    let aggregateMembers: [String]

    init(uid: String,
         outputChannels: Int,
         outputStreamCount: Int = 1,
         isBluetooth: Bool = false,
         isAggregate: Bool = false,
         aggregateMembers: [String] = []) {
        self.uid = uid
        self.outputChannels = outputChannels
        self.outputStreamCount = outputStreamCount
        self.isBluetooth = isBluetooth
        self.isAggregate = isAggregate
        self.aggregateMembers = aggregateMembers
    }
}

/// The resolved shape of the private aggregate device we are about to create.
struct AggregatePlan: Equatable {
    struct SubDevice: Equatable {
        let uid: String
        let outputChannels: Int
        let outputStreamCount: Int
        /// Index of this device's first channel across the whole aggregate. Informational —
        /// the render callback works in buffers, not a flat channel space.
        let channelOffset: Int
        /// Index of this device's first `AudioBuffer` in the output buffer list.
        let bufferOffset: Int
        /// Off for the clock device, on for everyone else.
        let driftCompensation: Bool
        /// Extra output latency in frames, applied by the HAL. Only settable at creation time,
        /// so live delay adjustment still needs our own delay lines (Phase 4).
        let extraOutputLatencyFrames: Int
    }

    let subDevices: [SubDevice]
    let clockDeviceUID: String
    /// Must be `false`. Measured, not assumed.
    ///
    /// `AudioHardware.h` says a value of 0 means "the output streams are all fed the same data",
    /// which reads as though 1 is the per-device layout. The opposite is true. Measured on
    /// macOS 27.0 with two stereo output devices:
    ///
    /// | `stacked` | output buffers | channels each |
    /// |-----------|----------------|---------------|
    /// | `true`    | 1              | 2             |
    /// | `false`   | 2              | 2             |
    ///
    /// `true` is what Apple's own Multi-Output Device uses — its UID is literally
    /// `~:AMS2_StackedOutput:0` — and it mirrors, handing the IOProc a single stereo buffer that
    /// every device receives identically. That makes per-device EQ, gain and delay impossible.
    /// `false` gives one `AudioBuffer` per sub-device, which is the whole basis of this app.
    let isStacked: Bool
    /// Whether the *tap* sub-device gets drift compensation. See `AggregatePlanner` for why this
    /// is not simply always-on.
    let tapDriftCompensation: Bool

    var totalOutputChannels: Int { subDevices.reduce(0) { $0 + $1.outputChannels } }
    var totalOutputStreams: Int { subDevices.reduce(0) { $0 + $1.outputStreamCount } }

    func subDevice(uid: String) -> SubDevice? { subDevices.first { $0.uid == uid } }

    /// Flat lookup from output-buffer index to sub-device index, for O(1) use on the render thread.
    ///
    /// Precomputed because the render callback must not search or allocate.
    var bufferToSubDeviceIndex: [Int] {
        var map: [Int] = []
        map.reserveCapacity(totalOutputStreams)
        for (index, device) in subDevices.enumerated() {
            map.append(contentsOf: Array(repeating: index, count: device.outputStreamCount))
        }
        return map
    }
}

/// Turns a user's ordered list of output devices into a concrete aggregate layout.
enum AggregatePlanner {

    /// - Parameters:
    ///   - requestedUIDs: user-chosen outputs, in priority order. Index 0 becomes the clock source.
    ///   - facts: device lookup by UID. Unknown UIDs are dropped rather than failing the whole plan,
    ///     because devices disappear between the user's click and this call.
    ///   - tapSourceIsVirtual: whether the device being tapped is virtual or an aggregate.
    ///   - extraLatencyFrames: per-UID HAL output latency, for Phase 4. Absent means zero.
    /// - Returns: `nil` when nothing usable survives.
    static func plan(requestedUIDs: [String],
                     facts: [String: PlannerDevice],
                     tapSourceIsVirtual: Bool,
                     stacked: Bool = false,
                     extraLatencyFrames: [String: Int] = [:]) -> AggregatePlan? {
        let flattened = flatten(requestedUIDs, facts: facts)

        var seen = Set<String>()
        let usable = flattened.filter { uid in
            guard let device = facts[uid], device.outputChannels > 0 else { return false }
            return seen.insert(uid).inserted
        }
        guard let clockUID = usable.first else { return nil }

        var channelOffset = 0
        var bufferOffset = 0
        var subDevices: [AggregatePlan.SubDevice] = []
        for (index, uid) in usable.enumerated() {
            let device = facts[uid]
            let channels = device?.outputChannels ?? 0
            let streams = max(1, device?.outputStreamCount ?? 1)
            subDevices.append(
                .init(uid: uid,
                      outputChannels: channels,
                      outputStreamCount: streams,
                      channelOffset: channelOffset,
                      bufferOffset: bufferOffset,
                      // The clock device defines the timebase, so compensating it against itself
                      // is both meaningless and a source of periodic sample insertion.
                      driftCompensation: index > 0,
                      extraOutputLatencyFrames: max(0, extraLatencyFrames[uid] ?? 0))
            )
            channelOffset += channels
            bufferOffset += streams
        }

        // Sub-tap drift compensation must be OFF when the tap source and the clock output share a
        // clock domain. Two cases:
        //   Bluetooth — tap and output both follow the BT clock. Enabling it makes the HAL insert
        //   or delete a sample on the ~50 ppm BT-vs-crystal offset roughly every 0.7 s, which is
        //   audible as rhythmic crackle.
        //   Virtual sources — burst delivery looks like drift to the detector.
        // Unresolvable clock device defaults to OFF, which is the less wrong guess for unknown BT.
        let clockIsBluetooth = facts[clockUID]?.isBluetooth ?? true
        let tapDriftCompensation = !tapSourceIsVirtual && !clockIsBluetooth

        return AggregatePlan(subDevices: subDevices,
                             clockDeviceUID: clockUID,
                             isStacked: stacked,
                             tapDriftCompensation: tapDriftCompensation)
    }

    /// Expands any requested device that is itself an aggregate into its members.
    ///
    /// Core Audio aggregates cannot nest — a nested aggregate reports zero output channels — so a
    /// user aggregate selected as an output has to be replaced by its hardware members.
    /// Depth-limited and cycle-guarded because a malformed aggregate that lists itself would
    /// otherwise recurse forever.
    static func flatten(_ uids: [String],
                        facts: [String: PlannerDevice],
                        depthLimit: Int = 4) -> [String] {
        var result: [String] = []
        var visiting = Set<String>()

        func expand(_ uid: String, depth: Int) {
            guard let device = facts[uid] else {
                // Unknown UID is kept here and dropped by the caller's `usable` filter, so that
                // `flatten` stays a pure structural transform with no validity opinion.
                result.append(uid)
                return
            }
            guard device.isAggregate, !device.aggregateMembers.isEmpty, depth < depthLimit,
                  !visiting.contains(uid) else {
                result.append(uid)
                return
            }
            visiting.insert(uid)
            defer { visiting.remove(uid) }
            for member in device.aggregateMembers {
                expand(member, depth: depth + 1)
            }
        }

        for uid in uids { expand(uid, depth: 0) }
        return result
    }
}

// MARK: - Bridging from live devices

extension PlannerDevice {
    init(_ device: AudioDevice) {
        self.init(uid: device.uid,
                  outputChannels: device.outputChannels,
                  outputStreamCount: device.outputStreamCount,
                  isBluetooth: device.isBluetooth,
                  isAggregate: device.isAggregate,
                  aggregateMembers: device.aggregateSubDeviceUIDs)
    }
}
