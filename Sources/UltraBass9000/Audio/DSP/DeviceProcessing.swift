import Foundation

enum BandKind: String, Codable, CaseIterable, Identifiable {
    case peaking, lowShelf, highShelf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }

    var symbolName: String {
        switch self {
        case .peaking: return "circle.circle"
        case .lowShelf: return "chevron.up.forward.square"
        case .highShelf: return "chevron.up.backward.square"
        }
    }
}

struct EQBand: Codable, Equatable, Identifiable {
    /// Stable slot index, not a position. Bands keep their identity when reordered on screen.
    var id: Int
    var kind: BandKind = .peaking
    var frequency: Double = 1_000
    var gainDB: Double = 0
    var q: Double = 0.707
    var isEnabled: Bool = true

    static let frequencyRange: ClosedRange<Double> = 20...20_000
    static let gainRange: ClosedRange<Double> = -24...24
    static let qRange: ClosedRange<Double> = 0.1...18

    var clamped: EQBand {
        var band = self
        band.frequency = min(max(frequency, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound)
        band.gainDB = min(max(gainDB, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        band.q = min(max(q, Self.qRange.lowerBound), Self.qRange.upperBound)
        return band
    }

    /// A band that is on but doing nothing still costs a biquad; shelves and peaks at 0 dB are
    /// mathematically transparent, so they are skipped when compiling.
    var isTransparent: Bool { !isEnabled || abs(gainDB) < 0.01 }
}

struct FilterSetting: Codable, Equatable {
    var isEnabled: Bool = false
    var frequency: Double
    var q: Double = 0.707

    static let qRange: ClosedRange<Double> = 0.1...8

    var clamped: FilterSetting {
        var setting = self
        setting.frequency = min(max(frequency, EQBand.frequencyRange.lowerBound),
                                EQBand.frequencyRange.upperBound)
        setting.q = min(max(q, Self.qRange.lowerBound), Self.qRange.upperBound)
        return setting
    }
}

/// Everything applied to one output device, in signal order: EQ bands, then high-pass, low-pass
/// and band-pass, then the fader.
struct DeviceProcessing: Codable, Equatable {
    var eqEnabled: Bool = true
    /// Always exactly `bandCount` entries, so a band's slot index is also its array index.
    var bands: [EQBand]
    var highPass: FilterSetting
    var lowPass: FilterSetting
    var bandPass: FilterSetting

    static let bandCount = 5

    /// Default centre frequencies spread across the audible range, roughly one per octave-and-a-bit.
    static let defaultFrequencies: [Double] = [60, 250, 1_000, 4_000, 12_000]

    static var neutral: DeviceProcessing {
        DeviceProcessing(
            eqEnabled: true,
            bands: (0..<bandCount).map { index in
                EQBand(id: index,
                       kind: index == 0 ? .lowShelf : (index == bandCount - 1 ? .highShelf : .peaking),
                       frequency: defaultFrequencies[index],
                       gainDB: 0,
                       q: 0.707,
                       isEnabled: true)
            },
            highPass: FilterSetting(isEnabled: false, frequency: 80),
            lowPass: FilterSetting(isEnabled: false, frequency: 12_000),
            bandPass: FilterSetting(isEnabled: false, frequency: 1_000, q: 1.0)
        )
    }

    var isNeutral: Bool {
        !highPass.isEnabled && !lowPass.isEnabled && !bandPass.isEnabled
            && (!eqEnabled || bands.allSatisfy(\.isTransparent))
    }

    var activeFilterNames: [String] {
        var names: [String] = []
        if highPass.isEnabled { names.append("HP") }
        if lowPass.isEnabled { names.append("LP") }
        if bandPass.isEnabled { names.append("BP") }
        return names
    }

    /// Repairs anything malformed — a short band array from an older preference file, a slot index
    /// that no longer matches its position, out-of-range values from a drag.
    var normalised: DeviceProcessing {
        var result = self
        var repaired = (0..<Self.bandCount).map { index -> EQBand in
            if let existing = bands.first(where: { $0.id == index }) { return existing.clamped }
            return DeviceProcessing.neutral.bands[index]
        }
        for index in repaired.indices { repaired[index].id = index }
        result.bands = repaired
        result.highPass = highPass.clamped
        result.lowPass = lowPass.clamped
        result.bandPass = bandPass.clamped
        return result
    }

    /// Flattens the settings into the biquad chain the render thread runs.
    ///
    /// Transparent sections are dropped rather than compiled to identity: a shorter chain is fewer
    /// multiply-accumulates per sample on every device, every buffer.
    func compile(sampleRate: Double) -> [BiquadCoefficients] {
        var sections: [BiquadCoefficients] = []
        sections.reserveCapacity(Self.bandCount + 3)

        if eqEnabled {
            for band in bands where !band.isTransparent {
                let clamped = band.clamped
                switch clamped.kind {
                case .peaking:
                    sections.append(BiquadDesign.peaking(frequency: clamped.frequency,
                                                         gainDB: clamped.gainDB,
                                                         q: clamped.q,
                                                         sampleRate: sampleRate))
                case .lowShelf:
                    sections.append(BiquadDesign.lowShelf(frequency: clamped.frequency,
                                                          gainDB: clamped.gainDB,
                                                          q: clamped.q,
                                                          sampleRate: sampleRate))
                case .highShelf:
                    sections.append(BiquadDesign.highShelf(frequency: clamped.frequency,
                                                           gainDB: clamped.gainDB,
                                                           q: clamped.q,
                                                           sampleRate: sampleRate))
                }
            }
        }

        if highPass.isEnabled {
            let setting = highPass.clamped
            sections.append(BiquadDesign.highPass(frequency: setting.frequency,
                                                  q: setting.q,
                                                  sampleRate: sampleRate))
        }
        if lowPass.isEnabled {
            let setting = lowPass.clamped
            sections.append(BiquadDesign.lowPass(frequency: setting.frequency,
                                                 q: setting.q,
                                                 sampleRate: sampleRate))
        }
        if bandPass.isEnabled {
            let setting = bandPass.clamped
            sections.append(BiquadDesign.bandPass(frequency: setting.frequency,
                                                  q: setting.q,
                                                  sampleRate: sampleRate))
        }

        return sections
    }

    /// Combined magnitude response in dB, for drawing the curve.
    func magnitudeResponse(at frequencies: [Double], sampleRate: Double) -> [Double] {
        let sections = compile(sampleRate: sampleRate)
        guard !sections.isEmpty else { return Array(repeating: 0, count: frequencies.count) }

        return frequencies.map { frequency in
            let omega = 2 * .pi * min(max(frequency, 1), sampleRate / 2 * 0.999) / sampleRate
            // Cascaded sections multiply in linear magnitude, which is the same as summing in dB.
            let linear = sections.reduce(1.0) { $0 * $1.magnitude(atAngularFrequency: omega) }
            guard linear > 1e-9 else { return -180 }
            return 20 * log10(linear)
        }
    }
}
