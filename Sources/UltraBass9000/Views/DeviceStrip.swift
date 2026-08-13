import SwiftUI

/// One mixer channel for an active output device: identity header, an
/// optional CLOCK badge, a vertical fader + meter, a numeric dB readout,
/// mute, a live waveform preview, and an EQ thumbnail + filter summary that
/// opens the full `EQEditor` / `FilterControls` in a sheet.
struct DeviceStrip: View {
    @Environment(AudioEngine.self) private var engine

    let device: AudioDevice
    /// True when this device is `activeDevices[0]` — the clock source.
    let isClock: Bool

    @State private var isProcessingSheetPresented = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            header
            faderSection
            controlsRow
            Divider()
            processingSection
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(width: DesignSystem.Metrics.stripWidth)
        .materialPanel(cornerRadius: DesignSystem.Metrics.cornerRadius)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: DesignSystem.Spacing.xxs) {
            HStack {
                Image(systemName: device.transport.symbolName)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer(minLength: 0)
                if isClock {
                    Text("CLOCK")
                        .font(DesignSystem.Typography.badge)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(DesignSystem.Colors.clock, in: Capsule())
                }
            }
            Text(device.name)
                .font(DesignSystem.Typography.stripLabel)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Fader + meter

    private var faderSection: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            StripLevelMeter(uid: device.uid)
            GainFader(gain: gainBinding)
                .opacity(engine.isMuted(device.uid) ? 0.4 : 1)
        }
        .frame(height: 200)
    }

    private var gainBinding: Binding<Float> {
        Binding(
            get: { engine.gain(for: device.uid) },
            set: { engine.setGain($0, for: device.uid) }
        )
    }

    // MARK: - Readout + mute

    private var controlsRow: some View {
        VStack(spacing: DesignSystem.Spacing.xxs) {
            Text(DesignSystem.Gain.formattedDB(fromLinear: engine.gain(for: device.uid)))
                .font(DesignSystem.Typography.readout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Button {
                engine.setMuted(!engine.isMuted(device.uid), for: device.uid)
            } label: {
                Image(systemName: engine.isMuted(device.uid) ? "speaker.slash.fill" : "speaker.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(engine.isMuted(device.uid) ? DesignSystem.Colors.danger : nil)
            .controlSize(.small)
        }
    }

    // MARK: - Processing (waveform / EQ / filters)

    private var processingSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            StripWaveform(uid: device.uid)
                .frame(height: DesignSystem.Metrics.waveformHeight)

            Button {
                isProcessingSheetPresented = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignSystem.Spacing.xxs) {
                        Image(systemName: "slider.horizontal.3")
                        Text("EQ")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(DesignSystem.Typography.readout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                    StripEQThumbnail(uid: device.uid)
                        .frame(height: DesignSystem.Metrics.eqThumbnailHeight)

                    filterSummary
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(DesignSystem.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .materialPanel(cornerRadius: DesignSystem.Metrics.smallCornerRadius)
        .sheet(isPresented: $isProcessingSheetPresented) {
            DeviceProcessingSheet(device: device)
        }
    }

    /// Read-only "which filters are on" line — editing them happens in the
    /// sheet opened by tapping the EQ thumbnail above, alongside `EQEditor`.
    private var filterSummary: some View {
        let processing = engine.processing(for: device.uid)
        let active = [
            processing.highPass.isEnabled ? "HP" : nil,
            processing.lowPass.isEnabled ? "LP" : nil,
            processing.bandPass.isEnabled ? "BP" : nil,
        ].compactMap { $0 }

        return Text(active.isEmpty ? "No filters" : active.joined(separator: " \u{00B7} "))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .lineLimit(1)
    }
}

/// Isolates the ~30 Hz `waveform(for:)` poll to a leaf view, same rationale
/// as `StripLevelMeter`: keep that redraw cadence from invalidating the rest
/// of the strip.
private struct StripWaveform: View {
    @Environment(AudioEngine.self) private var engine
    let uid: String

    var body: some View {
        WaveformView(samples: engine.waveform(for: uid))
    }
}

/// Miniature, non-interactive magnitude-response preview. Uses far fewer
/// sample points than the full `EQEditor` plot since it only needs to read
/// as a glanceable shape, not resolve individual band positions.
private struct StripEQThumbnail: View {
    @Environment(AudioEngine.self) private var engine
    let uid: String

    private static let sampleFrequencies = EQFrequencyScale.logSpaced(count: 48)

    var body: some View {
        Canvas { context, size in
            let magnitudes = engine.magnitudeResponse(for: uid, at: Self.sampleFrequencies)
            let curve = EQCurveGeometry.paths(magnitudes: magnitudes, size: size)
            context.fill(curve.fill, with: .color(DesignSystem.Colors.accent.opacity(0.3)))
            context.stroke(curve.stroke, with: .color(DesignSystem.Colors.accent), lineWidth: 1)
        }
        .background(DesignSystem.Colors.strip.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

/// Sheet content presented from a strip's EQ thumbnail: the full `EQEditor`
/// plus `FilterControls` for the same device, with sheet chrome (dismiss,
/// whole-device reset) owned here rather than by either child view.
private struct DeviceProcessingSheet: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let device: AudioDevice

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            EQEditor(device: device)
            Divider()
            FilterControls(device: device)
            Spacer(minLength: 0)
            HStack {
                Button("Reset Device") {
                    engine.resetProcessing(for: device.uid)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 640, idealHeight: 720)
    }
}

/// Isolates the ~30 Hz `peak(for:)` poll to a leaf view so re-renders stay
/// scoped to the meter, not the whole strip (sliders, badges, placeholders).
private struct StripLevelMeter: View {
    @Environment(AudioEngine.self) private var engine
    let uid: String

    var body: some View {
        LevelMeter(level: engine.peak(for: uid), isMuted: engine.isMuted(uid))
    }
}

/// A vertical, log-taper gain fader. Reports linear 0...1 gain through
/// `gain`; internally drags in dB space so the throw matches the meter's
/// scale. Double-click resets to unity (0 dB).
struct GainFader: View {
    @Binding var gain: Float

    var body: some View {
        GeometryReader { proxy in
            let fraction = CGFloat(DesignSystem.Gain.fraction(fromLinear: gain))
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(DesignSystem.Colors.strip)
                Capsule()
                    .fill(DesignSystem.Colors.accent.opacity(0.85))
                    .frame(height: max(4, proxy.size.height * fraction))
                thumb
                    .offset(y: -proxy.size.height * fraction + 6)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(height: proxy.size.height))
            // Double-click resets to unity; must outrank the zero-distance
            // drag above or the second tap is swallowed as a drag.
            .highPriorityGesture(TapGesture(count: 2).onEnded { gain = 1 })
        }
        .frame(width: DesignSystem.Metrics.meterWidth)
        .accessibilityElement()
        .accessibilityLabel("Gain")
        .accessibilityValue(DesignSystem.Gain.formattedDB(fromLinear: gain))
        .accessibilityAdjustableAction { direction in
            let step: Float = 0.02
            switch direction {
            case .increment: gain = (gain + step).clamped(to: 0...1)
            case .decrement: gain = (gain - step).clamped(to: 0...1)
            default: break
            }
        }
    }

    private var thumb: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .frame(width: DesignSystem.Metrics.meterWidth + 6, height: 6)
            .shadow(radius: 1)
    }

    private func dragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard height > 0 else { return }
                let fraction = (1 - value.location.y / height).clamped(to: 0...1)
                gain = DesignSystem.Gain.linear(fromFraction: Float(fraction))
            }
    }
}
