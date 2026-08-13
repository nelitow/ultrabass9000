import SwiftUI

/// Engine-aware wrapper for the acoustic auto-sync flow: reads `AudioEngine.calibration`, derives
/// the per-device summary, and forwards everything to the stateless `CalibrationFlowView`.
struct CalibrationSheet: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CalibrationFlowView(
            state: engine.calibration,
            deviceCount: engine.activeDevices.count,
            onStart: { engine.startCalibration() },
            onRetry: { engine.startCalibration() },
            onCancel: {
                engine.cancelCalibration()
                dismiss()
            },
            onDone: { dismiss() }
        )
    }

}

/// Pure presentation for every stage of `CalibrationState`. Holds no reference to `AudioEngine` so
/// every case can be previewed directly with synthetic data.
struct CalibrationFlowView: View {
    let state: CalibrationState
    let deviceCount: Int
    let onStart: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Acoustic Auto-Sync")
                .font(DesignSystem.Typography.title)
            Divider()
            ScrollView {
                stageContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 500)
    }

    // MARK: - Stage content

    @ViewBuilder
    private var stageContent: some View {
        switch state {
        case .idle:
            idleContent
        case .preparing:
            stageStatus(title: "Preparing\u{2026}", detail: "Getting the microphone and outputs ready.")
        case .measuring(let deviceName, let index, let total):
            measuringContent(deviceName: deviceName, index: index, total: total)
        case .analysing:
            stageStatus(title: "Analysing\u{2026}", detail: "Comparing arrival times and computing delays.")
        case .failed(let message):
            failedContent(message: message)
        case .succeeded(let results, let spreadMilliseconds):
            succeededContent(results: results, spreadMilliseconds: spreadMilliseconds)
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            explanationRow(
                icon: "waveform",
                text: "Each of your \(deviceCount) selected \(deviceCount == 1 ? "output" : "outputs")"
                    + " plays a short sweep in turn while the built-in microphone listens."
            )
            explanationRow(
                icon: "figure.stand",
                text: "Sit at your normal listening position and keep the room quiet — background"
                    + " noise and movement will throw off the measurement."
            )
            explanationRow(
                icon: "mic.fill",
                text: "The microphone's position becomes the sweet spot: alignment is computed for"
                    + " wherever this Mac is sitting right now."
            )
            explanationRow(
                icon: "exclamationmark.triangle.fill",
                text: "Headphones and earbuds can't be measured this way — the microphone can't hear"
                    + " them. They'll be skipped and need a manual offset.",
                tint: DesignSystem.Colors.warning
            )
        }
    }

    private func explanationRow(icon: String, text: String, tint: Color = DesignSystem.Colors.textSecondary) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stageStatus(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(title).font(DesignSystem.Typography.title)
            }
            Text(detail).font(.callout).foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private func measuringContent(deviceName: String, index: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            stageStatus(title: "Measuring \(deviceName)", detail: "Device \(index) of \(total) \u{00B7} stay quiet and still")
            // `index` is 1-based and counts the device currently playing, so the bar reaches full
            // only while the *last* device's sweep is in flight, not once it's actually done —
            // acceptable imprecision for a few-second, few-device measurement.
            ProgressView(value: Double(index), total: Double(max(total, 1)))
                .tint(DesignSystem.Colors.accent)
        }
    }

    private func failedContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignSystem.Colors.danger)
                Text("Calibration Failed").font(DesignSystem.Typography.title)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private func succeededContent(results: [CalibrationResult], spreadMilliseconds: Double) -> some View {
        let measured = results.filter(\.wasMeasured)
        let skipped = results.filter { !$0.wasMeasured }

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: skipped.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(skipped.isEmpty ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                // Always states the denominator. "Aligned 2 Outputs" next to a list of three reads
                // as a miscount rather than as one device having been skipped.
                Text(skipped.isEmpty
                     ? "Aligned \(measured.count) \(measured.count == 1 ? "output" : "outputs")"
                     : "Aligned \(measured.count) of \(results.count) outputs")
                    .font(DesignSystem.Typography.title)
            }

            Text(measured.count > 1
                 ? "Corrected a \(DesignSystem.Delay.formattedMilliseconds(spreadMilliseconds)) spread between the earliest and latest arrival."
                 : "Nothing to correct — only one output could be measured.")
                .font(.callout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("PER-DEVICE CORRECTION")
                        .font(DesignSystem.Typography.sectionHeader)
                        .foregroundStyle(.secondary)
                    ForEach(results) { result in
                        HStack {
                            Text(result.deviceName)
                                .font(DesignSystem.Typography.stripLabel)
                                .foregroundStyle(result.wasMeasured ? .primary : .secondary)
                            Spacer(minLength: DesignSystem.Spacing.sm)
                            if result.wasMeasured {
                                Text(DesignSystem.Delay.formattedMilliseconds(result.delayMilliseconds))
                                    .font(DesignSystem.Typography.readout)
                                    .foregroundStyle(.secondary)
                            } else {
                                // Never render an unmeasured device as "0.0 ms" — that is
                                // indistinguishable from a device that was measured and needed no
                                // correction, which is the opposite of what happened.
                                Text("not heard")
                                    .font(DesignSystem.Typography.readout)
                                    .foregroundStyle(DesignSystem.Colors.warning)
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.sm)
                .materialPanel()
            }

            if !skipped.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("SET THESE MANUALLY")
                        .font(DesignSystem.Typography.sectionHeader)
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text("\(skipped.map(\.deviceName).joined(separator: ", ")) — the microphone could not hear "
                         + (skipped.count == 1 ? "it" : "them") + ". "
                         + "Headphones and earbuds never can be; a device with nothing plugged into it will not be either. "
                         + "Any existing delay on \(skipped.count == 1 ? "it" : "them") was left untouched.")
                        .font(.callout)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Footer

    /// Cancel calls `cancelCalibration()` at every stage that could still be running or retried —
    /// only `.succeeded` drops it, since there is nothing left to cancel and the applied delays
    /// shouldn't be touched by a button labelled "Cancel".
    private var isCancelable: Bool {
        if case .succeeded = state { return false }
        return true
    }

    private var footer: some View {
        HStack {
            if isCancelable {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
            }
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch state {
        case .idle:
            Button("Start Calibration", action: onStart)
                .buttonStyle(.borderedProminent)
        case .failed:
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        case .succeeded:
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .preparing, .measuring, .analysing:
            EmptyView()
        }
    }
}

// MARK: - Previews

#Preview("Idle") {
    CalibrationFlowView(state: .idle, deviceCount: 3,
                        onStart: {}, onRetry: {}, onCancel: {}, onDone: {})
}

#Preview("Preparing") {
    CalibrationFlowView(state: .preparing, deviceCount: 3,
                        onStart: {}, onRetry: {}, onCancel: {}, onDone: {})
}

#Preview("Measuring") {
    CalibrationFlowView(
        state: .measuring(deviceName: "MacBook Pro Speakers", index: 2, total: 3),
        deviceCount: 3,
        onStart: {}, onRetry: {}, onCancel: {}, onDone: {}
    )
}

#Preview("Analysing") {
    CalibrationFlowView(state: .analysing, deviceCount: 3,
                        onStart: {}, onRetry: {}, onCancel: {}, onDone: {})
}

#Preview("Failed") {
    CalibrationFlowView(
        state: .failed("The microphone recorded nothing. Grant UltraBass 9000 microphone access in System Settings \u{203A} Privacy & Security \u{203A} Microphone."),
        deviceCount: 3,
        onStart: {}, onRetry: {}, onCancel: {}, onDone: {}
    )
}

#Preview("Succeeded") {
    CalibrationFlowView(
        state: .succeeded(
            results: [
                CalibrationResult(uid: "1", deviceName: "MacBook Pro Speakers",
                                  delayMilliseconds: 0, confidence: 0.41, wasMeasured: true),
                CalibrationResult(uid: "2", deviceName: "Living Room HomePod",
                                  delayMilliseconds: 42.3, confidence: 0.33, wasMeasured: true),
                CalibrationResult(uid: "3", deviceName: "AirPods Pro",
                                  delayMilliseconds: 0, confidence: 0.04, wasMeasured: false),
            ],
            spreadMilliseconds: 42.3),
        deviceCount: 3,
        onStart: {}, onRetry: {}, onCancel: {}, onDone: {}
    )
}
