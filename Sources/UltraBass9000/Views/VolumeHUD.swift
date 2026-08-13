import AppKit
import SwiftUI

/// The overlay shown when a volume key is pressed.
///
/// Swallowing the key also swallows Apple's own HUD, so pressing F11 with nothing on screen feels
/// like the key is broken even when the volume is moving. This replaces it.
struct VolumeHUD: View {
    let fraction: Double
    let isMuted: Bool

    private var segments: Int { 16 }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: symbolName)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(isMuted ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textPrimary)
                .frame(height: 44)

            // Segmented rather than continuous, matching the system HUD and making a single key
            // press visibly move exactly one step.
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { index in
                    let filled = !isMuted && Double(index) < (fraction * Double(segments)).rounded()
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(filled ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.hairline)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 200, height: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var symbolName: String {
        if isMuted { return "speaker.slash.fill" }
        if fraction <= 0.001 { return "speaker.fill" }
        if fraction < 0.4 { return "speaker.wave.1.fill" }
        if fraction < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Owns the floating panel the HUD lives in.
///
/// A panel rather than anything inside the app's own window, because the volume keys work whether
/// or not this app is frontmost, and a HUD that only appears when you are already looking at the
/// app would be pointless.
@MainActor
final class VolumeHUDController {

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(fraction: Double, isMuted: Bool) {
        let hud = VolumeHUD(fraction: fraction, isMuted: isMuted)
        let panel = existingPanel()
        panel.contentView = NSHostingView(rootView: hud)
        position(panel)
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: showing the HUD must never
        // steal focus from whatever the user is actually working in.
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 130),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.panel = panel
        return panel
    }

    /// Bottom centre of whichever screen has the mouse, which is where the system puts its own.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + frame.height * 0.12))
    }
}
