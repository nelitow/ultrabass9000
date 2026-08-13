import CoreAudio
import Foundation

/// A snapshot of one Core Audio device, taken at enumeration time.
///
/// Deliberately a value type: the HAL can invalidate an `AudioDeviceID` at any moment (unplug,
/// sleep, Bluetooth drop), so holding live objects invites use-after-free. Re-enumerate instead.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let manufacturer: String
    let transport: Transport
    let outputChannels: Int
    let inputChannels: Int
    /// Output *stream* count, not channel count. The render callback receives one `AudioBuffer`
    /// per stream, so this is what decides where a device's audio lands in the buffer list.
    let outputStreamCount: Int
    let nominalSampleRate: Double

    var canOutput: Bool { outputChannels > 0 }
    var isAggregate: Bool { transport == .aggregate }

    /// Bluetooth needs special handling in two places: sub-tap drift compensation must be off when
    /// it is the clock device, and its reported latency is routinely wrong.
    var isBluetooth: Bool { transport == .bluetooth || transport == .bluetoothLE }

    /// Virtual devices deliver in bursts, which the HAL's drift detector misreads as clock drift.
    var isVirtual: Bool { transport == .virtual || transport == .aggregate }

    enum Transport: Hashable {
        case builtIn, usb, bluetooth, bluetoothLE, hdmi, displayPort
        case airPlay, aggregate, virtual, thunderbolt, pci, firewire, unknown(UInt32)

        init(rawValue: UInt32) {
            switch rawValue {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
            case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeAggregate: self = .aggregate
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypePCI: self = .pci
            case kAudioDeviceTransportTypeFireWire: self = .firewire
            default: self = .unknown(rawValue)
            }
        }

        var symbolName: String {
            switch self {
            case .builtIn: return "laptopcomputer"
            case .usb, .thunderbolt, .pci, .firewire: return "cable.connector"
            case .bluetooth, .bluetoothLE: return "wave.3.right"
            case .hdmi, .displayPort: return "display"
            case .airPlay: return "airplayaudio"
            case .aggregate, .virtual: return "square.stack.3d.up"
            case .unknown: return "speaker.wave.2"
            }
        }
    }
}

// MARK: - Reading a device from the HAL

extension AudioDevice {
    init?(deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return nil }
        do {
            let outputChannels = (try? deviceID.channelCount(scope: kAudioObjectPropertyScopeOutput)) ?? 0
            let inputChannels = (try? deviceID.channelCount(scope: kAudioObjectPropertyScopeInput)) ?? 0
            let transportRaw: UInt32 = (try? deviceID.read(.global(kAudioDevicePropertyTransportType))) ?? 0
            let sampleRate: Float64 = (try? deviceID.read(.global(kAudioDevicePropertyNominalSampleRate))) ?? 0
            let outputStreams = (try? deviceID.readArray(.output(kAudioDevicePropertyStreams),
                                                         of: AudioObjectID.self).count) ?? 0

            self.init(
                id: deviceID,
                uid: try deviceID.readString(.global(kAudioDevicePropertyDeviceUID)),
                name: (try? deviceID.readString(.global(kAudioObjectPropertyName))) ?? "Unknown Device",
                manufacturer: (try? deviceID.readString(.global(kAudioObjectPropertyManufacturer))) ?? "",
                transport: Transport(rawValue: transportRaw),
                outputChannels: outputChannels,
                inputChannels: inputChannels,
                outputStreamCount: max(outputChannels > 0 ? 1 : 0, outputStreams),
                nominalSampleRate: sampleRate
            )
        } catch {
            return nil
        }
    }

    /// Sub-device UIDs of a user-created aggregate, in order. Empty for non-aggregates.
    ///
    /// Needed because aggregates cannot nest: if the user picks their own aggregate as an output,
    /// its members have to be flattened into ours.
    var aggregateSubDeviceUIDs: [String] {
        guard isAggregate else { return [] }
        let address = AudioObjectPropertyAddress.global(kAudioAggregateDevicePropertyFullSubDeviceList)
        guard id.hasProperty(address) else { return [] }
        var mutableAddress = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &mutableAddress, 0, nil, &size) == noErr else { return [] }
        var unmanaged: Unmanaged<CFArray>?
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(id, &mutableAddress, 0, nil, &size, pointer)
        }
        guard status == noErr, let array = unmanaged?.takeRetainedValue() as? [String] else { return [] }
        return array
    }
}
