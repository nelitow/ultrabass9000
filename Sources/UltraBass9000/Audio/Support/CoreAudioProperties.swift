import CoreAudio
import Foundation

// MARK: - Address construction

extension AudioObjectPropertyAddress {
    static func global(_ selector: AudioObjectPropertySelector) -> Self {
        .init(mSelector: selector,
              mScope: kAudioObjectPropertyScopeGlobal,
              mElement: kAudioObjectPropertyElementMain)
    }

    static func output(_ selector: AudioObjectPropertySelector,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Self {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    static func input(_ selector: AudioObjectPropertySelector,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Self {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
    }
}

// MARK: - Typed property access

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func hasProperty(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func dataSize(_ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        try caTry("AudioObjectGetPropertyDataSize(\(address.mSelector.fourCC))",
                  AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size))
        return size
    }

    /// Reads a single fixed-layout value. Allocates with `T`'s alignment so `load(as:)` is legal.
    ///
    /// `as:` is deliberately **not** defaulted, because inferring `T` from context is a trap.
    /// `let rate: Float64 = (try? object.read(address)) ?? 0` looks unambiguous but lets Swift
    /// settle on `T == Float64?` — the optional-coalescing operator is happy to unwrap one level
    /// too few — so the reader asks the HAL for nine bytes of a property that has eight. Before the
    /// size check below existed this returned whatever the allocator had left in the padding, which
    /// on this codebase happened to look correct for months.
    ///
    /// Requiring the type at every call site makes that class of mistake impossible to write.
    func read<T>(_ address: AudioObjectPropertyAddress, as type: T.Type) throws -> T {
        var address = address
        let expected = MemoryLayout<T>.size
        var size = UInt32(expected)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: expected,
                                                      alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: expected)

        try caTry("AudioObjectGetPropertyData(\(address.mSelector.fourCC))",
                  AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer))
        guard Int(size) == expected else {
            throw CoreAudioError(
                operation: """
                    AudioObjectGetPropertyData(\(address.mSelector.fourCC)) wrote \(size) bytes \
                    into a \(expected)-byte \(T.self) — the requested type does not match the property
                    """,
                status: kAudioHardwareBadPropertySizeError)
        }
        return buffer.load(as: T.self)
    }

    /// Reads a variable-length array property (device lists, stream lists, …).
    ///
    /// `of:` is required for the same reason `read(_:as:)` requires `as:`.
    func readArray<T>(_ address: AudioObjectPropertyAddress, of type: T.Type) throws -> [T] {
        var address = address
        var size = try dataSize(address)
        guard size > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        try caTry("AudioObjectGetPropertyData(\(address.mSelector.fourCC))",
                  AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer))
        let count = Int(size) / MemoryLayout<T>.stride
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    /// Core Audio hands back CFStrings at +1. Taking them as `Unmanaged` and releasing explicitly
    /// is the only way to avoid either a leak or an over-release under ARC bridging.
    func readString(_ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        try caTry("AudioObjectGetPropertyData(\(address.mSelector.fourCC)) as CFString", status)
        guard let unmanaged else { return "" }
        return unmanaged.takeRetainedValue() as String
    }

    func write<T>(_ address: AudioObjectPropertyAddress, value: T) throws {
        var address = address
        var value = value
        try caTry("AudioObjectSetPropertyData(\(address.mSelector.fourCC))",
                  AudioObjectSetPropertyData(self, &address, 0, nil,
                                             UInt32(MemoryLayout<T>.size), &value))
    }

    /// Total channel count in a scope, summed across every buffer in the stream configuration.
    ///
    /// `kAudioDevicePropertyStreamConfiguration` returns a variable-length `AudioBufferList`, so it
    /// cannot go through `read(_:)` — the struct's declared size is only ever the one-buffer case.
    func channelCount(scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = try dataSize(address)
        guard size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try caTry("AudioObjectGetPropertyData(stream configuration)",
                  AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw))
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - Selector formatting

extension AudioObjectPropertySelector {
    /// Four-character-code rendering, for readable error messages.
    var fourCC: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
              let fourCC = String(bytes: bytes, encoding: .ascii) else { return "\(self)" }
        return fourCC
    }
}
