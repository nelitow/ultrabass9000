import AppKit
import Foundation
import os

/// Whether the volume keys are ours.
enum MediaKeyStatus: Equatable {
    case off
    case needsAccessibility
    case active
    /// macOS disabled the tap repeatedly and it is not worth fighting.
    case failed(String)
}

/// Intercepts the volume keys so they drive this app instead of a device nobody is hearing.
///
/// With the process tap running, the original playback path is muted, so the device the system keys
/// would adjust is out of the signal path. Pressing F11 changes the volume of something inaudible.
/// This takes the keys, swallows them so macOS does not also act, and hands them to the engine.
@MainActor
final class MediaKeyMonitor {

    private let logger = Logger(subsystem: "com.nelitojr.UltraBass9000", category: "MediaKeys")

    /// NX_SYSDEFINED. Absent from `CGEventType`, so it is spelled out once here.
    static let systemDefinedEventType: UInt32 = 14

    private(set) var status: MediaKeyStatus = .off

    /// Called on the main actor for each key-down. `isRepeat` is true while the key is held.
    var onKey: ((MediaKeyEvent, NSEvent.ModifierFlags) -> Void)?
    var onStatusChange: ((MediaKeyStatus) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    /// Times macOS has disabled the tap since the last successful stretch.
    private var disableCount = 0
    private var disableWindowStart = Date.distantPast

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Whether the app is currently trusted for Accessibility, without prompting.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt asking for Accessibility. Returns the state *before* the prompt, so
    /// a caller can tell that it asked rather than that it was granted; macOS grants asynchronously
    /// and only after the user acts in System Settings.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        guard eventTap == nil else { return }

        // Installing a tap with `.defaultTap` while untrusted is documented as a bad idea, and in
        // practice produces a tap that exists and never fires.
        guard Self.isTrusted else {
            set(status: .needsAccessibility)
            return
        }

        // `CGEventType` has no case for system-defined events; it only enumerates mouse and key
        // ones. The volume keys arrive as NX_SYSDEFINED, which is 14, and has to be named by value.
        let mask = CGEventMask(1 << MediaKeyMonitor.systemDefinedEventType)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap,
                                          place: .headInsertEventTap,
                                          // Not listen-only: the whole point is to consume the key
                                          // so macOS does not also change a device's volume and
                                          // show its own HUD on top of ours.
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: mediaKeyTapCallback,
                                          userInfo: context) else {
            set(status: .failed("macOS refused to install the event tap."))
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        disableCount = 0
        observeSystemEvents()
        set(status: .active)
        logger.info("Volume key tap installed")
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        set(status: .off)
    }

    /// Re-checks Accessibility and installs the tap if it has since been granted.
    func retryIfTrusted() {
        guard status == .needsAccessibility, Self.isTrusted else { return }
        start()
    }

    // MARK: - Keeping the tap alive

    /// Event taps do not survive sleep or a user switch.
    ///
    /// They remain valid objects and simply stop delivering, with no callback and no error, so the
    /// only way to notice is to reinstall on the notifications that precede it.
    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.status == .active else { return }
                    self.logger.info("Reinstalling volume key tap after wake or session change")
                    self.stop()
                    self.start()
                }
            }
            observers.append(observer)
        }
    }

    /// macOS disables a tap whose callback is slow, and gives no error when it does.
    ///
    /// Re-enabling is usually enough. Doing it forever is not: if the tap is being disabled
    /// repeatedly, something is wrong that re-enabling will not fix, and silently flapping is worse
    /// than saying so.
    fileprivate func handleTapDisabled() {
        guard let eventTap else { return }

        let now = Date()
        if now.timeIntervalSince(disableWindowStart) > 60 {
            disableWindowStart = now
            disableCount = 0
        }
        disableCount += 1

        guard disableCount <= 2 else {
            logger.error("Volume key tap disabled repeatedly; giving up")
            stop()
            set(status: .failed("macOS kept disabling the volume key tap."))
            return
        }

        logger.warning("Volume key tap was disabled by macOS; re-enabling")
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    fileprivate func handle(event: MediaKeyEvent, modifiers: NSEvent.ModifierFlags) {
        onKey?(event, modifiers)
    }

    private func set(status newValue: MediaKeyStatus) {
        guard status != newValue else { return }
        status = newValue
        onStatusChange?(newValue)
    }
}

/// C-convention callback the tap requires.
///
/// Runs on the run loop that installed it, which is the main one here. It must return fast: a slow
/// callback is exactly what makes macOS disable the tap.
private func mediaKeyTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.handleTapDisabled() }
        return nil
    }

    guard type.rawValue == MediaKeyMonitor.systemDefinedEventType,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == Int16(MediaKeyDecoder.auxiliaryKeySubtype),
          let decoded = MediaKeyDecoder.decode(subtype: Int(nsEvent.subtype.rawValue),
                                               data1: nsEvent.data1)
    else {
        // Anything that is not a volume key passes straight through. Swallowing those would break
        // brightness, playback and every other media key on the keyboard.
        return Unmanaged.passUnretained(event)
    }

    if decoded.isDown {
        let modifiers = nsEvent.modifierFlags
        MainActor.assumeIsolated { monitor.handle(event: decoded, modifiers: modifiers) }
    }
    // Swallow both down and up. Passing the key-up through would let macOS act on the press after
    // we already have.
    return nil
}
