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

/// Steepness of a high-pass or low-pass, in decibels per octave.
///
/// Expressed as slope rather than Q because that is the number a crossover is actually specified
/// by: "the sub takes everything below 120 Hz at 24 dB/oct" is a sentence someone can act on, where
/// "Q = 1.31 on section two of a fourth-order cascade" is the same filter described uselessly.
enum FilterSlope: Int, Codable, CaseIterable, Identifiable {
    case db6 = 6
    case db12 = 12
    case db24 = 24
    case db36 = 36
    case db48 = 48

    var id: Int { rawValue }

    /// Filter order. Every 6 dB/oct is one order.
    var order: Int { rawValue / 6 }

    /// Biquads needed. A first-order section still occupies one.
    var sectionCount: Int { (order + 1) / 2 }

    var displayName: String { "\(rawValue) dB/oct" }
}

/// A single-sided filter: everything above a corner, or everything below it.
struct FilterSetting: Codable, Equatable {
    var isEnabled: Bool = false
    var frequency: Double
    var slope: FilterSlope = .db12

    var clamped: FilterSetting {
        var setting = self
        setting.frequency = min(max(frequency, EQBand.frequencyRange.lowerBound),
                                EQBand.frequencyRange.upperBound)
        return setting
    }

    // Migration: older builds stored a `q` and had no `slope`. Decoding with defaults keeps a
    // user's saved setup working across the upgrade instead of silently discarding all of it.
    private enum CodingKeys: String, CodingKey { case isEnabled, frequency, slope }

    init(isEnabled: Bool = false, frequency: Double, slope: FilterSlope = .db12) {
        self.isEnabled = isEnabled
        self.frequency = frequency
        self.slope = slope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        frequency = try container.decodeIfPresent(Double.self, forKey: .frequency) ?? 1_000
        slope = try container.decodeIfPresent(FilterSlope.self, forKey: .slope) ?? .db12
    }
}

/// A band of frequencies to keep, expressed the way a crossover is: a lower edge, an upper edge,
/// and how steeply it falls away outside them.
///
/// Modelled as a high-pass and a low-pass in series rather than a single resonant biquad. One
/// biquad can only give a fixed 6 dB/oct skirt whose width is set indirectly by Q, which cannot
/// express "keep 80 Hz to 2 kHz and drop everything else at 24 dB/oct".
struct BandPassSetting: Codable, Equatable {
    var isEnabled: Bool = false
    /// Lower edge — the high-pass corner.
    var lowFrequency: Double = 200
    /// Upper edge — the low-pass corner.
    var highFrequency: Double = 4_000
    var slope: FilterSlope = .db12

    /// Keeps the edges the right way round and at least a little apart.
    ///
    /// A band whose edges cross over would silently become a notch — filters do not care that the
    /// user meant a band — so the pair is ordered and separated here instead.
    var clamped: BandPassSetting {
        var setting = self
        let low = min(max(lowFrequency, EQBand.frequencyRange.lowerBound),
                      EQBand.frequencyRange.upperBound)
        let high = min(max(highFrequency, EQBand.frequencyRange.lowerBound),
                       EQBand.frequencyRange.upperBound)
        setting.lowFrequency = min(low, high)
        setting.highFrequency = max(low, high)
        // Never narrower than a quarter octave, so the band always passes something.
        let minimumRatio = pow(2.0, 0.25)
        if setting.highFrequency < setting.lowFrequency * minimumRatio {
            setting.highFrequency = min(setting.lowFrequency * minimumRatio,
                                        EQBand.frequencyRange.upperBound)
        }
        return setting
    }

    var widthInOctaves: Double {
        let setting = clamped
        guard setting.lowFrequency > 0 else { return 0 }
        return log2(setting.highFrequency / setting.lowFrequency)
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, lowFrequency, highFrequency, slope, frequency, q }

    init(isEnabled: Bool = false,
         lowFrequency: Double = 200,
         highFrequency: Double = 4_000,
         slope: FilterSlope = .db12) {
        self.isEnabled = isEnabled
        self.lowFrequency = lowFrequency
        self.highFrequency = highFrequency
        self.slope = slope
    }

    /// Migrates the old centre-frequency-and-Q representation by converting it to the equivalent
    /// pair of edges, so an existing band-pass keeps roughly the sound it had.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        slope = try container.decodeIfPresent(FilterSlope.self, forKey: .slope) ?? .db12

        if let low = try container.decodeIfPresent(Double.self, forKey: .lowFrequency),
           let high = try container.decodeIfPresent(Double.self, forKey: .highFrequency) {
            lowFrequency = low
            highFrequency = high
        } else {
            let centre = try container.decodeIfPresent(Double.self, forKey: .frequency) ?? 1_000
            let q = try container.decodeIfPresent(Double.self, forKey: .q) ?? 1
            // Bandwidth in octaves for a resonant band-pass of a given Q.
            let bandwidth = max(0.25, 1 / max(q, 0.1))
            lowFrequency = centre / pow(2, bandwidth / 2)
            highFrequency = centre * pow(2, bandwidth / 2)
        }
    }

    /// Written explicitly because `CodingKeys` carries the legacy `frequency`/`q` keys for reading,
    /// and those have no corresponding property to synthesise an encoder from.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(lowFrequency, forKey: .lowFrequency)
        try container.encode(highFrequency, forKey: .highFrequency)
        try container.encode(slope, forKey: .slope)
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
    var bandPass: BandPassSetting

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
            bandPass: BandPassSetting(isEnabled: false, lowFrequency: 200, highFrequency: 4_000)
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
            sections.append(contentsOf: BiquadDesign.highPassCascade(frequency: setting.frequency,
                                                                     order: setting.slope.order,
                                                                     sampleRate: sampleRate))
        }
        if lowPass.isEnabled {
            let setting = lowPass.clamped
            sections.append(contentsOf: BiquadDesign.lowPassCascade(frequency: setting.frequency,
                                                                    order: setting.slope.order,
                                                                    sampleRate: sampleRate))
        }
        if bandPass.isEnabled {
            // A band is a high-pass at its lower edge followed by a low-pass at its upper edge.
            let setting = bandPass.clamped
            sections.append(contentsOf: BiquadDesign.highPassCascade(frequency: setting.lowFrequency,
                                                                     order: setting.slope.order,
                                                                     sampleRate: sampleRate))
            sections.append(contentsOf: BiquadDesign.lowPassCascade(frequency: setting.highFrequency,
                                                                    order: setting.slope.order,
                                                                    sampleRate: sampleRate))
        }

        return sections
    }

    /// Biquads this configuration needs. Compared against `FilterBank.maxSections` by the tests, so
    /// a new filter type cannot quietly overflow the render thread's fixed-size chain.
    var sectionCount: Int {
        var count = eqEnabled ? bands.filter { !$0.isTransparent }.count : 0
        if highPass.isEnabled { count += highPass.slope.sectionCount }
        if lowPass.isEnabled { count += lowPass.slope.sectionCount }
        if bandPass.isEnabled { count += bandPass.slope.sectionCount * 2 }
        return count
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
