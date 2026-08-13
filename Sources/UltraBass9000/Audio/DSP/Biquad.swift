import Foundation

/// Normalised second-order IIR section: `y = b0·x + b1·x₋₁ + b2·x₋₂ − a1·y₋₁ − a2·y₋₂`.
///
/// Coefficients are pre-divided by `a0`, so the render thread never divides.
struct BiquadCoefficients: Equatable {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    /// Passes signal through untouched.
    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Magnitude response at a normalised angular frequency, as a linear ratio.
    ///
    /// Evaluates `H(e^{jω})` directly rather than using the squared-magnitude shortcut, because the
    /// shortcut is easy to mistype and this runs on the main thread for drawing, never in the
    /// render callback.
    func magnitude(atAngularFrequency omega: Double) -> Double {
        let cos1 = cos(omega), sin1 = sin(omega)
        let cos2 = cos(2 * omega), sin2 = sin(2 * omega)

        let numeratorReal = Double(b0) + Double(b1) * cos1 + Double(b2) * cos2
        let numeratorImaginary = -(Double(b1) * sin1 + Double(b2) * sin2)
        let denominatorReal = 1 + Double(a1) * cos1 + Double(a2) * cos2
        let denominatorImaginary = -(Double(a1) * sin1 + Double(a2) * sin2)

        let numerator = (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary).squareRoot()
        let denominator = (denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary).squareRoot()
        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }

    /// A section is stable when both poles sit inside the unit circle, which for a normalised
    /// biquad reduces to these two triangle inequalities.
    var isStable: Bool {
        abs(a2) < 1 && abs(a1) < 1 + a2
    }
}

/// Coefficient design, following the Audio EQ Cookbook (Robert Bristow-Johnson).
enum BiquadDesign {

    /// Frequencies are clamped away from DC and Nyquist: the cookbook formulas produce degenerate
    /// or unstable sections at exactly 0 or Fs/2, and a user dragging a handle will reach both.
    static let minimumFrequency: Double = 10
    static let minimumQ: Double = 0.05

    static func clampedOmega(frequency: Double, sampleRate: Double) -> Double {
        let nyquist = sampleRate / 2
        let clamped = min(max(frequency, minimumFrequency), nyquist * 0.995)
        return 2 * .pi * clamped / sampleRate
    }

    static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let w0 = clampedOmega(frequency: frequency, sampleRate: sampleRate)
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * max(q, minimumQ))
        let a0 = 1 + alpha
        return normalise(b0: (1 - cosW0) / 2, b1: 1 - cosW0, b2: (1 - cosW0) / 2,
                         a0: a0, a1: -2 * cosW0, a2: 1 - alpha)
    }

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let w0 = clampedOmega(frequency: frequency, sampleRate: sampleRate)
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * max(q, minimumQ))
        let a0 = 1 + alpha
        return normalise(b0: (1 + cosW0) / 2, b1: -(1 + cosW0), b2: (1 + cosW0) / 2,
                         a0: a0, a1: -2 * cosW0, a2: 1 - alpha)
    }

    /// Constant 0 dB peak gain variant, so enabling a band-pass does not change perceived level at
    /// the centre frequency.
    static func bandPass(frequency: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let w0 = clampedOmega(frequency: frequency, sampleRate: sampleRate)
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * max(q, minimumQ))
        let a0 = 1 + alpha
        return normalise(b0: alpha, b1: 0, b2: -alpha,
                         a0: a0, a1: -2 * cosW0, a2: 1 - alpha)
    }

    static func notch(frequency: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let w0 = clampedOmega(frequency: frequency, sampleRate: sampleRate)
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * max(q, minimumQ))
        let a0 = 1 + alpha
        return normalise(b0: 1, b1: -2 * cosW0, b2: 1,
                         a0: a0, a1: -2 * cosW0, a2: 1 - alpha)
    }

    static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let amplitude = pow(10, gainDB / 40)
        let w0 = clampedOmega(frequency: frequency, sampleRate: sampleRate)
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * max(q, minimumQ))
        let a0 = 1 + alpha / amplitude
        return normalise(b0: 1 + alpha * amplitude, b1: -2 * cosW0, b2: 1 - alpha * amplitude,
                         a0: a0, a1: -2 * cosW0, a2: 1 - alpha / amplitude)
    }

    static func lowShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let amplitude = pow(10, gainDB / 40)
        let w0 = clampedOmega(frequency: frequency, sampleRate: sampleRate)
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * max(q, minimumQ))
        let sqrtA = amplitude.squareRoot()
        let aPlus = amplitude + 1
        let aMinus = amplitude - 1

        return normalise(
            b0: amplitude * (aPlus - aMinus * cosW0 + 2 * sqrtA * alpha),
            b1: 2 * amplitude * (aMinus - aPlus * cosW0),
            b2: amplitude * (aPlus - aMinus * cosW0 - 2 * sqrtA * alpha),
            a0: aPlus + aMinus * cosW0 + 2 * sqrtA * alpha,
            a1: -2 * (aMinus + aPlus * cosW0),
            a2: aPlus + aMinus * cosW0 - 2 * sqrtA * alpha
        )
    }

    static func highShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let amplitude = pow(10, gainDB / 40)
        let w0 = clampedOmega(frequency: frequency, sampleRate: sampleRate)
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * max(q, minimumQ))
        let sqrtA = amplitude.squareRoot()
        let aPlus = amplitude + 1
        let aMinus = amplitude - 1

        return normalise(
            b0: amplitude * (aPlus + aMinus * cosW0 + 2 * sqrtA * alpha),
            b1: -2 * amplitude * (aMinus + aPlus * cosW0),
            b2: amplitude * (aPlus + aMinus * cosW0 - 2 * sqrtA * alpha),
            a0: aPlus - aMinus * cosW0 + 2 * sqrtA * alpha,
            a1: 2 * (aMinus - aPlus * cosW0),
            a2: aPlus - aMinus * cosW0 - 2 * sqrtA * alpha
        )
    }

    /// Divides through by `a0` and refuses to emit anything the render thread could blow up on.
    private static func normalise(b0: Double, b1: Double, b2: Double,
                                  a0: Double, a1: Double, a2: Double) -> BiquadCoefficients {
        guard a0.isFinite, a0 != 0 else { return .identity }
        let coefficients = BiquadCoefficients(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                                              a1: Float(a1 / a0), a2: Float(a2 / a0))
        // An unstable or non-finite section would self-oscillate into the user's speakers at full
        // scale. Falling back to a pass-through is always the safer failure.
        guard coefficients.b0.isFinite, coefficients.b1.isFinite, coefficients.b2.isFinite,
              coefficients.a1.isFinite, coefficients.a2.isFinite, coefficients.isStable else {
            return .identity
        }
        return coefficients
    }
}
