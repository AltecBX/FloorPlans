import Foundation

// MARK: - Accuracy validation (spec §9, §28)
//
// The only place an accuracy figure may come from. A sample pairs what the
// app produced with what a tape or laser said about the same thing; the
// statistics summarise those pairs. Nothing is inferred from algorithms —
// no sample, no number.

public enum AccuracyMeasureKind: String, Codable, CaseIterable, Sendable {
    case wallLength
    case roomWidth
    case roomDepth
    case roomArea
    case doorWidth
    case windowWidth
    case openingHeight
    case ceilingHeight
    case wallThickness
    case totalFloorArea
    case floorToFloor
    case diagonal
    case custom

    public var displayName: String {
        switch self {
        case .wallLength: return "Wall Length"
        case .roomWidth: return "Room Width"
        case .roomDepth: return "Room Depth"
        case .roomArea: return "Room Area"
        case .doorWidth: return "Door Width"
        case .windowWidth: return "Window Width"
        case .openingHeight: return "Opening Height"
        case .ceilingHeight: return "Ceiling Height"
        case .wallThickness: return "Wall Thickness"
        case .totalFloorArea: return "Total Floor Area"
        case .floorToFloor: return "Floor-to-Floor Height"
        case .diagonal: return "Diagonal"
        case .custom: return "Custom"
        }
    }

    public var isArea: Bool { self == .roomArea || self == .totalFloorArea }
}

public struct AccuracySample: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AccuracyMeasureKind
    /// What was measured, e.g. "Kitchen north wall". Repeated scans of the
    /// same thing share a name so repeatability can be computed.
    public var name: String
    /// Trusted value (tape/laser), meters or square meters.
    public var knownValue: Double
    /// The app's value for the same element.
    public var measuredValue: Double
    /// A second method's value for the element (e.g. mesh line fit).
    public var alternateValue: Double?
    /// Evidence score the element carried when the sample was taken.
    public var predictedConfidence: Double?
    public var elementID: UUID?
    public var roomID: UUID?
    public var scanSessionID: UUID?
    public var recordedAt: Date
    public var notes: String

    public init(
        id: UUID = UUID(),
        kind: AccuracyMeasureKind,
        name: String,
        knownValue: Double,
        measuredValue: Double,
        alternateValue: Double? = nil,
        predictedConfidence: Double? = nil,
        elementID: UUID? = nil,
        roomID: UUID? = nil,
        scanSessionID: UUID? = nil,
        recordedAt: Date = Date(),
        notes: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.knownValue = knownValue
        self.measuredValue = measuredValue
        self.alternateValue = alternateValue
        self.predictedConfidence = predictedConfidence
        self.elementID = elementID
        self.roomID = roomID
        self.scanSessionID = scanSessionID
        self.recordedAt = recordedAt
        self.notes = notes
    }

    /// Signed: positive when the app reads long.
    public var error: Double { measuredValue - knownValue }
    public var absoluteError: Double { abs(error) }
    public var percentError: Double? {
        knownValue > 1e-9 ? absoluteError / knownValue * 100 : nil
    }
    public var alternateError: Double? { alternateValue.map { $0 - knownValue } }
}

public struct AccuracyStatistics: Codable, Hashable, Sendable {
    public var count: Int
    public var meanAbsoluteError: Double
    public var medianAbsoluteError: Double
    public var p95AbsoluteError: Double
    public var maxAbsoluteError: Double
    /// Bias: mean of the signed errors.
    public var meanSignedError: Double
    public var rmsError: Double
    public var meanPercentError: Double?
    public var medianPercentError: Double?
    public var p95PercentError: Double?
    public var maxPercentError: Double?
    /// Share of samples within the tolerance (lengths only for the inch
    /// figures; every sample for the percentage).
    public var withinHalfInch: Double?
    public var withinOneInch: Double?
    public var withinThreePercent: Double?

    /// Statistics over a set of samples, nil when empty. Callers normally
    /// group by kind first — an area error and a length error are different
    /// units.
    public static func compute(_ samples: [AccuracySample]) -> AccuracyStatistics? {
        guard !samples.isEmpty else { return nil }
        let signed = samples.map(\.error)
        let absolute = samples.map(\.absoluteError).sorted()
        let percents = samples.compactMap(\.percentError).sorted()
        let inch = UnitConstants.metersPerInch
        let lengths = samples.filter { !$0.kind.isArea }

        var stats = AccuracyStatistics(
            count: samples.count,
            meanAbsoluteError: absolute.reduce(0, +) / Double(absolute.count),
            medianAbsoluteError: percentile(absolute, 0.5),
            p95AbsoluteError: percentile(absolute, 0.95),
            maxAbsoluteError: absolute.last ?? 0,
            meanSignedError: signed.reduce(0, +) / Double(signed.count),
            rmsError: (signed.reduce(0) { $0 + $1 * $1 } / Double(signed.count)).squareRoot())
        if !percents.isEmpty {
            stats.meanPercentError = percents.reduce(0, +) / Double(percents.count)
            stats.medianPercentError = percentile(percents, 0.5)
            stats.p95PercentError = percentile(percents, 0.95)
            stats.maxPercentError = percents.last
            stats.withinThreePercent = Double(percents.filter { $0 <= 3.0 + tolerance }.count) / Double(percents.count)
        }
        if !lengths.isEmpty {
            stats.withinHalfInch = Double(lengths.filter { $0.absoluteError <= inch * 0.5 + tolerance }.count) / Double(lengths.count)
            stats.withinOneInch = Double(lengths.filter { $0.absoluteError <= inch + tolerance }.count) / Double(lengths.count)
        }
        return stats
    }

    /// Floating-point slack on the "within" tests so an error of exactly one
    /// inch counts as within one inch.
    static let tolerance = 1e-9

    public static func byKind(_ samples: [AccuracySample]) -> [AccuracyMeasureKind: AccuracyStatistics] {
        var result: [AccuracyMeasureKind: AccuracyStatistics] = [:]
        for kind in AccuracyMeasureKind.allCases {
            if let stats = compute(samples.filter { $0.kind == kind }) {
                result[kind] = stats
            }
        }
        return result
    }

    /// Linear-interpolated percentile of an ascending array, p in 0…1.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}

/// Spread of repeated measurements of the same thing across scans.
public struct RepeatabilityGroup: Codable, Hashable, Sendable {
    public var kind: AccuracyMeasureKind
    public var name: String
    public var count: Int
    public var mean: Double
    public var standardDeviation: Double
    public var range: Double
    public var knownValue: Double?
}

/// Observed error for samples whose predicted confidence fell in a bin.
public struct CalibrationBin: Codable, Hashable, Sendable {
    public var lower: Double
    public var upper: Double
    public var count: Int
    public var meanPredictedConfidence: Double
    public var meanAbsoluteError: Double
    public var withinOneInch: Double?
    public var withinThreePercent: Double?
}

public enum AccuracyAnalysis {

    /// Groups by (kind, name) and reports the spread where there are at
    /// least two samples.
    public static func repeatability(_ samples: [AccuracySample]) -> [RepeatabilityGroup] {
        var groups: [String: [AccuracySample]] = [:]
        for sample in samples {
            groups["\(sample.kind.rawValue)|\(sample.name.lowercased())", default: []].append(sample)
        }
        return groups.values
            .filter { $0.count >= 2 }
            .map { members in
                let values = members.map(\.measuredValue)
                let mean = values.reduce(0, +) / Double(values.count)
                let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
                return RepeatabilityGroup(
                    kind: members[0].kind,
                    name: members[0].name,
                    count: members.count,
                    mean: mean,
                    standardDeviation: variance.squareRoot(),
                    range: (values.max() ?? 0) - (values.min() ?? 0),
                    knownValue: members[0].knownValue)
            }
            .sorted { $0.name < $1.name }
    }

    /// Bins samples by predicted confidence and reports what each bin
    /// actually delivered. Default edges match the confidence bands.
    public static func calibration(
        _ samples: [AccuracySample],
        edges: [Double] = [0, ConfidenceModel.mediumBand, ConfidenceModel.highBand, 1.0]
    ) -> [CalibrationBin] {
        guard edges.count >= 2 else { return [] }
        let inch = UnitConstants.metersPerInch
        var bins: [CalibrationBin] = []
        for i in 0..<(edges.count - 1) {
            let lower = edges[i]
            let upper = edges[i + 1]
            let members = samples.filter { sample in
                guard let c = sample.predictedConfidence else { return false }
                let last = i == edges.count - 2
                return c >= lower && (last ? c <= upper : c < upper)
            }
            guard !members.isEmpty else { continue }
            let lengths = members.filter { !$0.kind.isArea }
            let percents = members.compactMap(\.percentError)
            bins.append(CalibrationBin(
                lower: lower,
                upper: upper,
                count: members.count,
                meanPredictedConfidence: members.compactMap(\.predictedConfidence).reduce(0, +) / Double(members.count),
                meanAbsoluteError: members.map(\.absoluteError).reduce(0, +) / Double(members.count),
                withinOneInch: lengths.isEmpty ? nil
                    : Double(lengths.filter { $0.absoluteError <= inch + AccuracyStatistics.tolerance }.count) / Double(lengths.count),
                withinThreePercent: percents.isEmpty ? nil
                    : Double(percents.filter { $0 <= 3 + AccuracyStatistics.tolerance }.count) / Double(percents.count)))
        }
        return bins
    }

    /// Primary-versus-alternate comparison over samples that carry both.
    public static func alternateComparison(_ samples: [AccuracySample]) -> (primary: AccuracyStatistics, alternate: AccuracyStatistics)? {
        let both = samples.filter { $0.alternateValue != nil }
        guard let primary = AccuracyStatistics.compute(both) else { return nil }
        let swapped = both.map { sample -> AccuracySample in
            var s = sample
            s.measuredValue = sample.alternateValue ?? sample.measuredValue
            return s
        }
        guard let alternate = AccuracyStatistics.compute(swapped) else { return nil }
        return (primary, alternate)
    }
}
