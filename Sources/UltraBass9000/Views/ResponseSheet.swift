import SwiftUI

/// Sheet wrapping `ResponseChart` with a title, an honest explanation of what the measurement can
/// and can't tell the user, and an empty state pointing at Auto-Sync when nothing has been
/// measured yet.
struct ResponseSheet: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    /// Expanded the first time, so the caveats are read once, then collapsible out of the way.
    @State private var isExplanationExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header
            Divider()
            if engine.hasMeasuredResponses {
                // The chart is the reason this sheet exists, so it takes the space and the caveats
                // scroll behind a disclosure. Putting both in one scroll view left the plot squeezed
                // into a strip below three paragraphs of text nobody needs to reread.
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    ResponseChart()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    DisclosureGroup(isExpanded: $isExplanationExpanded) {
                        explanation
                    } label: {
                        Text("What this is worth")
                            .font(DesignSystem.Typography.sectionHeader)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 720, idealWidth: 900, minHeight: 560, idealHeight: 700)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "chart.xyaxis.line")
                .foregroundStyle(DesignSystem.Colors.accent)
            Text("Measured Response").font(DesignSystem.Typography.title)
        }
    }

    // MARK: Explanation

    private var explanation: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("These curves come from the sweep Auto-Sync plays and records on the built-in "
                 + "microphone. That microphone has a response of its own, and nothing here "
                 + "corrects for it, so read a single curve's shape with some suspicion.")
                .font(.callout)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The comparison between devices is the trustworthy part, since the same "
                 + "microphone in the same spot heard all of them. Below about 300 Hz, one "
                 + "microphone position picks up the room about as much as the speaker, so treat "
                 + "the low end as a rough guide.")
                .font(.callout)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Use it to see which device produces what, and to check a crossover you've set "
                 + "against where a device's own output actually starts falling away.")
                .font(.callout)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.sm)
        .materialPanel()
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Nothing Measured Yet")
                .font(DesignSystem.Typography.title)
            Text("Run Auto-Sync first. It plays a sweep from each output and listens for it, and "
                 + "this chart is what came back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
