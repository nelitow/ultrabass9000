import SwiftUI

/// dB <-> pixel mapping for the measured-response plot, deliberately separate from `EQGainScale`.
///
/// `EQGainScale`'s -24...+24 range is a filter *design* range: it has to fit a shelf or peak
/// pushed to its limit. This plot shows a normalised acoustic *measurement*, and a measured curve
/// swinging past roughly -30/+15 almost always means a room mode or a clipped recording, not
/// something the device itself is doing, so the range is narrower on purpose.
enum ResponseGainScale {
    static let minDB = -30.0
    static let maxDB = 15.0

    static func y(for db: Double, height: CGFloat) -> CGFloat {
        let t = (db.clamped(to: minDB...maxDB) - minDB) / (maxDB - minDB)
        return height - CGFloat(t) * height
    }
}

/// Overlays every active device's measured frequency response on one log-frequency / dB plot.
///
/// Reuses `EQFrequencyScale` from `EQEditor` for the x-axis, so this chart and the EQ editor agree
/// pixel-for-pixel on where a given frequency sits on screen. Each device gets a fixed-slot color
/// from `DesignSystem.Colors.responseSeries` plus its own dash pattern, so identity survives even
/// for a reader who cannot separate the hues, and the legend spells the name out regardless.
///
/// Where a device has an enabled high-pass, low-pass or band-pass, a faint dashed vertical line in
/// that device's color marks the corner frequency. That is the reason this screen exists: it lets
/// a crossover the user set be checked against where the device's own output actually falls away,
/// rather than trusting a number typed into a filter control.
struct ResponseChart: View {
    @Environment(AudioEngine.self) private var engine

    private static let gridFrequencies: [(Double, String)] = [(100, "100"), (1_000, "1k"), (10_000, "10k")]
    private static let gridDecibels: [Double] = [-30, -15, 0, 15]

    /// One color, one dash style, one line width, cycled if there are ever more devices than
    /// slots. `RenderControlBlock.maxDevices` caps the mixer at 16; the eight palette slots below
    /// are validated as a set for the first eight, so cycling only kicks in well past what this
    /// app's UI is comfortable showing on one strip.
    private static let dashPatterns: [[CGFloat]] = [
        [],
        [6, 4],
        [2, 3],
        [8, 3, 2, 3],
        [10, 4],
        [1, 4],
        [12, 3, 3, 3, 3, 3],
        [4, 2, 8, 2],
    ]

    private var devices: [AudioDevice] { engine.activeDevices }

    private struct Entry: Identifiable {
        let device: AudioDevice
        let color: Color
        let dash: [CGFloat]
        let points: [ResponsePoint]
        let processing: DeviceProcessing
        var id: String { device.uid }
    }

    private var entries: [Entry] {
        devices.enumerated().map { index, device in
            Entry(
                device: device,
                color: Self.color(at: index),
                dash: Self.dashPattern(at: index),
                points: engine.measuredResponse(for: device.uid),
                processing: engine.processing(for: device.uid)
            )
        }
    }

    private var hasAnyCurve: Bool { entries.contains { $0.points.count > 1 } }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            plot
                .frame(minHeight: 220, idealHeight: 260)
            if !entries.isEmpty {
                Text("Dashed verticals mark a device's own crossover settings, in that device's colour.")
                    .font(.caption2)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                legend
            }
        }
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // Computed once per body evaluation rather than once per draw call.
            let rows = entries

            ZStack {
                Canvas { context, canvasSize in
                    drawGrid(context: context, size: canvasSize)
                    for entry in rows {
                        drawMarkers(for: entry, context: context, size: canvasSize)
                    }
                    for entry in rows where entry.points.count > 1 {
                        drawCurve(for: entry, context: context, size: canvasSize)
                    }
                }

                if devices.isEmpty {
                    placeholder("No output devices selected.")
                } else if !hasAnyCurve {
                    placeholder("None of the currently selected outputs have been measured yet. Run Auto-Sync again with them selected.")
                }
            }
            .clipped()
        }
        .background(DesignSystem.Colors.panel, in: RoundedRectangle(cornerRadius: DesignSystem.Metrics.smallCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Metrics.smallCornerRadius)
                .strokeBorder(DesignSystem.Colors.hairline, lineWidth: DesignSystem.Metrics.hairlineWidth)
        )
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: 320)
    }

    /// Gridlines and their labels, drawn directly inside the Canvas so they share the exact same
    /// coordinate space as the curves and markers below — mirrors `EQEditor.drawGrid`.
    private func drawGrid(context: GraphicsContext, size: CGSize) {
        for db in Self.gridDecibels {
            let y = ResponseGainScale.y(for: db, height: size.height)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(DesignSystem.Colors.hairline.opacity(db == 0 ? 0.8 : 0.35)), lineWidth: 1)

            let label = context.resolve(Text("\(Int(db))").font(.system(size: 9)).foregroundColor(DesignSystem.Colors.textSecondary))
            context.draw(label, at: CGPoint(x: 3, y: y + 7), anchor: .leading)
        }

        for (frequency, title) in Self.gridFrequencies {
            let x = EQFrequencyScale.x(for: frequency, width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(DesignSystem.Colors.hairline.opacity(0.35)), lineWidth: 1)

            let label = context.resolve(Text(title).font(.system(size: 9)).foregroundColor(DesignSystem.Colors.textSecondary))
            context.draw(label, at: CGPoint(x: x + 3, y: size.height - 9), anchor: .leading)
        }
    }

    // MARK: Curves

    private func drawCurve(for entry: Entry, context: GraphicsContext, size: CGSize) {
        var path = Path()
        for (index, point) in entry.points.enumerated() {
            let position = CGPoint(
                x: EQFrequencyScale.x(for: point.frequency, width: size.width),
                y: ResponseGainScale.y(for: point.decibels, height: size.height)
            )
            if index == 0 {
                path.move(to: position)
            } else {
                path.addLine(to: position)
            }
        }
        context.stroke(
            path,
            with: .color(entry.color),
            style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round, dash: entry.dash)
        )
    }

    // MARK: Crossover markers

    private enum MarkerEdge { case top, bottom }

    private func drawMarkers(for entry: Entry, context: GraphicsContext, size: CGSize) {
        let processing = entry.processing
        if processing.highPass.isEnabled {
            drawMarker(frequency: processing.highPass.frequency, color: entry.color, edge: .top, context: context, size: size)
        }
        if processing.lowPass.isEnabled {
            drawMarker(frequency: processing.lowPass.frequency, color: entry.color, edge: .bottom, context: context, size: size)
        }
        if processing.bandPass.isEnabled {
            let band = processing.bandPass.clamped
            drawMarker(frequency: band.lowFrequency, color: entry.color, edge: .top, context: context, size: size)
            drawMarker(frequency: band.highFrequency, color: entry.color, edge: .bottom, context: context, size: size)
        }
    }

    /// A light dashed vertical line at a filter's corner frequency, labelled with the exact value
    /// since it rarely lands on a gridline. High-pass and the band-pass's low edge label from the
    /// top; low-pass and the band-pass's high edge label from the bottom, so an HP/LP pair on the
    /// same device (the common case) doesn't stack its two labels on top of one another.
    private func drawMarker(frequency: Double, color: Color, edge: MarkerEdge, context: GraphicsContext, size: CGSize) {
        let x = EQFrequencyScale.x(for: frequency, width: size.width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        let label = context.resolve(
            Text(EQEditor.formattedFrequency(frequency))
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        )
        switch edge {
        case .top:
            context.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
        case .bottom:
            context.draw(label, at: CGPoint(x: x + 3, y: size.height - 2), anchor: .bottomLeading)
        }
    }

    // MARK: Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
            ForEach(entries) { entry in
                legendRow(entry)
            }
        }
    }

    private func legendRow(_ entry: Entry) -> some View {
        let wasHeard = !entry.points.isEmpty
        return HStack(spacing: DesignSystem.Spacing.xs) {
            swatch(color: entry.color, dash: entry.dash)
            Text(entry.device.name)
                .font(DesignSystem.Typography.stripLabel)
                .foregroundStyle(wasHeard ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: DesignSystem.Spacing.sm)
            if !wasHeard {
                // Same "not heard" wording `CalibrationSheet` uses for a device the microphone
                // never captured, so the two screens describe the same fact the same way.
                Text("not heard")
                    .font(DesignSystem.Typography.readout)
                    .foregroundStyle(DesignSystem.Colors.warning)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.device.name), \(wasHeard ? "measured" : "not heard")")
    }

    private func swatch(color: Color, dash: [CGFloat]) -> some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
        }
        .frame(width: 22, height: 10)
        .accessibilityHidden(true)
    }

    // MARK: Palette assignment

    private static func color(at index: Int) -> Color {
        let palette = DesignSystem.Colors.responseSeries
        return palette[index % palette.count]
    }

    private static func dashPattern(at index: Int) -> [CGFloat] {
        dashPatterns[index % dashPatterns.count]
    }
}
