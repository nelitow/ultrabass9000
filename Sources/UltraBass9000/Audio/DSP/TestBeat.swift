import Foundation

/// The transient played by the beat button, used to hear whether alignment worked.
///
/// Two components on purpose. A short noise burst gives the sharp attack the ear uses to place a
/// sound in time, which is what makes two devices a few milliseconds apart audible as an echo
/// rather than as a vague smear. A low sine thump underneath gives the beat energy below the
/// crossover point, so a device that has been low-passed to 120 Hz still produces something and
/// still gets tested. A click made only of high frequencies would go silent on exactly the device a
/// subwoofer crossover exists to feed.
enum TestBeat {

    /// Total length of one hit. Long enough for the thump to develop, short enough that two hits
    /// 4 ms apart are heard as two events rather than one thickened one.
    static let duration: Double = 0.14
    /// Frequency of the low component. Below most crossover points, above what small speakers give
    /// up on entirely.
    static let thumpFrequency: Double = 62
    /// How long the noise attack takes to decay to silence.
    static let attackDecay: Double = 0.012

    static func waveform(sampleRate: Double) -> [Float] {
        guard sampleRate > 0 else { return [] }
        let frameCount = Int(duration * sampleRate)
        guard frameCount > 1 else { return [] }

        // Deterministic noise: the same beat every time, so a difference the user hears is a
        // difference in their setup rather than in the test signal.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }

        var samples = [Float](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let t = Double(index) / sampleRate

            let attackEnvelope = exp(-t / attackDecay)
            let attack = Double(noise()) * attackEnvelope * 0.6

            // The thump decays more slowly, so the beat has weight after the click has gone.
            let thumpEnvelope = exp(-t / (duration * 0.28))
            let thump = sin(2 * .pi * thumpFrequency * t) * thumpEnvelope * 0.7

            samples[index] = Float(attack + thump)
        }

        // Taper the tail so the hit ends at silence rather than at whatever the envelope had
        // reached, which would itself be a click.
        let tail = max(1, frameCount / 8)
        for index in (frameCount - tail)..<frameCount {
            let position = Double(index - (frameCount - tail)) / Double(tail)
            samples[index] *= Float(0.5 + 0.5 * cos(.pi * position))
        }

        return samples
    }
}
