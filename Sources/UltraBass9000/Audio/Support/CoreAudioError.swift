import CoreAudio
import Foundation

/// Wraps an `OSStatus` from a Core Audio call together with the operation that produced it.
///
/// Core Audio reports failure through four-character codes packed into an `OSStatus`, which print
/// as meaningless negative integers. Decoding them at the throw site is the difference between
/// "-10851" and "kAudioUnitErr_InvalidPropertyValue".
struct CoreAudioError: LocalizedError, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var errorDescription: String? { description }

    var description: String {
        "\(operation) failed: \(Self.describe(status))"
    }

    /// Renders an OSStatus as its four-character code when the bytes are printable, decimal otherwise.
    static func describe(_ status: OSStatus) -> String {
        let bytes = [
            UInt8((status >> 24) & 0xFF),
            UInt8((status >> 16) & 0xFF),
            UInt8((status >> 8) & 0xFF),
            UInt8(status & 0xFF),
        ]
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
        if printable, let fourCC = String(bytes: bytes, encoding: .ascii) {
            return "'\(fourCC)' (\(status))"
        }
        return "\(status)"
    }
}

/// Throws if `status` is anything other than `noErr`.
func caTry(_ operation: @autoclosure () -> String, _ status: OSStatus) throws {
    guard status == noErr else {
        throw CoreAudioError(operation: operation(), status: status)
    }
}
