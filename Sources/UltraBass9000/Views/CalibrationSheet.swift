import SwiftUI

/// One measured device's outcome for the result summary.
///
/// `CalibrationState.succeeded` carries only a count, a spread and the *skipped* names — no
/// per-device breakdown. This is reconstructed by `CalibrationSheet` matching those skipped names
/// against `AudioEngine.activeDevices`/`delay(for:)`, which is the only join the contract exposes.
struct DeviceCorrection: Identifiable, Equatable {
    let id: String
    let name: String
    let delay: DeviceDelay
}

/// Engine-aware wrapper for the acoustic auto-sync flow: reads `AudioEngine.calibration`, derives
/// the per-device summary, and forwards everything to the stateless `CalibrationFlowView`.
struct CalibrationSheet: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CalibrationFlowView(
            state: engine.calibration,
            deviceCount: engine.activeDevices.count,
            corrections: corrections,
            onStart: { engine.startCalibration() },
            onRetry: { engine.startCalibration() },
            onCancel: {
                engine.cancelCalibration()
                dismiss()
            },
            onDone: { dismiss() }
        )
    }

    private var corrections: [DeviceCorrection] {
        guard case .succeeded(_, _, let skipped) = engine.calibration else { return [] }
        return engine.activeDevices
            .filter { !skipped.contains($0.name) }
            .map { DeviceCorrection(id: $0.uid, name: $0.name, delay: engine.delay(for: $0.uid)) }
    }
}

/// Pure presentation for every stage of `CalibrationState`. Holds no reference to `AudioEngine` so
/// every case can be previewed directly with synthetic data.
struct CalibrationFlowView: View {
    let state: CalibrationState
    let deviceCount: Int
    let corrections: [DeviceCorrection]
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
        case .succeeded(let alignedDeviceCount, let spreadMilliseconds, let skipped):
            succeededContent(alignedDeviceCount: alignedDeviceCount, spreadMilliseconds: spreadMilliseconds, skipped: skipped)
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

    private func succeededContent(alignedDeviceCount: Int, spreadMilliseconds: Double, skipped: [String]) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.success)
                Text("Aligned \(alignedDeviceCount) \(alignedDeviceCount == 1 ? "Output" : "Outputs")")
                    .font(DesignSystem.Typography.title)
            }
            Text("Corrected a \(DesignSystem.Delay.formattedMilliseconds(spreadMilliseconds)) spread between the earliest and latest arrival.")
                .font(.callout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if !corrections.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("PER-DEVICE CORRECTION").font(DesignSystem.Typography.sectionHeader).foregroundStyle(.secondary)
                    ForEach(corrections) { correction in
                        HStack {
                            Text(correction.name).font(DesignSystem.Typography.stripLabel)
                            Spacer(minLength: DesignSystem.Spacing.sm)
                            Text(DesignSystem.Delay.formattedMilliseconds(correction.delay.milliseconds))
                                .font(DesignSystem.Typography.readout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.sm)
                .materialPanel()
            }

            if !skipped.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("SKIPPED \u{00B7} SET MANUALLY")
                        .font(DesignSystem.Typography.sectionHeader)
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text(skipped.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
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
    CalibrationFlowView(state: .idle, deviceCount: 3, corrections: [],
                        onStart: {}, onRetry: {}, onCancel: {}, onDone: {})
}

#Preview("Preparing") {
    CalibrationFlowView(state: .preparing, deviceCount: 3, corrections: [],
                        onStart: {}, onRetry: {}, onCancel: {}, onDone: {})
}

#Preview("Measuring") {
    CalibrationFlowView(
        state: .measuring(deviceName: "MacBook Pro Speakers", index: 2, total: 3),
        deviceCount: 3, corrections: [],
        onStart: {}, onRetry: {}, onCancel: {}, onDone: {}
    )
}

#Preview("Analysing") {
    CalibrationFlowView(state: .analysing, deviceCount: 3, corrections: [],
                        onStart: {}, onRetry: {}, onCancel: {}, onDone: {})
}

#Preview("Failed") {
    CalibrationFlowView(
        state: .failed("The microphone recorded nothing. Grant UltraBass 9000 microphone access in System Settings \u{203A} Privacy & Security \u{203A} Microphone."),
        deviceCount: 3, corrections: [],
        onStart: {}, onRetry: {}, onCancel: {}, onDone: {}
    )
}

#Preview("Succeeded") {
    CalibrationFlowView(
        state: .succeeded(alignedDeviceCount: 2, spreadMilliseconds: 42.3, skipped: ["AirPods Pro"]),
        deviceCount: 3,
        corrections: [
            DeviceCorrection(id: "1", name: "MacBook Pro Speakers", delay: DeviceDelay(milliseconds: 0, isAutomatic: true)),
            DeviceCorrection(id: "2", name: "Living Room HomePod", delay: DeviceDelay(milliseconds: 42.3, isAutomatic: true)),
        ],
        onStart: {}, onRetry: {}, onCancel: {}, onDone: {}
    )
}
