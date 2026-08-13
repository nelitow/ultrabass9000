import CoreAudio
import Foundation
import Observation
import os

/// Live inventory of the system's audio devices, refreshed whenever the HAL reports a change.
///
/// Everything here is main-actor state consumed by SwiftUI. The audio engine takes *snapshots*
/// from it; it never reads this object from the render thread.
@MainActor
@Observable
final class AudioDeviceRegistry {
    private(set) var devices: [AudioDevice] = []
    private(set) var defaultOutputDeviceID: AudioDeviceID = .unknown

    var outputDevices: [AudioDevice] {
        devices.filter(\.canOutput)
    }

    /// Output devices that make sense as UltraBass targets: real hardware only.
    ///
    /// Aggregates and virtual devices are excluded because routing our aggregate's output into
    /// another aggregate either fails outright (no nesting) or creates a feedback path.
    var routableOutputDevices: [AudioDevice] {
        outputDevices.filter { !$0.isVirtual }
    }

    var defaultOutputDevice: AudioDevice? {
        devices.first { $0.id == defaultOutputDeviceID }
    }

    private let logger = Logger(subsystem: "com.nelitojr.UltraBass9000", category: "DeviceRegistry")
    /// Touched from `deinit`, which is nonisolated. Only ever mutated during init and read during
    /// deinit, so there is no concurrent access to protect against.
    nonisolated(unsafe) private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        refresh()
        installListeners()
    }

    deinit {
        // Listener blocks are registered against the system object and outlive `self` unless
        // explicitly removed, so a dropped registry would keep firing into freed memory.
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(.system, &address, .main, block)
        }
    }

    func device(uid: String) -> AudioDevice? {
        devices.first { $0.uid == uid }
    }

    func refresh() {
        do {
            let ids = try AudioObjectID.system
                .readArray(.global(kAudioHardwarePropertyDevices), of: AudioDeviceID.self)
            devices = ids.compactMap(AudioDevice.init(deviceID:))
            defaultOutputDeviceID = (try? AudioObjectID.system
                .read(.global(kAudioHardwarePropertyDefaultOutputDevice),
                      as: AudioDeviceID.self)) ?? .unknown
        } catch {
            logger.error("Device enumeration failed: \(error.localizedDescription, privacy: .public)")
            devices = []
        }
    }

    private func installListeners() {
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            let address = AudioObjectPropertyAddress.global(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            var mutableAddress = address
            let status = AudioObjectAddPropertyListenerBlock(.system, &mutableAddress, .main, block)
            if status == noErr {
                listeners.append((address, block))
            } else {
                logger.error("Failed to observe \(selector.fourCC, privacy: .public): \(status)")
            }
        }
    }
}
