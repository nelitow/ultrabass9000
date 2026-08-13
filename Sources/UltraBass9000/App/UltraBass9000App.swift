import SwiftUI

@main
struct UltraBass9000App: App {
    @State private var registry: AudioDeviceRegistry
    @State private var engine: AudioEngine

    init() {
        let registry = AudioDeviceRegistry()
        _registry = State(initialValue: registry)
        _engine = State(initialValue: AudioEngine(registry: registry))
    }

    var body: some Scene {
        Window("UltraBass 9000", id: "main") {
            ContentView()
                .environment(engine)
                .environment(registry)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 880, height: 600)
        .windowResizability(.contentMinSize)

        MenuBarExtra("UltraBass 9000", systemImage: "waveform") {
            MenuBarPopoverView()
                .environment(engine)
                .environment(registry)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact popover shown from the menu bar: engine status + transport,
/// master volume, and a scannable list of active devices with meters.
private struct MenuBarPopoverView: View {
    @Environment(AudioEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            Divider()
            masterControls

            if !engine.activeDevices.isEmpty {
                Divider()
                deviceList
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(width: 260)
        .floatingPanel(cornerRadius: DesignSystem.Metrics.cornerRadius)
    }

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Circle()
                .fill(engine.status.indicatorColor)
                .frame(width: 8, height: 8)
            Text(engine.status.label)
                .font(DesignSystem.Typography.stripLabel)
            Spacer(minLength: DesignSystem.Spacing.sm)
            Button(engine.status.isActive ? "Stop" : "Start") {
                engine.status.isActive ? engine.stop() : engine.start()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var masterControls: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                engine.isMasterMuted.toggle()
            } label: {
                Image(systemName: engine.isMasterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)

            Slider(value: masterGainBinding, in: 0...1)
                .disabled(engine.isMasterMuted)

            Text(DesignSystem.Gain.formattedDB(fromLinear: engine.masterGain))
                .font(DesignSystem.Typography.readout)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var masterGainBinding: Binding<Double> {
        Binding(
            get: { Double(engine.masterGain) },
            set: { engine.masterGain = Float($0) }
        )
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ForEach(Array(engine.activeDevices.enumerated()), id: \.element.uid) { index, device in
                MenuBarDeviceRow(device: device, isClock: index == 0)
            }
        }
    }
}

private struct MenuBarDeviceRow: View {
    @Environment(AudioEngine.self) private var engine
    let device: AudioDevice
    let isClock: Bool

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: device.transport.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(device.name)
                .font(.caption)
                .lineLimit(1)

            if isClock {
                Text("CLOCK")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(DesignSystem.Colors.clock, in: Capsule())
            }

            Spacer(minLength: 4)

            LevelMeter(level: engine.peak(for: device.uid), isMuted: engine.isMuted(device.uid))
                .frame(width: 6, height: 18)
        }
    }
}
