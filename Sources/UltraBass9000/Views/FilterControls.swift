import SwiftUI

/// High-pass, low-pass and band-pass controls for one device.
///
/// The contract doesn't document a frequency range for `FilterSetting`
/// beyond "Hz", so all three share the same 20 Hz...20 kHz audible range
/// used by `EQEditor`'s frequency axis; `q` is clamped to the documented
/// 0.1...8.
struct FilterControls: View {
    @Environment(AudioEngine.self) private var engine
    let device: AudioDevice

    private var processing: DeviceProcessing { engine.processing(for: device.uid) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Filters").font(DesignSystem.Typography.title)

            // A connecting rail behind the three rows makes the series
            // relationship literal instead of just implied by stacking:
            // signal passes through all three in order, then into the EQ.
            HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                seriesRail
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    filterSection(title: "High-Pass", symbol: "arrow.up.forward", filter: filterBinding(\.highPass))
                    filterSection(title: "Low-Pass", symbol: "arrow.down.forward", filter: filterBinding(\.lowPass))
                    filterSection(title: "Band-Pass", symbol: "arrow.left.and.right", filter: filterBinding(\.bandPass))
                }
            }

            Text("In series, ahead of the EQ bands")
                .font(.caption2)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var seriesRail: some View {
        VStack(spacing: 0) {
            ForEach(0..<3) { index in
                Circle().frame(width: 4, height: 4)
                if index < 2 {
                    Rectangle().frame(width: DesignSystem.Metrics.hairlineWidth).frame(maxHeight: .infinity)
                }
            }
        }
        .foregroundStyle(DesignSystem.Colors.hairline)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func filterBinding(_ keyPath: WritableKeyPath<DeviceProcessing, FilterSetting>) -> Binding<FilterSetting> {
        Binding(
            get: { processing[keyPath: keyPath] },
            set: { newValue in
                var p = engine.processing(for: device.uid)
                p[keyPath: keyPath] = newValue
                engine.setProcessing(p, for: device.uid)
            }
        )
    }

    @ViewBuilder
    private func filterSection(title: String, symbol: String, filter: Binding<FilterSetting>) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: symbol)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text(title).font(DesignSystem.Typography.stripLabel)
                Spacer(minLength: 0)
                Text(compactReadout(filter.wrappedValue))
                    .font(DesignSystem.Typography.readout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Toggle("\(title) Enabled", isOn: filter.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if filter.wrappedValue.isEnabled {
                NumericSliderField(
                    title: "Freq",
                    value: filter.frequency,
                    range: EQFrequencyScale.minFrequency...EQFrequencyScale.maxFrequency,
                    sliderRange: log10(EQFrequencyScale.minFrequency)...log10(EQFrequencyScale.maxFrequency),
                    toSlider: { log10($0) },
                    fromSlider: { pow(10, $0) },
                    // Plain Hz, not the abbreviated chip format — this text
                    // is parsed back with `Double.init?(_:)` on commit.
                    format: { String(format: "%.0f", $0) }
                )
                NumericSliderField(
                    title: "Q",
                    value: filter.q,
                    range: 0.1...8,
                    format: { String(format: "%.2f", $0) }
                )
            }
        }
        .padding(DesignSystem.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .materialPanel(cornerRadius: DesignSystem.Metrics.smallCornerRadius)
    }

    private func compactReadout(_ setting: FilterSetting) -> String {
        guard setting.isEnabled else { return "Off" }
        return "\(EQEditor.formattedFrequencyWithUnit(setting.frequency)) \u{00B7} Q \(String(format: "%.2f", setting.q))"
    }
}
