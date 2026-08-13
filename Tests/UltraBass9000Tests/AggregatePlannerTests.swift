import XCTest
@testable import UltraBass9000

/// The planner decides clock source, drift compensation and buffer layout — the three things that
/// produce silent, crackling or mis-routed audio when they are wrong, and the three things that are
/// almost impossible to debug once real hardware is in the loop.
final class AggregatePlannerTests: XCTestCase {

    private func facts(_ devices: [PlannerDevice]) -> [String: PlannerDevice] {
        Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
    }

    private let speakers = PlannerDevice(uid: "speakers", outputChannels: 2)
    private let dac = PlannerDevice(uid: "dac", outputChannels: 2)
    private let interface = PlannerDevice(uid: "interface", outputChannels: 8, outputStreamCount: 4)
    private let airpods = PlannerDevice(uid: "airpods", outputChannels: 2, isBluetooth: true)
    private let mic = PlannerDevice(uid: "mic", outputChannels: 0)

    // MARK: - Selection resolution

    func testEmptySelectionProducesNoPlan() {
        XCTAssertNil(AggregatePlanner.plan(requestedUIDs: [],
                                           facts: facts([speakers]),
                                           tapSourceIsVirtual: false))
    }

    func testSelectionOfOnlyUnknownDevicesProducesNoPlan() {
        XCTAssertNil(AggregatePlanner.plan(requestedUIDs: ["ghost"],
                                           facts: facts([speakers]),
                                           tapSourceIsVirtual: false))
    }

    func testInputOnlyDeviceIsDropped() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["mic", "speakers"],
                                         facts: facts([mic, speakers]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.subDevices.map(\.uid), ["speakers"])
    }

    func testDuplicateSelectionIsCollapsedPreservingOrder() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["dac", "speakers", "dac"],
                                         facts: facts([speakers, dac]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.subDevices.map(\.uid), ["dac", "speakers"])
    }

    // MARK: - Clock and drift compensation

    func testFirstSelectedDeviceBecomesClockAndIsNotDriftCompensated() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["dac", "speakers"],
                                         facts: facts([speakers, dac]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.clockDeviceUID, "dac")
        XCTAssertEqual(plan?.subDevices.first?.driftCompensation, false)
        XCTAssertEqual(plan?.subDevices.last?.driftCompensation, true)
    }

    func testWiredClockWithHardwareTapSourceEnablesTapDriftCompensation() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["speakers"],
                                         facts: facts([speakers]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.tapDriftCompensation, true)
    }

    /// Enabling tap drift compensation against a Bluetooth clock makes the HAL add or drop a sample
    /// roughly every 0.7 s, which is audible as rhythmic crackle.
    func testBluetoothClockDisablesTapDriftCompensation() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["airpods", "speakers"],
                                         facts: facts([airpods, speakers]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.tapDriftCompensation, false)
    }

    /// A Bluetooth device that is not the clock must not disable tap drift compensation.
    func testBluetoothAsSecondaryDeviceKeepsTapDriftCompensation() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["speakers", "airpods"],
                                         facts: facts([airpods, speakers]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.tapDriftCompensation, true)
    }

    /// Virtual sources deliver in bursts, which the drift detector misreads as clock drift.
    func testVirtualTapSourceDisablesTapDriftCompensation() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["speakers"],
                                         facts: facts([speakers]),
                                         tapSourceIsVirtual: true)
        XCTAssertEqual(plan?.tapDriftCompensation, false)
    }

    // MARK: - Buffer and channel layout

    func testChannelAndBufferOffsetsAccumulateInSelectionOrder() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["speakers", "interface", "dac"],
                                         facts: facts([speakers, interface, dac]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.subDevices.map(\.channelOffset), [0, 2, 10])
        XCTAssertEqual(plan?.subDevices.map(\.bufferOffset), [0, 1, 5])
        XCTAssertEqual(plan?.totalOutputChannels, 12)
        XCTAssertEqual(plan?.totalOutputStreams, 6)
    }

    /// The render callback indexes this map directly; an off-by-one sends a device's audio to its
    /// neighbour's gain and meter.
    func testBufferToSubDeviceMapCoversEveryStream() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["speakers", "interface", "dac"],
                                         facts: facts([speakers, interface, dac]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.bufferToSubDeviceIndex, [0, 1, 1, 1, 1, 2])
    }

    /// Measured on macOS 27.0: a stacked aggregate hands the IOProc one shared buffer that every
    /// device receives identically — the exact mirroring behaviour this app exists to replace.
    /// Unstacked gives one buffer per sub-device. The header's wording suggests the opposite, so
    /// this assertion is load-bearing rather than decorative.
    func testPlanIsNeverStackedSoEachDeviceGetsItsOwnBuffer() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["speakers", "dac"],
                                         facts: facts([speakers, dac]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.isStacked, false)
    }

    func testExtraOutputLatencyIsCarriedIntoThePlan() {
        let plan = AggregatePlanner.plan(requestedUIDs: ["speakers", "dac"],
                                         facts: facts([speakers, dac]),
                                         tapSourceIsVirtual: false,
                                         extraLatencyFrames: ["dac": 512, "speakers": -10])
        XCTAssertEqual(plan?.subDevice(uid: "dac")?.extraOutputLatencyFrames, 512)
        XCTAssertEqual(plan?.subDevice(uid: "speakers")?.extraOutputLatencyFrames, 0)
    }

    // MARK: - Aggregate flattening

    func testUserAggregateIsReplacedByItsHardwareMembers() {
        let userAggregate = PlannerDevice(uid: "user-agg",
                                          outputChannels: 4,
                                          isAggregate: true,
                                          aggregateMembers: ["speakers", "dac"])
        let plan = AggregatePlanner.plan(requestedUIDs: ["user-agg"],
                                         facts: facts([userAggregate, speakers, dac]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.subDevices.map(\.uid), ["speakers", "dac"])
        XCTAssertEqual(plan?.clockDeviceUID, "speakers")
    }

    func testFlatteningDoesNotDuplicateADeviceSelectedDirectlyAndViaAggregate() {
        let userAggregate = PlannerDevice(uid: "user-agg",
                                          outputChannels: 4,
                                          isAggregate: true,
                                          aggregateMembers: ["speakers", "dac"])
        let plan = AggregatePlanner.plan(requestedUIDs: ["speakers", "user-agg"],
                                         facts: facts([userAggregate, speakers, dac]),
                                         tapSourceIsVirtual: false)
        XCTAssertEqual(plan?.subDevices.map(\.uid), ["speakers", "dac"])
    }

    /// A malformed aggregate that lists itself would otherwise recurse until the stack runs out.
    func testSelfReferencingAggregateTerminates() {
        let looping = PlannerDevice(uid: "loop",
                                    outputChannels: 2,
                                    isAggregate: true,
                                    aggregateMembers: ["loop"])
        let flattened = AggregatePlanner.flatten(["loop"], facts: facts([looping]))
        XCTAssertEqual(flattened, ["loop"])
    }

    func testMutuallyReferencingAggregatesTerminate() {
        let a = PlannerDevice(uid: "a", outputChannels: 2, isAggregate: true, aggregateMembers: ["b"])
        let b = PlannerDevice(uid: "b", outputChannels: 2, isAggregate: true, aggregateMembers: ["a"])
        let flattened = AggregatePlanner.flatten(["a"], facts: facts([a, b]))
        XCTAssertFalse(flattened.isEmpty)
        XCTAssertLessThan(flattened.count, 10)
    }

    func testEmptyAggregateFallsBackToItself() {
        let empty = PlannerDevice(uid: "empty-agg", outputChannels: 2, isAggregate: true)
        let flattened = AggregatePlanner.flatten(["empty-agg"], facts: facts([empty]))
        XCTAssertEqual(flattened, ["empty-agg"])
    }
}
