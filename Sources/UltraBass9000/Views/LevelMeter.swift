import SwiftUI

/// A vertical peak meter for a single channel, drawn on a log (dBFS) scale
/// with a decaying peak-hold line and a green -> amber -> red color ramp.
///
/// `level` is expected to be republished ~30x/sec by the caller (reading
/// `AudioEngine.peak(for:)` in the body of a thin wrapper view). That
/// cadence doubles as this view's animation clock, so the peak-hold decay
/// advances once per incoming value via `onChange` — there is no internal
/// `Timer` and no per-frame allocation inside `Canvas`.
struct LevelMeter: View {
    var level: Float
    var isMuted: Bool = false

    /// How many consecutive updates the held peak stays put before it
    /// starts decaying. At ~30 Hz, 45 frames is ~1.5s.
    private static let holdFrames = 45
    /// Peak-hold decay speed, in dBFS per incoming update.
    private static let decayPerFrameDB: Float = 1.4

    @State private var displayLevel: Float = 0
    @State private var heldPeakDB: Float = DesignSystem.Gain.floorDB
    @State private var framesSinceRise: Int = 0

    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size)
        }
        .frame(minWidth: DesignSystem.Metrics.meterWidth)
        .opacity(isMuted ? 0.35 : 1)
        .onAppear { advance(to: level) }
        .onChange(of: level) { _, newValue in advance(to: newValue) }
        .accessibilityLabel("Level meter")
        .accessibilityValue(DesignSystem.Gain.formattedDB(fromLinear: displayLevel))
    }

    private func advance(to newValue: Float) {
        displayLevel = newValue
        let newDB = DesignSystem.Gain.decibels(fromLinear: newValue)
        if newDB >= heldPeakDB {
            heldPeakDB = newDB
            framesSinceRise = 0
        } else {
            framesSinceRise += 1
            if framesSinceRise > Self.holdFrames {
                heldPeakDB = max(DesignSystem.Gain.floorDB, heldPeakDB - Self.decayPerFrameDB)
            }
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let floor = DesignSystem.Gain.floorDB
        let trackCorner = DesignSystem.Metrics.smallCornerRadius / 2

        // Track.
        let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: trackCorner)
        context.fill(track, with: .color(DesignSystem.Colors.strip.opacity(0.6)))

        // Faint tick marks for the fixed reference dB values.
        for tickDB in DesignSystem.Meter.tickMarksDB {
            let y = size.height * (1 - CGFloat((tickDB - floor) / -floor))
            let tick = Path(CGRect(x: 0, y: y, width: size.width, height: 1))
            context.fill(tick, with: .color(DesignSystem.Colors.hairline.opacity(0.5)))
        }

        // Fill, clipped to the current level, colored by a fixed gradient
        // spanning the whole track so the visible hue always matches
        // position (quiet stays green even while the bar is short).
        let levelDB = DesignSystem.Gain.decibels(fromLinear: displayLevel)
        let fillFraction = CGFloat(((levelDB - floor) / -floor).clamped(to: 0...1))
        if fillFraction > 0 {
            let filledHeight = size.height * fillFraction
            let filledRect = CGRect(x: 0, y: size.height - filledHeight, width: size.width, height: filledHeight)
            context.fill(
                Path(roundedRect: filledRect, cornerRadius: trackCorner),
                with: .linearGradient(
                    DesignSystem.Meter.gradient,
                    startPoint: CGPoint(x: 0, y: size.height),
                    endPoint: CGPoint(x: 0, y: 0)
                )
            )
        }

        // Peak-hold line.
        let peakFraction = CGFloat(((heldPeakDB - floor) / -floor).clamped(to: 0...1))
        if peakFraction > 0 {
            let peakY = size.height - size.height * peakFraction
            let peakRect = CGRect(x: 0, y: max(0, peakY - 1), width: size.width, height: 2)
            let color: Color = peakFraction > 0.88 ? DesignSystem.Colors.meterRed : DesignSystem.Colors.textPrimary
            context.fill(Path(peakRect), with: .color(color.opacity(0.9)))
        }
    }
}

#Preview("Level Meter") {
    HStack(alignment: .bottom, spacing: 16) {
        LevelMeter(level: 0.0)
        LevelMeter(level: 0.05)
        LevelMeter(level: 0.35)
        LevelMeter(level: 0.7)
        LevelMeter(level: 0.92)
        LevelMeter(level: 0.5, isMuted: true)
    }
    .frame(width: 260, height: 240)
    .padding(DesignSystem.Spacing.lg)
    .background(DesignSystem.Colors.canvas)
}
