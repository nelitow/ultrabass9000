import SwiftUI

/// Root layout: a device sidebar on the left, and on the right a toolbar
/// (status, transport, master gain) above the mixer — one `DeviceStrip`
/// per active output, or an empty state when nothing is selected.
struct ContentView: View {
    @Environment(AudioEngine.self) private var engine

    /// Presentation-only: which diagnostics the user has dismissed this
    /// session. `AudioEngine.diagnostics` has no dismiss API, so banners
    /// are just filtered locally by id.
    @State private var dismissedDiagnosticIDs: Set<String> = []
    @State private var isCalibrationSheetPresented = false

    private var visibleDiagnostics: [EngineDiagnostic] {
        engine.diagnostics.filter { !dismissedDiagnosticIDs.contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            DeviceListSidebar()
                .navigationSplitViewColumnWidth(
                    min: 220, ideal: DesignSystem.Metrics.sidebarWidth, max: 340
                )
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                mixerArea
            }
            .background(DesignSystem.Colors.canvas)
        }
        .navigationTitle("UltraBass 9000")
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        GlassEffectContainer(spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.md) {
                statusPill
                startStopButton
                Spacer(minLength: DesignSystem.Spacing.lg)
                syncControl
                autoSyncButton
                masterGainControl
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .sheet(isPresented: $isCalibrationSheetPresented) {
            CalibrationSheet()
        }
    }

    private var statusPill: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Circle()
                .fill(engine.status.indicatorColor)
                .frame(width: 8, height: 8)
            Text(engine.status.label)
                .font(DesignSystem.Typography.stripLabel)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .floatingPill()
    }

    private var startStopButton: some View {
        Button {
            engine.status.isActive ? engine.stop() : engine.start()
        } label: {
            Label(
                engine.status.isActive ? "Stop" : "Start",
                systemImage: engine.status.isActive ? "stop.fill" : "play.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.status.isActive ? DesignSystem.Colors.danger : DesignSystem.Colors.accent)
    }

    private var masterGainControl: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                engine.isMasterMuted.toggle()
            } label: {
                Image(systemName: engine.isMasterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)

            Slider(value: masterGainBinding, in: 0...1)
                .frame(width: 160)
                .disabled(engine.isMasterMuted)

            Text(DesignSystem.Gain.formattedDB(fromLinear: engine.masterGain))
                .font(DesignSystem.Typography.readout)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .floatingPill()
    }

    private var masterGainBinding: Binding<Double> {
        Binding(
            get: { Double(engine.masterGain) },
            set: { engine.masterGain = Float($0) }
        )
    }

    // MARK: - Sync

    /// Master on/off plus the honest cost of being on: the largest delay currently applied, when
    /// there is one. When sync is off that cost is zero by definition, so the pill switches to
    /// saying so explicitly rather than just going quiet — the low-latency state should be as
    /// visible as the latency cost is.
    private var syncControl: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: engine.syncEnabled ? "arrow.triangle.branch" : "bolt.fill")
                .foregroundStyle(engine.syncEnabled ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.success)

            Toggle("Sync", isOn: syncEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()

            if !engine.syncEnabled {
                Text("Lowest Latency")
                    .font(DesignSystem.Typography.readout)
                    .foregroundStyle(DesignSystem.Colors.success)
            } else if engine.syncLatencyMilliseconds > 0 {
                Text("Sync +\(DesignSystem.Delay.formattedMilliseconds(engine.syncLatencyMilliseconds))")
                    .font(DesignSystem.Typography.readout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .floatingPill()
    }

    private var syncEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.syncEnabled },
            set: { engine.syncEnabled = $0 }
        )
    }

    private var autoSyncButton: some View {
        Button {
            isCalibrationSheetPresented = true
        } label: {
            Label("Auto-Sync", systemImage: "waveform.and.mic")
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Mixer

    private var mixerArea: some View {
        VStack(spacing: 0) {
            if !visibleDiagnostics.isEmpty {
                diagnosticsBanner
            }

            if engine.activeDevices.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        ForEach(Array(engine.activeDevices.enumerated()), id: \.element.uid) { index, device in
                            DeviceStrip(device: device, isClock: index == 0)
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnosticsBanner: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(visibleDiagnostics) { diagnostic in
                DiagnosticBanner(diagnostic: diagnostic) {
                    dismissedDiagnosticIDs.insert(diagnostic.id)
                }
            }
        }
        .padding([.horizontal, .top], DesignSystem.Spacing.lg)
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Outputs Selected")
                .font(DesignSystem.Typography.title)
            Text("Choose one or more outputs from the sidebar to start mixing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A single dismissible diagnostic banner.
private struct DiagnosticBanner: View {
    let diagnostic: EngineDiagnostic
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.title).font(DesignSystem.Typography.stripLabel)
                Text(diagnostic.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(DesignSystem.Spacing.sm)
        .materialPanel()
    }
}
