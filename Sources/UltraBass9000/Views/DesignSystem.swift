import SwiftUI

/// Centralized visual language for UltraBass 9000: palette, spacing, type,
/// and the small set of chrome modifiers shared by every mixer view.
///
/// Everything here is a semantic color or a system material — nothing is a
/// raw hex grey — so the app tracks the system appearance automatically.
enum DesignSystem {

    // MARK: - Palette

    enum Colors {
        // Appearance-aware surfaces.
        static let canvas = Color(nsColor: .windowBackgroundColor)
        static let panel = Color(nsColor: .underPageBackgroundColor)
        static let strip = Color(nsColor: .controlBackgroundColor)
        static let hairline = Color(nsColor: .separatorColor)

        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary

        static let accent = Color.accentColor
        static let clock = Color.accentColor

        static let danger = Color.red
        static let warning = Color.orange
        static let success = meterGreen

        // Meter ramp carries a fixed safety meaning (safe / hot / clipping)
        // and intentionally does not shift with light/dark appearance.
        static let meterGreen = Color(red: 0.20, green: 0.85, blue: 0.45)
        static let meterAmber = Color(red: 0.98, green: 0.75, blue: 0.15)
        static let meterRed = Color(red: 0.95, green: 0.25, blue: 0.25)
    }

    // MARK: - Metrics

    enum Metrics {
        static let stripWidth: CGFloat = 112
        static let sidebarWidth: CGFloat = 260
        static let meterWidth: CGFloat = 14
        static let cornerRadius: CGFloat = 16
        static let smallCornerRadius: CGFloat = 8
        static let hairlineWidth: CGFloat = 1
    }

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Typography {
        static let title = Font.system(.headline, design: .rounded).weight(.semibold)
        static let stripLabel = Font.system(.caption, design: .rounded).weight(.semibold)
        static let readout = Font.system(.caption2, design: .monospaced)
        static let badge = Font.system(size: 9, weight: .bold, design: .rounded)
        static let sectionHeader = Font.system(.caption, design: .rounded).weight(.bold)
    }

    // MARK: - Gain <-> dBFS

    /// Fader/meter taper shared by every gain-facing control so the master
    /// slider, per-device faders and the level meter all agree on where a
    /// given dB value sits along their throw.
    enum Gain {
        static let floorDB: Float = -60

        static func decibels(fromLinear gain: Float) -> Float {
            guard gain > 0.0001 else { return floorDB }
            return max(floorDB, 20 * log10(gain))
        }

        static func linear(fromDecibels db: Float) -> Float {
            db <= floorDB ? 0 : pow(10, db / 20)
        }

        /// Maps a 0...1 fader throw (bottom/left = 0, top/right = 1) to
        /// linear gain using the log taper above.
        static func linear(fromFraction fraction: Float) -> Float {
            linear(fromDecibels: floorDB + fraction.clamped(to: 0...1) * -floorDB)
        }

        static func fraction(fromLinear gain: Float) -> Float {
            ((decibels(fromLinear: gain) - floorDB) / -floorDB).clamped(to: 0...1)
        }

        static func formattedDB(fromLinear gain: Float) -> String {
            let db = decibels(fromLinear: gain)
            return db <= floorDB ? "-\u{221E}" : String(format: "%.1f dB", db)
        }
    }

    // MARK: - Level meter

    enum Meter {
        /// Built once; `LevelMeter` reuses this value every frame instead of
        /// constructing a `Gradient` inside `Canvas`.
        static let gradient = Gradient(stops: [
            .init(color: Colors.meterGreen, location: 0.0),
            .init(color: Colors.meterGreen, location: 0.55),
            .init(color: Colors.meterAmber, location: 0.75),
            .init(color: Colors.meterAmber, location: 0.88),
            .init(color: Colors.meterRed, location: 1.0),
        ])
        /// Gridline marks, in dBFS, drawn faintly behind the fill.
        static let tickMarksDB: [Float] = [-6, -12, -24, -48]
    }
}

// MARK: - Comparable clamp

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Chrome (Liquid Glass / material)

extension View {
    /// Liquid Glass chrome for primary floating surfaces: the toolbar
    /// controls, the menu bar popover, reorderable sidebar chrome.
    @ViewBuilder
    func floatingPanel(cornerRadius: CGFloat = DesignSystem.Metrics.cornerRadius) -> some View {
        self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Liquid Glass pill, used for compact controls like the status
    /// indicator and the master gain readout.
    @ViewBuilder
    func floatingPill() -> some View {
        self.glassEffect(.regular, in: Capsule())
    }

    /// `.regularMaterial` fallback for secondary / inline surfaces that
    /// aren't floating chrome: mixer strip bodies, diagnostic banners,
    /// disabled Phase 2 placeholders.
    func materialPanel(cornerRadius: CGFloat = DesignSystem.Metrics.smallCornerRadius) -> some View {
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Status presentation

/// Presentation for `EngineStatus`, kept here so the toolbar and the menu
/// bar popover render the exact same status pill without duplicating logic.
extension EngineStatus {
    // `isActive` deliberately lives on the type itself in the audio layer — it is a state question,
    // not a presentation one, and the engine branches on it too.

    var indicatorColor: Color {
        switch self {
        case .idle: return DesignSystem.Colors.textSecondary
        case .starting: return DesignSystem.Colors.warning
        case .running: return DesignSystem.Colors.success
        case .failed: return DesignSystem.Colors.danger
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting\u{2026}"
        case .running: return "Running"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

// MARK: - Previews

#Preview("Design System Swatches") {
    VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
        HStack(spacing: DesignSystem.Spacing.sm) {
            designSystemSwatch("Canvas", DesignSystem.Colors.canvas)
            designSystemSwatch("Panel", DesignSystem.Colors.panel)
            designSystemSwatch("Strip", DesignSystem.Colors.strip)
        }
        HStack(spacing: DesignSystem.Spacing.sm) {
            designSystemSwatch("Green", DesignSystem.Colors.meterGreen)
            designSystemSwatch("Amber", DesignSystem.Colors.meterAmber)
            designSystemSwatch("Red", DesignSystem.Colors.meterRed)
        }
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Section Header").font(DesignSystem.Typography.sectionHeader)
            Text("Strip Label").font(DesignSystem.Typography.stripLabel)
            Text("-12.3 dB").font(DesignSystem.Typography.readout)
            Text("CLOCK").font(DesignSystem.Typography.badge)
        }
        Text("Floating Pill")
            .font(DesignSystem.Typography.stripLabel)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .floatingPill()
    }
    .padding(DesignSystem.Spacing.lg)
    .background(DesignSystem.Colors.canvas)
}

private func designSystemSwatch(_ name: String, _ color: Color) -> some View {
    VStack(spacing: DesignSystem.Spacing.xxs) {
        RoundedRectangle(cornerRadius: DesignSystem.Metrics.smallCornerRadius)
            .fill(color)
            .frame(width: 64, height: 64)
        Text(name).font(.caption2).foregroundStyle(.secondary)
    }
}
