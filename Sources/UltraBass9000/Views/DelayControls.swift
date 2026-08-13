import SwiftUI

/// Per-device delay editing: the "hold this device back" control that keeps every output arriving
/// at the same moment. Mirrors `FilterControls`' layout — icon-led header with a badge, a labeled
/// slider+field row, small print underneath — so the two feel like the same instrument.
struct DelayControls: View {
    @Environment(AudioEngine.self) private var engine
    let device: AudioDevice

    /// Live position while an edit is in progress; `nil` once it's committed. Every call to
    /// `AudioEngine.setDelayMilliseconds` fades the delay line out and back in (~10 ms each way, to
    /// avoid a click when the read pointer jumps), so writing on every change would turn a single
    /// gesture into a stutter machine. This buffers edits locally — readout and slider stay smooth —
    /// and commits to the engine once things settle. Same reasoning is why the text field commits on
    /// submit/blur rather than per keystroke.
    @State private var draftMilliseconds: Double?
    /// Debounced fallback commit, armed on every slider change and re-armed (cancelling the
    /// previous one) on the next. `Slider.onEditingChanged` reliably brackets a click-drag with
    /// true/false, but a plain click on the track or a keyboard/VoiceOver nudge changes the value
    /// without ever firing it — without this, those edits would show in the readout and then
    /// silently revert the next time `delay.milliseconds` is read. During an actual drag this timer
    /// keeps getting cancelled and re-armed on every tick, so it does not reintroduce a per-tick
    /// write; `handleEditingChanged` still commits immediately on release for a snappier feel.
    @State private var commitTask: Task<Void, Never>?
    @State private var text: String = ""
    @FocusState private var isFieldFocused: Bool

    private var delay: DeviceDelay { engine.delay(for: device.uid) }

    /// Not always 500 ms: the delay buffer is a fixed number of frames, so the ceiling shrinks as
    /// the device sample rate rises.
    private var maximumMilliseconds: Double { max(0, engine.maximumDelayMilliseconds) }

    /// What the slider and readouts show: the live drag/edit position while one is in progress,
    /// otherwise the value already committed to `AudioEngine`.
    private var displayedMilliseconds: Double { draftMilliseconds ?? delay.milliseconds }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            sliderRow
            Text(distanceReadout)
                .font(DesignSystem.Typography.readout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if !engine.syncEnabled {
                Text("Sync is off, so this has no audible effect right now.")
                    .font(.caption2)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .onAppear { text = Self.formattedForEditing(displayedMilliseconds) }
        .onChange(of: delay.milliseconds) { _, newValue in
            if draftMilliseconds == nil, !isFieldFocused { text = Self.formattedForEditing(newValue) }
        }
        .onDisappear { commitTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "timer")
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text("Delay").font(DesignSystem.Typography.title)
            sourceBadge
            Spacer(minLength: 0)
            Button("Clear") {
                // A pending debounced commit (see `commitTask`) must not resurrect the value this
                // just cleared a moment later.
                commitTask?.cancel()
                commitTask = nil
                draftMilliseconds = nil
                engine.clearDelay(for: device.uid)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(delay.milliseconds == 0)
        }
    }

    /// Always shown, not only for the automatic case — AUTO vs MANUAL is the one thing this control
    /// exists to make legible. Filled for AUTO, outlined for MANUAL, so the distinction doesn't rely
    /// on color alone.
    private var sourceBadge: some View {
        Text(delay.isAutomatic ? "AUTO" : "MANUAL")
            .font(DesignSystem.Typography.badge)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(delay.isAutomatic ? .white : DesignSystem.Colors.textSecondary)
            .background(delay.isAutomatic ? DesignSystem.Colors.accent : Color.clear, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    DesignSystem.Colors.hairline,
                    lineWidth: delay.isAutomatic ? 0 : DesignSystem.Metrics.hairlineWidth
                )
            )
    }

    // MARK: - Slider + field

    /// Deliberately not `EQEditor`'s shared `NumericSliderField`: that component's slider writes
    /// its bound value on every drag tick, which is correct for EQ/filter parameters but would
    /// stutter delay's fade-out/fade-in. This row buffers the drag instead (see `draftMilliseconds`).
    private var sliderRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Text("ms")
                .font(DesignSystem.Typography.stripLabel)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 56, alignment: .leading)

            Slider(value: sliderBinding, in: 0...maximumMilliseconds, onEditingChanged: handleEditingChanged)

            TextField("Delay", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(DesignSystem.Typography.readout)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
                .focused($isFieldFocused)
                .onSubmit(commitText)
                .onChange(of: isFieldFocused) { _, focused in if !focused { commitText() } }
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { displayedMilliseconds },
            set: { newValue in
                let clamped = newValue.clamped(to: 0...maximumMilliseconds)
                draftMilliseconds = clamped
                scheduleCommit(clamped)
            }
        )
    }

    /// Fires on drag release for an immediate, non-debounced commit. `scheduleCommit`'s timer is
    /// still the one that catches everything this doesn't (see `commitTask`'s doc comment).
    private func handleEditingChanged(_ isEditing: Bool) {
        guard !isEditing, let draftMilliseconds else { return }
        commit(draftMilliseconds)
    }

    private func scheduleCommit(_ milliseconds: Double) {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            commit(milliseconds)
        }
    }

    private func commit(_ milliseconds: Double) {
        commitTask?.cancel()
        commitTask = nil
        engine.setDelayMilliseconds(milliseconds, for: device.uid)
        text = Self.formattedForEditing(milliseconds)
        draftMilliseconds = nil
    }

    private func commitText() {
        if let parsed = Double(text.trimmingCharacters(in: .whitespaces)) {
            commit(parsed.clamped(to: 0...maximumMilliseconds))
        } else {
            text = Self.formattedForEditing(displayedMilliseconds)
        }
    }

    /// Plain digits, no unit suffix — this text is round-tripped through `Double.init?(_:)` on
    /// commit, same constraint `FilterControls`/`EQEditor` document for their numeric fields.
    private static func formattedForEditing(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }

    // MARK: - Readout

    private var distanceReadout: String {
        "\(DesignSystem.Delay.formattedMilliseconds(displayedMilliseconds)) \u{00B7} "
            + "\(DesignSystem.Delay.formattedDistance(displayedMilliseconds)) of air"
    }
}
