import Foundation

/// The volume keys, as they actually arrive.
enum MediaKey: Equatable {
    case volumeUp
    case volumeDown
    case mute
}

/// One decoded key event.
struct MediaKeyEvent: Equatable {
    let key: MediaKey
    /// Key-down. Key-up events arrive too and must be swallowed but not acted on, or every press
    /// would move the volume twice.
    let isDown: Bool
    /// Held down. Auto-repeat is what makes holding a key ramp rather than step once.
    let isRepeat: Bool
}

/// Pulls a volume key out of a system-defined event's packed payload.
///
/// The volume keys are not ordinary key presses. They arrive as `NSSystemDefined` events with
/// subtype 8, carrying everything bit-packed into `data1`: which key, whether it went down or up,
/// and whether the press is a repeat. Nothing about that layout is discoverable from the API, so it
/// lives here, alone, where it can be tested without an event tap or Accessibility permission.
enum MediaKeyDecoder {

    /// The subtype that marks an audio/media key. Other system-defined events use different ones and
    /// must be passed through untouched.
    static let auxiliaryKeySubtype = 8

    // Values from `IOKit/hidsystem/ev_keymap.h`.
    private static let keyTypeSoundUp = 0
    private static let keyTypeSoundDown = 1
    private static let keyTypeMute = 7

    /// - Parameters:
    ///   - subtype: the event's subtype. Anything but `auxiliaryKeySubtype` decodes to `nil`.
    ///   - data1: the packed payload.
    /// - Returns: `nil` for any event that is not one of the three volume keys, which the caller
    ///   must then leave alone.
    static func decode(subtype: Int, data1: Int) -> MediaKeyEvent? {
        guard subtype == auxiliaryKeySubtype else { return nil }

        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        // 0xA in the high byte of the flags means the key went down; 0xB means it came up.
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA
        let isRepeat = (keyFlags & 0x1) == 1

        let key: MediaKey
        switch keyCode {
        case keyTypeSoundUp: key = .volumeUp
        case keyTypeSoundDown: key = .volumeDown
        case keyTypeMute: key = .mute
        default: return nil
        }
        return MediaKeyEvent(key: key, isDown: isDown, isRepeat: isRepeat)
    }
}

/// How far one press moves the volume.
///
/// Matches the system's own feel: sixteen steps from silence to full, and quarter steps while
/// Shift and Option are held. Working in fader fraction rather than linear amplitude is what makes
/// the steps sound evenly spaced, since a linear step near zero is inaudible and the same step near
/// one is enormous.
enum VolumeStep {
    static let coarse = 1.0 / 16.0
    static let fine = coarse / 4

    /// Decibel floor of the fader, matching the one the sliders use.
    static let floorDB: Double = -60

    static func fraction(fromLinear gain: Double) -> Double {
        guard gain > 0.0001 else { return 0 }
        let decibels = max(floorDB, 20 * log10(gain))
        return min(1, max(0, (decibels - floorDB) / -floorDB))
    }

    static func linear(fromFraction fraction: Double) -> Double {
        let clamped = min(1, max(0, fraction))
        guard clamped > 0 else { return 0 }
        return pow(10, (floorDB + clamped * -floorDB) / 20)
    }

    /// The gain one key press away.
    static func nudged(gain: Double, up: Bool, fine isFine: Bool) -> Double {
        let step = isFine ? fine : coarse
        let moved = fraction(fromLinear: gain) + (up ? step : -step)
        return linear(fromFraction: moved)
    }
}
