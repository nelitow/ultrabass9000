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
    @State private var isResponseSheetPresented = false

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
            // Deliberately not chained onto `toolbar`'s own `.sheet(isPresented:)` below: two
            // `.sheet` modifiers on the same view is a known SwiftUI footgun, so this one gets its
            // own view in the hierarchy instead of trusting that they'd coexist.
            .sheet(isPresented: $isResponseSheetPresented) {
                ResponseSheet()
            }
            // Development affordance, alongside -UB9KAutoStart and -UB9KCalibrate: opens the
            // response chart as soon as there is something to plot, so the whole measure-and-draw
            // path can be exercised from a script. Does nothing without the flag.
            .task {
                guard UserDefaults.standard.bool(forKey: "UB9KShowResponse") else { return }
                for _ in 0..<90 {
                    if engine.hasMeasuredResponses {
                        isResponseSheetPresented = true
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        .navigationTitle("ULTRABASS:9000")
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        GlassEffectContainer(spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.md) {
                statusPill
                startStopButton
                Spacer(minLength: DesignSystem.Spacing.lg)
                syncControl
                beatButton
                autoSyncButton
                responseButton
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
                .lineLimit(1)
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
                    .lineLimit(1)
            } else if engine.syncLatencyMilliseconds > 0 {
                Text("Sync +\(DesignSystem.Delay.formattedMilliseconds(engine.syncLatencyMilliseconds))")
                    .font(DesignSystem.Typography.readout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
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

    /// Plays a repeating transient on every output at once, so alignment can be checked by ear.
    /// Aligned devices sound like one hit. Misaligned ones sound like a slap echo, which is much
    /// easier to hear than to read off a number.
    private var beatButton: some View {
        Button {
            engine.toggleBeat()
        } label: {
            Label(engine.isBeatPlaying ? "Stop Beat" : "Beat",
                  systemImage: engine.isBeatPlaying ? "stop.circle.fill" : "metronome")
        }
        .buttonStyle(.bordered)
        .tint(engine.isBeatPlaying ? DesignSystem.Colors.accent : nil)
        .disabled(engine.status != .running)
        .help(engine.status == .running
              ? "Play a test beat on every output to hear whether they are aligned. Replaces the audio while it runs."
              : "Start playback first.")
    }

    /// Opens the measured-response chart. Disabled rather than hidden when there's nothing to
    /// show yet, so the button stays discoverable and its tooltip can say why it's greyed out
    /// instead of the control just disappearing.
    private var responseButton: some View {
        Button {
            isResponseSheetPresented = true
        } label: {
            Label("Response", systemImage: "chart.xyaxis.line")
        }
        .buttonStyle(.bordered)
        .disabled(!engine.hasMeasuredResponses)
        .help(engine.hasMeasuredResponses
              ? "See each device's measured frequency response."
              : "Run Auto-Sync first to measure a response.")
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
                mixerStrips
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Strips divide the available width and fill the height, and only start scrolling once there
    /// are more devices than fit at the minimum width.
    ///
    /// The width has to be measured rather than expressed as `maxWidth: .infinity` inside a
    /// horizontal `ScrollView`. A scroll view offers its content unbounded width along its scroll
    /// axis, so "as wide as possible" resolves to the content's ideal size and every strip collapses
    /// to its minimum with the remaining space left blank beside it.
    private var mixerStrips: some View {
        GeometryReader { proxy in
            let devices = engine.activeDevices
            let padding = DesignSystem.Spacing.lg * 2
            let gaps = CGFloat(max(devices.count - 1, 0)) * DesignSystem.Spacing.md
            let required = CGFloat(devices.count) * DesignSystem.Metrics.stripMinWidth + gaps
            let fits = required <= proxy.size.width - padding

            Group {
                if fits {
                    strips(devices, width: nil)
                } else {
                    ScrollView(.horizontal) {
                        strips(devices, width: DesignSystem.Metrics.stripMinWidth)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    /// - Parameter width: fixed strip width when scrolling, or `nil` to share the space evenly.
    private func strips(_ devices: [AudioDevice], width: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ForEach(Array(devices.enumerated()), id: \.element.uid) { index, device in
                DeviceStrip(device: device, isClock: index == 0)
                    .frame(width: width)
                    .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity)
            }
        }
        .padding(DesignSystem.Spacing.lg)
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
