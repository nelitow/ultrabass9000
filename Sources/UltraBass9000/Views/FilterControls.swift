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
                    bandPassSection
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
                slopePicker(selection: filter.slope)
            }
        }
        .padding(DesignSystem.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .materialPanel(cornerRadius: DesignSystem.Metrics.smallCornerRadius)
    }

    // MARK: Band-pass

    /// Two corners rather than one, because a band is defined by where it starts and where it ends.
    private var bandPassSection: some View {
        let band = bandPassBinding
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text("Band-Pass").font(DesignSystem.Typography.stripLabel)
                Spacer(minLength: 0)
                Text(bandReadout(band.wrappedValue))
                    .font(DesignSystem.Typography.readout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Toggle("Band-Pass Enabled", isOn: band.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if band.wrappedValue.isEnabled {
                NumericSliderField(
                    title: "Low",
                    value: band.lowFrequency,
                    range: EQFrequencyScale.minFrequency...EQFrequencyScale.maxFrequency,
                    sliderRange: log10(EQFrequencyScale.minFrequency)...log10(EQFrequencyScale.maxFrequency),
                    toSlider: { log10($0) },
                    fromSlider: { pow(10, $0) },
                    format: { String(format: "%.0f", $0) }
                )
                NumericSliderField(
                    title: "High",
                    value: band.highFrequency,
                    range: EQFrequencyScale.minFrequency...EQFrequencyScale.maxFrequency,
                    sliderRange: log10(EQFrequencyScale.minFrequency)...log10(EQFrequencyScale.maxFrequency),
                    toSlider: { log10($0) },
                    fromSlider: { pow(10, $0) },
                    format: { String(format: "%.0f", $0) }
                )
                slopePicker(selection: band.slope)
                Text(String(format: "%.2f octaves wide", band.wrappedValue.widthInOctaves))
                    .font(.caption2)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(DesignSystem.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .materialPanel(cornerRadius: DesignSystem.Metrics.smallCornerRadius)
    }

    private var bandPassBinding: Binding<BandPassSetting> {
        Binding(
            get: { processing.bandPass },
            set: { newValue in
                var p = engine.processing(for: device.uid)
                p.bandPass = newValue
                engine.setProcessing(p, for: device.uid)
            }
        )
    }

    private func slopePicker(selection: Binding<FilterSlope>) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Text("Slope")
                .font(DesignSystem.Typography.readout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 40, alignment: .leading)
            Picker("Slope", selection: selection) {
                ForEach(FilterSlope.allCases) { slope in
                    Text("\(slope.rawValue)").tag(slope)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            Text("dB/oct")
                .font(.caption2)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private func compactReadout(_ setting: FilterSetting) -> String {
        guard setting.isEnabled else { return "Off" }
        return "\(EQEditor.formattedFrequencyWithUnit(setting.frequency)) \u{00B7} \(setting.slope.rawValue) dB/oct"
    }

    private func bandReadout(_ setting: BandPassSetting) -> String {
        guard setting.isEnabled else { return "Off" }
        let clamped = setting.clamped
        return "\(EQEditor.formattedFrequencyWithUnit(clamped.lowFrequency))\u{2013}"
            + "\(EQEditor.formattedFrequencyWithUnit(clamped.highFrequency)) \u{00B7} \(setting.slope.rawValue) dB/oct"
    }
}
