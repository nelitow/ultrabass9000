import SwiftUI

/// Output device picker. "Outputs" holds the current selection in clock
/// order and is drag-reorderable; "Available" holds every other routable
/// device. Tapping either toggles selection.
struct DeviceListSidebar: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(AudioDeviceRegistry.self) private var registry

    private var availableDevices: [AudioDevice] {
        let selected = Set(engine.selectedOutputUIDs)
        return registry.routableOutputDevices.filter { !selected.contains($0.uid) }
    }

    var body: some View {
        List {
            if !engine.activeDevices.isEmpty {
                Section {
                    ForEach(Array(engine.activeDevices.enumerated()), id: \.element.uid) { index, device in
                        activeRow(device: device, position: index)
                    }
                    .onMove { offsets, destination in
                        engine.moveSelection(fromOffsets: offsets, toOffset: destination)
                    }
                } header: {
                    sectionHeader("OUTPUTS", subtitle: "Drag to set clock priority")
                }
            }

            Section {
                if availableDevices.isEmpty {
                    Text("No other outputs found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableDevices) { device in
                        availableRow(device: device)
                    }
                }
            } header: {
                sectionHeader("AVAILABLE", subtitle: nil)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.panel)
        .frame(minWidth: DesignSystem.Metrics.sidebarWidth)
    }

    // MARK: - Rows

    private func activeRow(device: AudioDevice, position: Int) -> some View {
        Button {
            engine.toggleSelection(uid: device.uid)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if position == 0 {
                    Text("CLOCK")
                        .font(DesignSystem.Typography.badge)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(DesignSystem.Colors.clock, in: Capsule())
                } else {
                    Text("\(position + 1)")
                        .font(DesignSystem.Typography.readout)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }

                deviceRowBody(device: device)

                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func availableRow(device: AudioDevice) -> some View {
        Button {
            engine.toggleSelection(uid: device.uid)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)

                deviceRowBody(device: device)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func deviceRowBody(device: AudioDevice) -> some View {
        Image(systemName: device.transport.symbolName)
            .frame(width: 18)
            .foregroundStyle(DesignSystem.Colors.textSecondary)

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(device.name)
                    .font(DesignSystem.Typography.stripLabel)
                    .lineLimit(1)
                if device.id == registry.defaultOutputDeviceID {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                        .help("System default output")
                }
            }
            Text("\(device.outputChannels) ch \u{00B7} \(Int(device.nominalSampleRate.rounded())) Hz")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)

        Spacer(minLength: 0)
    }

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DesignSystem.Typography.sectionHeader)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
