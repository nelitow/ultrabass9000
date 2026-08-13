import Accelerate
import Foundation

/// One point on a measured frequency response.
struct ResponsePoint: Equatable, Identifiable, Codable {
    let frequency: Double
    let decibels: Double

    var id: Double { frequency }
}

/// Measures what a device and the room between it and the microphone did to a known sweep.
///
/// The comparison is what carries the information. Dividing the recorded spectrum by the spectrum
/// of the signal that was played cancels the sweep's own shape, leaving only what the speaker, the
/// room and the microphone contributed.
///
/// **Read these curves as relative, never absolute.** The built-in microphone is not a measurement
/// microphone: it has its own response, and macOS may be processing it. What survives that is
/// comparison — the same microphone in the same position measures every device, so "this one has
/// output below 80 Hz and that one does not" is trustworthy even though neither absolute curve is.
/// Below roughly 300 Hz a single microphone position measures the room at least as much as the
/// speaker.
enum ResponseAnalyzer {

    /// Resolution of the reported curve.
    ///
    /// Twelfth-octave, which is fine enough to show the shape of a crossover rather than just its
    /// existence. It is also fine enough to show the comb filtering that any single microphone
    /// position produces, which is why the measurement is averaged over several passes before it
    /// reaches this resolution: without that, the extra detail would mostly be extra noise.
    static let bandsPerOctave = 12
    static let lowestFrequency: Double = 40
    static let highestFrequency: Double = 12_000

    /// A band whose excitation is this far below the sweep's peak is not reported at all. Dividing
    /// by a frequency the sweep never contained produces a large, confident, meaningless number.
    static let excitationFloorDB: Double = -40

    /// Magnitude response of the path the recording travelled, relative to the reference.
    ///
    /// - Parameters:
    ///   - recorded: the captured sweep, already aligned to its arrival.
    ///   - reference: the sweep that was played, at the *capture* sample rate.
    static func response(recorded: [Float],
                         reference: [Float],
                         sampleRate: Double) -> [ResponsePoint] {
        guard sampleRate > 0, !recorded.isEmpty, !reference.isEmpty else { return [] }

        let length = max(recorded.count, reference.count)
        let n = nextPowerOfTwo(max(length, 1024))
        guard let recordedSpectrum = powerSpectrum(recorded, length: n),
              let referenceSpectrum = powerSpectrum(reference, length: n) else { return [] }

        let peakExcitation = Double(referenceSpectrum.max() ?? 0)
        guard peakExcitation > 0 else { return [] }
        let excitationFloor = peakExcitation * pow(10, excitationFloorDB / 10)

        let binWidth = sampleRate / Double(n)
        let nyquistBin = n / 2

        var points: [ResponsePoint] = []
        let step = pow(2.0, 1.0 / Double(bandsPerOctave))
        let halfBand = pow(2.0, 1.0 / Double(2 * bandsPerOctave))

        var centre = lowestFrequency
        while centre <= highestFrequency {
            let lower = centre / halfBand
            let upper = centre * halfBand
            let firstBin = max(1, Int((lower / binWidth).rounded(.down)))
            let lastBin = min(nyquistBin - 1, Int((upper / binWidth).rounded(.up)))

            if firstBin <= lastBin {
                var recordedPower = 0.0
                var referencePower = 0.0
                for bin in firstBin...lastBin {
                    recordedPower += Double(recordedSpectrum[bin])
                    referencePower += Double(referenceSpectrum[bin])
                }
                // Only report bands the sweep actually excited.
                if referencePower > excitationFloor, recordedPower > 0 {
                    points.append(ResponsePoint(frequency: centre,
                                                decibels: 10 * log10(recordedPower / referencePower)))
                }
            }
            centre *= step
        }

        return normalised(points)
    }

    /// Shifts the curve so its median sits at 0 dB.
    ///
    /// Absolute level says nothing useful here — it is a function of how loud the device was turned
    /// up and how far away it is, not of how it sounds. Removing it is what makes two devices'
    /// curves comparable on one plot, which is the entire point.
    static func normalised(_ points: [ResponsePoint]) -> [ResponsePoint] {
        guard !points.isEmpty else { return [] }
        let sorted = points.map(\.decibels).sorted()
        let median = sorted[sorted.count / 2]
        return points.map { ResponsePoint(frequency: $0.frequency, decibels: $0.decibels - median) }
    }

    // MARK: - Spectrum

    /// Power per bin, zero-padded to `length`.
    ///
    /// A Hann window keeps the ends of the capture from leaking broadband energy across the whole
    /// spectrum, which would flatten every curve toward the same shape.
    private static func powerSpectrum(_ samples: [Float], length: Int) -> [Float]? {
        guard length > 0, let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), .FORWARD)
        else { return nil }
        defer { vDSP_DFT_DestroySetup(setup) }

        var real = [Float](repeating: 0, count: length)
        var imaginary = [Float](repeating: 0, count: length)
        let count = min(samples.count, length)
        for index in 0..<count {
            let window = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(max(count - 1, 1))))
            real[index] = samples[index] * window
        }

        var outputReal = [Float](repeating: 0, count: length)
        var outputImaginary = [Float](repeating: 0, count: length)
        vDSP_DFT_Execute(setup, real, imaginary, &outputReal, &outputImaginary)

        var power = [Float](repeating: 0, count: length)
        for bin in 0..<length {
            power[bin] = outputReal[bin] * outputReal[bin] + outputImaginary[bin] * outputImaginary[bin]
        }
        return power
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result <<= 1 }
        return result
    }
}
