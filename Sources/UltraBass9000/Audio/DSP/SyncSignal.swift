import Accelerate
import Foundation

/// Test-signal generation and arrival-time detection for acoustic device alignment.
///
/// The measurement plays a known signal out of one device, records it on the built-in microphone,
/// and finds where the recording best matches the signal. Doing that for every device gives their
/// relative arrival times, and the delays that align them.
enum SyncSignal {

    /// Band limits for the sweep.
    ///
    /// Wide enough to answer the question the measurement is usually being taken to answer: which
    /// device actually produces bass. An earlier, narrower 200 Hz to 8 kHz sweep was chosen purely
    /// for timing robustness, and it worked, but it meant the response curves simply stopped before
    /// the region where a laptop speaker and a subwoofer differ most. A device producing nothing at
    /// 50 Hz is a measurement; no data at 50 Hz is not.
    ///
    /// The bottom stops short of 30 Hz and the top short of Nyquist because neither end carries
    /// useful information: below that most speakers are inaudible and above it the microphone's own
    /// response dominates.
    static let lowFrequency: Double = 30
    static let highFrequency: Double = 16_000
    static let defaultDuration: Double = 0.4

    /// A logarithmic sine sweep, windowed so it starts and ends at silence.
    ///
    /// A sweep rather than a beep: a tone burst has a slow, ambiguous onset and its correlation peak
    /// is as wide as the tone is long. A sweep correlates to a sharp spike, which is what makes
    /// millisecond timing possible in a room with reflections and background noise.
    static func logarithmicSweep(duration: Double = defaultDuration,
                                 from startFrequency: Double = lowFrequency,
                                 to endFrequency: Double = highFrequency,
                                 sampleRate: Double) -> [Float] {
        let frameCount = Int(duration * sampleRate)
        guard frameCount > 1, sampleRate > 0, startFrequency > 0, endFrequency > startFrequency else {
            return []
        }

        let ratio = endFrequency / startFrequency
        let logRatio = log(ratio)
        // Instantaneous frequency rises exponentially; the phase is its integral.
        let scale = 2 * Double.pi * startFrequency * duration / logRatio

        var signal = [Float](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let t = Double(index) / Double(frameCount - 1)
            let phase = scale * (pow(ratio, t) - 1)
            signal[index] = Float(sin(phase))
        }

        applyFades(&signal, fadeFraction: 0.05)
        return signal
    }

    /// Raised-cosine fades at both ends, so playback does not begin or end with a step.
    static func applyFades(_ signal: inout [Float], fadeFraction: Double) {
        let count = signal.count
        guard count > 2 else { return }
        let fade = max(1, Int(Double(count) * fadeFraction))
        for index in 0..<fade {
            let window = Float(0.5 - 0.5 * cos(Double.pi * Double(index) / Double(fade)))
            signal[index] *= window
            signal[count - 1 - index] *= window
        }
    }

    /// Corner of the high-pass applied before correlating for arrival time.
    ///
    /// The played sweep starts at 30 Hz so the response measurement covers the bass, but low
    /// frequencies are exactly what a room smears: they arrive slowly, reflect strongly, and blunt
    /// the correlation peak that timing depends on. Widening the sweep for the response measurably
    /// degraded the timing one, so the two now look at different parts of the same recording.
    /// Timing uses only the part above this corner, where the transient is sharp.
    static let timingHighPassFrequency: Double = 250

    /// Band-limits a signal for arrival detection. Applied identically to the reference and the
    /// recording, so it shifts both by the same amount and cancels out of the difference.
    static func bandLimitedForTiming(_ samples: [Float], sampleRate: Double) -> [Float] {
        let chain = BiquadDesign.highPassCascade(frequency: timingHighPassFrequency,
                                                 order: 4,
                                                 sampleRate: sampleRate)
        var output = samples
        for coefficients in chain {
            var z1: Float = 0
            var z2: Float = 0
            for index in output.indices {
                let x = output[index]
                let y = coefficients.b0 * x + z1
                z1 = coefficients.b1 * x - coefficients.a1 * y + z2
                z2 = coefficients.b2 * x - coefficients.a2 * y
                output[index] = y
            }
        }
        return output
    }

    // MARK: - Arrival detection

    struct Detection: Equatable {
        /// Frames from the start of the recording to the start of the matched signal.
        let offsetFrames: Int
        /// Normalised correlation peak, 0...1. A clean measurement in a quiet room sits well above
        /// 0.3; ambient noise or a device that produced nothing sits near zero.
        let confidence: Float
    }

    /// Minimum normalised peak worth trusting.
    ///
    /// Chosen so an absent or inaudible device is rejected rather than reported at a random lag —
    /// a wrong delay is worse than no delay, because the user cannot tell it is wrong by looking.
    static let confidenceThreshold: Float = 0.12

    /// Finds where `reference` best matches inside `recording`.
    ///
    /// Uses `vDSP_conv`, whose kernel is `C[n] = Σ A[n+p]·F[p]` — cross-correlation as written, no
    /// reversal needed. It is O(N·P) but vectorised, and a one-off calibration of a few hundred
    /// milliseconds finishes in well under a second.
    static func findOffset(reference: [Float], in recording: [Float]) -> Detection? {
        let referenceCount = reference.count
        guard referenceCount > 0, recording.count >= referenceCount else { return nil }

        let lagCount = recording.count - referenceCount + 1
        guard lagCount > 0 else { return nil }

        var correlation = [Float](repeating: 0, count: lagCount)
        recording.withUnsafeBufferPointer { recordingPointer in
            reference.withUnsafeBufferPointer { referencePointer in
                vDSP_conv(recordingPointer.baseAddress!, 1,
                          referencePointer.baseAddress!, 1,
                          &correlation, 1,
                          vDSP_Length(lagCount), vDSP_Length(referenceCount))
            }
        }

        var peak: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(correlation, 1, &peak, &peakIndex, vDSP_Length(lagCount))
        guard peak > 0 else { return nil }

        // Normalise by the energy actually present in both signals at the winning lag, so the score
        // means "how well does this match" rather than "how loud was it".
        var referenceEnergy: Float = 0
        vDSP_svesq(reference, 1, &referenceEnergy, vDSP_Length(referenceCount))
        var segmentEnergy: Float = 0
        recording.withUnsafeBufferPointer { pointer in
            vDSP_svesq(pointer.baseAddress! + Int(peakIndex), 1, &segmentEnergy,
                       vDSP_Length(referenceCount))
        }

        let denominator = (referenceEnergy * segmentEnergy).squareRoot()
        guard denominator > 0 else { return nil }
        let confidence = min(1, peak / denominator)

        return Detection(offsetFrames: Int(peakIndex), confidence: confidence)
    }

    // MARK: - Turning arrivals into delays

    /// Converts per-device relative latencies into the delays that align them.
    ///
    /// The input is deliberately *relative*, not absolute. Each value is
    /// `(when the sweep was heard) − (when the sweep was scheduled to play)`, which equals the
    /// device's true latency plus one constant: microphone latency, ADC buffering, the offset
    /// between starting the recorder and starting playback, and any bias in the correlation. That
    /// constant is identical for every device because they are all measured in a single continuous
    /// recording, so it vanishes the moment differences are taken.
    ///
    /// That is what makes acoustic alignment possible without calibrating anything, and why the
    /// measurement must be one unbroken pass rather than a start/stop per device.
    ///
    /// Every device is held back to match the slowest, because the alternative — advancing the
    /// others — would require knowing the future.
    static func alignmentDelays(relativeLatencies: [Double]) -> [Double] {
        guard let slowest = relativeLatencies.max() else { return [] }
        return relativeLatencies.map { max(0, slowest - $0) }
    }

    /// Combines a capture-rate detection and a playback-rate schedule into one relative latency.
    ///
    /// Playback and capture do not share a sample rate — the built-in microphone may sit at
    /// 44.1 kHz while the output aggregate runs at 48 kHz — so frame counts from the two sides are
    /// not comparable. Converting both to seconds first is the only way to subtract them, and is
    /// also why the correlation reference has to be generated at the *capture* rate while the
    /// played signal is generated at the *playback* rate.
    static func relativeLatencySeconds(arrivalFrames: Int,
                                       captureSampleRate: Double,
                                       scheduledPlaybackFrames: Int,
                                       playbackSampleRate: Double) -> Double? {
        guard captureSampleRate > 0, playbackSampleRate > 0 else { return nil }
        return Double(arrivalFrames) / captureSampleRate
            - Double(scheduledPlaybackFrames) / playbackSampleRate
    }
}
