import AppKit
import SwiftUI

// MARK: - Shared curve geometry

/// Log-frequency <-> pixel mapping for the 20 Hz...20 kHz axis, shared by
/// the full editor plot and the compact strip thumbnail in `DeviceStrip` so
/// both draw from the same coordinate math.
enum EQFrequencyScale {
    static let minFrequency = 20.0
    static let maxFrequency = 20000.0

    /// `count` frequencies, evenly spaced in log space from 20 Hz to 20 kHz.
    /// Equal index spacing here is what makes equal *pixel* spacing along
    /// the x-axis correct without any further transform at draw time.
    static func logSpaced(count: Int) -> [Double] {
        guard count > 1 else { return [minFrequency] }
        return (0..<count).map { i in
            minFrequency * pow(maxFrequency / minFrequency, Double(i) / Double(count - 1))
        }
    }

    static func x(for frequency: Double, width: CGFloat) -> CGFloat {
        let clamped = frequency.clamped(to: minFrequency...maxFrequency)
        let t = (log10(clamped) - log10(minFrequency)) / (log10(maxFrequency) - log10(minFrequency))
        return CGFloat(t) * width
    }

    static func frequency(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return minFrequency }
        let t = Double((x / width).clamped(to: 0...1))
        return pow(10, log10(minFrequency) + t * (log10(maxFrequency) - log10(minFrequency)))
    }
}

/// dB <-> pixel mapping for the -24...+24 dB axis (y grows downward).
enum EQGainScale {
    static let minDB = -24.0
    static let maxDB = 24.0

    static func y(for db: Double, height: CGFloat) -> CGFloat {
        let t = (db.clamped(to: minDB...maxDB) - minDB) / (maxDB - minDB)
        return height - CGFloat(t) * height
    }

    static func db(forY y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        let t = Double(((height - y) / height).clamped(to: 0...1))
        return minDB + t * (maxDB - minDB)
    }
}

/// Builds the filled-to-0dB curve path and its stroke outline from a
/// magnitude response. Shared by `EQEditor`'s full plot and the compact,
/// non-interactive thumbnail on `DeviceStrip` so both render the identical
/// shape, just at different resolutions and sizes.
enum EQCurveGeometry {
    static func paths(magnitudes: [Double], size: CGSize) -> (fill: Path, stroke: Path) {
        guard magnitudes.count > 1, size.width > 0, size.height > 0 else { return (Path(), Path()) }

        let zeroY = EQGainScale.y(for: 0, height: size.height)
        var fill = Path()
        var stroke = Path()
        fill.move(to: CGPoint(x: 0, y: zeroY))
        for (index, db) in magnitudes.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(magnitudes.count - 1)
            let point = CGPoint(x: x, y: EQGainScale.y(for: db, height: size.height))
            fill.addLine(to: point)
            if index == 0 {
                stroke.move(to: point)
            } else {
                stroke.addLine(to: point)
            }
        }
        fill.addLine(to: CGPoint(x: size.width, y: zeroY))
        fill.closeSubpath()
        return (fill, stroke)
    }
}

// MARK: - Reusable numeric field

/// A labeled slider paired with an editable, formatted text field for a
/// single `Double` parameter. Shared by `EQEditor`'s band inspector and
/// `FilterControls`' frequency/Q rows.
///
/// The slider can operate in a transformed domain (e.g. log-Hz) via
/// `toSlider`/`fromSlider` while `value` itself always stays in real units,
/// which is what the text field formats and parses.
struct NumericSliderField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var sliderRange: ClosedRange<Double>?
    var toSlider: (Double) -> Double = { $0 }
    var fromSlider: (Double) -> Double = { $0 }
    let format: (Double) -> String

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { toSlider(value) },
            set: { value = fromSlider($0).clamped(to: range) }
        )
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Text(title)
                .font(DesignSystem.Typography.stripLabel)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 56, alignment: .leading)
            Slider(value: sliderBinding, in: sliderRange ?? range)
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(DesignSystem.Typography.readout)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, newValue in if !isFocused { text = format(newValue) } }
    }

    private func commit() {
        if let parsed = Double(text.trimmingCharacters(in: .whitespaces)) {
            value = parsed.clamped(to: range)
        }
        text = format(value)
    }
}

// MARK: - EQEditor

/// The frequency-response EQ editor: a log-frequency / dB plot of the
/// combined chain response with one draggable handle per enabled band, a
/// slot rail covering all 5 bands (including disabled ones, which have no
/// handle to grab), and a numeric inspector for the selected band.
struct EQEditor: View {
    @Environment(AudioEngine.self) private var engine
    let device: AudioDevice

    @State private var selectedBandID: Int?

    /// Read fresh every access — this view holds no cached copy of
    /// processing state, per the "read/mutate/write through AudioEngine"
    /// contract.
    private var processing: DeviceProcessing { engine.processing(for: device.uid) }

    private static let plotSampleFrequencies = EQFrequencyScale.logSpaced(count: 200)
    private static let gridFrequencies: [(Double, String)] = [(100, "100"), (1000, "1k"), (10000, "10k")]
    private static let gridDecibels: [Double] = [-24, -12, 0, 12, 24]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            plot
                .frame(minHeight: 240, idealHeight: 260)
            Text("Drag: freq / gain \u{00B7} \u{2325}-drag or scroll: Q \u{00B7} Double-click: reset band")
                .font(.caption2)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            bandRail
            if let selectedBandID, let band = processing.bands.first(where: { $0.id == selectedBandID }) {
                bandInspector(band: band)
                    // Forces fresh @State (text field contents, focus) when
                    // the selection changes, even if the new band happens to
                    // share a value with the old one for some field.
                    .id(band.id)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Equalizer").font(DesignSystem.Typography.title)
            Spacer()
            Toggle("EQ Enabled", isOn: eqEnabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()
            Button("Reset EQ") { resetEQ() }
                .buttonStyle(.bordered)
        }
    }

    private var eqEnabledBinding: Binding<Bool> {
        Binding(
            get: { processing.eqEnabled },
            set: { newValue in
                var p = engine.processing(for: device.uid)
                p.eqEnabled = newValue
                engine.setProcessing(p, for: device.uid)
            }
        )
    }

    /// Resets only the band values, leaving the master EQ toggle and the
    /// filters untouched. `AudioEngine.resetProcessing(for:)` resets the
    /// *whole* `DeviceProcessing` (EQ + filters); that's exposed instead as
    /// a separate "Reset Device" action in the sheet that hosts this editor
    /// (see `DeviceStrip`). `eqEnabled` is deliberately left alone too: it's
    /// a switch right next to this button, and flipping it as a side effect
    /// of "Reset EQ" would be its own kind of surprise (`DeviceProcessing
    /// .neutral.eqEnabled` isn't documented and isn't necessarily `true`).
    private func resetEQ() {
        var p = engine.processing(for: device.uid)
        p.bands = DeviceProcessing.neutral.bands
        engine.setProcessing(p, for: device.uid)
        selectedBandID = nil
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // Computed once per body evaluation (i.e. once per state
            // change), not per handle or per gesture tick.
            let magnitudes = engine.magnitudeResponse(for: device.uid, at: Self.plotSampleFrequencies)
            let curve = EQCurveGeometry.paths(magnitudes: magnitudes, size: size)

            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    drawGrid(context: context, size: canvasSize)
                    context.fill(curve.fill, with: .color(DesignSystem.Colors.accent.opacity(0.28)))
                    context.stroke(curve.stroke, with: .color(DesignSystem.Colors.accent), lineWidth: 1.5)
                }

                ForEach(processing.bands.filter(\.isEnabled)) { band in
                    BandHandle(
                        band: band,
                        isSelected: selectedBandID == band.id,
                        plotSize: size,
                        onSelect: { selectedBandID = band.id },
                        onMove: { frequency, gainDB in
                            mutateBand(band.id) {
                                $0.frequency = frequency
                                $0.gainDB = gainDB
                            }
                        },
                        onAdjustQ: { q in mutateBand(band.id) { $0.q = q } },
                        onReset: { resetBand(band.id) }
                    )
                    .position(
                        x: EQFrequencyScale.x(for: band.frequency, width: size.width),
                        y: EQGainScale.y(for: band.gainDB, height: size.height)
                    )
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

    /// Gridlines and their labels, drawn directly inside the Canvas so they
    /// share the exact same coordinate space as the handles positioned via
    /// `GeometryReader`'s `size` above — no separate axis gutter to keep in
    /// sync.
    private func drawGrid(context: GraphicsContext, size: CGSize) {
        for db in Self.gridDecibels {
            let y = EQGainScale.y(for: db, height: size.height)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(DesignSystem.Colors.hairline.opacity(db == 0 ? 0.8 : 0.35)), lineWidth: 1)

            // `.foregroundColor` (not `.foregroundStyle`) deliberately here:
            // `context.resolve(_:)` requires a concrete `Text`, and only the
            // legacy modifier is guaranteed to keep returning `Text` rather
            // than an opaque `some View`.
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

    // MARK: Band rail (all 5 slots, including disabled ones)

    /// Enabled bands get a draggable handle on the curve; disabled bands
    /// don't (there's nothing meaningful to position on a curve they don't
    /// contribute to). This rail is the only way to select and re-enable a
    /// currently-disabled slot, since the contract's `EQBand.isEnabled`
    /// needs *some* always-visible affordance to flip back on.
    private var bandRail: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(processing.bands) { band in
                bandChip(band)
            }
        }
    }

    private func bandChip(_ band: EQBand) -> some View {
        Button {
            selectedBandID = band.id
        } label: {
            VStack(spacing: 2) {
                Image(systemName: band.kind.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(Self.formattedFrequency(band.frequency))
                    .font(.system(size: 9, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .foregroundStyle(band.isEnabled ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            .opacity(band.isEnabled ? 1 : 0.5)
            .background(
                selectedBandID == band.id ? DesignSystem.Colors.accent.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: DesignSystem.Metrics.smallCornerRadius)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Band \(band.id + 1), \(band.kind.displayName)")
        .accessibilityValue(band.isEnabled ? "On, \(Self.formattedFrequency(band.frequency))" : "Off")
    }

    // MARK: Inspector

    @ViewBuilder
    private func bandInspector(band: EQBand) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Picker("Band Type", selection: bandBinding(band.id, \.kind)) {
                    ForEach(BandKind.allCases) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Toggle("Band Enabled", isOn: bandBinding(band.id, \.isEnabled))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            NumericSliderField(
                title: "Freq",
                value: bandBinding(band.id, \.frequency),
                range: EQFrequencyScale.minFrequency...EQFrequencyScale.maxFrequency,
                sliderRange: log10(EQFrequencyScale.minFrequency)...log10(EQFrequencyScale.maxFrequency),
                toSlider: { log10($0) },
                fromSlider: { pow(10, $0) },
                // Plain integer Hz here, not the abbreviated "1.2k" used by
                // the band rail chips: this text is round-tripped through
                // `Double.init?(_:)` on commit, and "1.2k" doesn't parse.
                format: { String(format: "%.0f", $0) }
            )
            NumericSliderField(
                title: "Gain",
                value: bandBinding(band.id, \.gainDB),
                range: EQGainScale.minDB...EQGainScale.maxDB,
                format: { String(format: "%.1f dB", $0) }
            )
            NumericSliderField(
                title: "Q",
                value: bandBinding(band.id, \.q),
                range: 0.1...18,
                format: { String(format: "%.2f", $0) }
            )
        }
        .padding(DesignSystem.Spacing.sm)
        .materialPanel()
    }

    // MARK: Mutation helpers

    /// The one place that reads the current processing, mutates a single
    /// band in place, and writes the whole struct back — every drag tick,
    /// slider change and text commit funnels through here so there's a
    /// single source of truth and no duplicated band state in this view.
    private func mutateBand(_ id: Int, _ body: (inout EQBand) -> Void) {
        var p = engine.processing(for: device.uid)
        guard let index = p.bands.firstIndex(where: { $0.id == id }) else { return }
        body(&p.bands[index])
        p.bands[index].frequency = p.bands[index].frequency.clamped(to: EQFrequencyScale.minFrequency...EQFrequencyScale.maxFrequency)
        p.bands[index].gainDB = p.bands[index].gainDB.clamped(to: EQGainScale.minDB...EQGainScale.maxDB)
        p.bands[index].q = p.bands[index].q.clamped(to: 0.1...18)
        engine.setProcessing(p, for: device.uid)
    }

    private func resetBand(_ id: Int) {
        guard let neutralBand = DeviceProcessing.neutral.bands.first(where: { $0.id == id }) else { return }
        mutateBand(id) { $0 = neutralBand }
    }

    private func bandBinding<T>(_ id: Int, _ keyPath: WritableKeyPath<EQBand, T>) -> Binding<T> {
        Binding(
            get: {
                if let band = processing.bands.first(where: { $0.id == id }) {
                    return band[keyPath: keyPath]
                }
                // Defensive only: the contract guarantees exactly 5 bands
                // with stable ids, so this path should be unreachable.
                return DeviceProcessing.neutral.bands.first(where: { $0.id == id })?[keyPath: keyPath]
                    ?? DeviceProcessing.neutral.bands[0][keyPath: keyPath]
            },
            set: { newValue in mutateBand(id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Compact, space-constrained label for the band rail chips — never
    /// round-tripped through a parser, so the "k" abbreviation is safe here.
    static func formattedFrequency(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.2gk", hz / 1000) : String(format: "%.0f", hz)
    }

    /// Full unit label ("500 Hz" / "1.20 kHz") for read-only readouts, e.g.
    /// `FilterControls`' compact summary next to each enable toggle.
    static func formattedFrequencyWithUnit(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.2f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }
}

// MARK: - Band handle

/// One draggable handle on the plot. Horizontal drag maps to frequency,
/// vertical to gain; Option-drag (reliable everywhere) or a scroll gesture
/// (best-effort, see `ScrollWheelCatcher`) adjusts Q instead. Double-click
/// resets the band to its neutral default.
private struct BandHandle: View {
    let band: EQBand
    let isSelected: Bool
    let plotSize: CGSize
    let onSelect: () -> Void
    let onMove: (_ frequency: Double, _ gainDB: Double) -> Void
    let onAdjustQ: (_ q: Double) -> Void
    let onReset: () -> Void

    /// Captured at the start of a drag so every subsequent `onChanged` can
    /// compute an absolute new value from `origin + translation`, instead of
    /// drifting from repeatedly re-deriving position off itself.
    @State private var origin: (frequency: Double, gainDB: Double, q: Double)?

    private var diameter: CGFloat { isSelected ? 22 : 16 }

    var body: some View {
        Circle()
            .fill(isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.accent.opacity(0.8))
            .frame(width: diameter, height: diameter)
            .overlay(
                Image(systemName: band.kind.symbolName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(radius: isSelected ? 2 : 1)
            .background(ScrollWheelCatcher { deltaY in
                // Trackpad momentum can deliver a burst of large deltas for
                // a single flick; clamp the per-event delta so one gesture
                // can't slam Q from one end of its range to the other.
                let clampedDelta = Double(deltaY).clamped(to: -3...3)
                onAdjustQ((band.q * pow(1.02, clampedDelta)).clamped(to: 0.1...18))
            })
            .gesture(dragGesture)
            .highPriorityGesture(TapGesture(count: 2).onEnded { onReset() })
            .accessibilityElement()
            .accessibilityLabel("\(band.kind.displayName) band")
            .accessibilityValue("\(EQEditor.formattedFrequency(band.frequency)) hertz, \(String(format: "%.1f", band.gainDB)) dB, Q \(String(format: "%.2f", band.q))")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = origin ?? (band.frequency, band.gainDB, band.q)
                if origin == nil { origin = start }

                if NSEvent.modifierFlags.contains(.option) {
                    // Vertical modifier-drag adjusts Q logarithmically;
                    // frequency/gain hold still while this is active.
                    let factor = pow(2.0, Double(-value.translation.height) / 100)
                    onAdjustQ((start.q * factor).clamped(to: 0.1...18))
                } else {
                    let x = EQFrequencyScale.x(for: start.frequency, width: plotSize.width) + value.translation.width
                    let y = EQGainScale.y(for: start.gainDB, height: plotSize.height) + value.translation.height
                    onMove(
                        EQFrequencyScale.frequency(forX: x, width: plotSize.width),
                        EQGainScale.db(forY: y, height: plotSize.height)
                    )
                }
            }
            .onEnded { value in
                // A drag that barely moved is a tap: select the band for
                // the inspector instead of nudging its frequency/gain.
                if abs(value.translation.width) < 2, abs(value.translation.height) < 2 {
                    onSelect()
                }
                origin = nil
            }
    }
}

/// Thin `NSView` that exists only to intercept scroll-wheel events over an
/// EQ handle, since SwiftUI has no native scroll-wheel gesture. AppKit
/// routes `scrollWheel(with:)` by cursor hit-testing, not first-responder
/// status, so this works without any focus management. Best-effort: if a
/// future ancestor scroll view intercepts the event first, Option-drag
/// (see `BandHandle.dragGesture`) is the guaranteed fallback for Q.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaY)
        }
    }
}
