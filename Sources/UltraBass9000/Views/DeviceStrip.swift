import SwiftUI

/// One mixer channel for an active output device: identity header, an
/// optional CLOCK badge, a vertical fader + meter, a numeric dB readout,
/// mute, and a dimmed Phase 2 placeholder stack (EQ / Filters / Delay).
struct DeviceStrip: View {
    @Environment(AudioEngine.self) private var engine

    let device: AudioDevice
    /// True when this device is `activeDevices[0]` — the clock source.
    let isClock: Bool

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            header
            faderSection
            controlsRow
            Divider()
            phase2Placeholder
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

    // MARK: - Phase 2 placeholder

    private var phase2Placeholder: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            phase2Row(title: "EQ", systemImage: "slider.horizontal.3")
            phase2Row(title: "Filters", systemImage: "waveform.badge.minus")
            phase2Row(title: "Delay", systemImage: "timer")
        }
        .padding(DesignSystem.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .materialPanel(cornerRadius: DesignSystem.Metrics.smallCornerRadius)
        .overlay(alignment: .topTrailing) {
            Text("PHASE 2")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .background(.secondary.opacity(0.25), in: Capsule())
                .padding(4)
        }
        .opacity(0.55)
        .disabled(true)
        .accessibilityHidden(true)
    }

    private func phase2Row(title: String, systemImage: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            Image(systemName: systemImage)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(DesignSystem.Typography.readout)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
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
