import SwiftUI

/// A cheap scrolling amplitude envelope for one device: newest sample on the
/// right, drawn as a filled min/max band around a centre line.
///
/// This view holds no state and starts no timer of its own — the caller (a
/// thin polling wrapper, mirroring `LevelMeter`'s usage in `DeviceStrip`)
/// re-renders it by changing `samples`, typically from `AudioEngine
/// .waveform(for:)` republished ~30x/sec. Per redraw this builds exactly two
/// `Path` values and does no other allocation, so it stays cheap even at
/// that cadence.
struct WaveformView: View {
    var samples: [WaveformSample]
    var color: Color = DesignSystem.Colors.waveform

    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size)
        }
        // Decorative: level and clipping are already conveyed by LevelMeter
        // and the dB readout, so this doesn't need its own accessibility value.
        .accessibilityHidden(true)
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let midY = size.height / 2

        // Centre line first so the envelope, when present, sits on top of it.
        var centre = Path()
        centre.move(to: CGPoint(x: 0, y: midY))
        centre.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(centre, with: .color(DesignSystem.Colors.hairline.opacity(0.6)), lineWidth: 1)

        // Fewer than two samples can't describe an envelope shape (a single
        // point has no width to fill) — degrade to the centre line alone.
        guard samples.count > 1 else { return }

        let step = size.width / CGFloat(samples.count)
        var envelope = Path()
        envelope.move(to: point(forSampleIndex: 0, using: \.max, step: step, midY: midY))
        for index in samples.indices {
            envelope.addLine(to: point(forSampleIndex: index, using: \.max, step: step, midY: midY))
        }
        for index in samples.indices.reversed() {
            envelope.addLine(to: point(forSampleIndex: index, using: \.min, step: step, midY: midY))
        }
        envelope.closeSubpath()

        context.fill(envelope, with: .color(color.opacity(0.55)))
        context.stroke(envelope, with: .color(color.opacity(0.9)), lineWidth: 1)
    }

    private func point(forSampleIndex index: Int, using keyPath: KeyPath<WaveformSample, Float>, step: CGFloat, midY: CGFloat) -> CGPoint {
        let x = (CGFloat(index) + 0.5) * step
        let y = midY - CGFloat(samples[index][keyPath: keyPath]) * midY
        return CGPoint(x: x, y: y)
    }
}

#Preview("Waveform") {
    // Synthetic envelope: a decaying sine burst followed by near-silence,
    // enough to exercise both the filled and flat-line regions at once.
    let syntheticSamples: [WaveformSample] = (0..<480).map { i in
        let t = Double(i)
        let decay = max(0, 1 - t / 340)
        let amplitude = Float(decay * (0.15 + 0.85 * abs(sin(t * 0.12))))
        return WaveformSample(min: -amplitude, max: amplitude)
    }

    VStack(spacing: DesignSystem.Spacing.lg) {
        WaveformView(samples: syntheticSamples)
            .frame(height: DesignSystem.Metrics.waveformHeight)
        WaveformView(samples: Array(syntheticSamples.prefix(12)))
            .frame(height: DesignSystem.Metrics.waveformHeight)
        WaveformView(samples: [])
            .frame(height: DesignSystem.Metrics.waveformHeight)
    }
    .padding(DesignSystem.Spacing.lg)
    .frame(width: 320)
    .background(DesignSystem.Colors.canvas)
}
