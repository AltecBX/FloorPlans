import Foundation

// MARK: - What the field data says (build 15)
//
// This is the payoff of a field visit: for each method, how far it landed
// from the laser, how repeatable it was, and whether the confidence score it
// carried actually predicted its error. It reports; it decides nothing. No
// method is preferred, averaged or promoted here — that choice waits until
// there is enough data to make it, which is the whole point of collecting it.

public enum ValidationAnalysis {

    // MARK: Per-method accuracy

    /// One method's error against the laser, over the samples where that
    /// method produced an answer.
    public struct SourceAccuracy: Codable, Hashable, Sendable {
        public var source: MeasurementMethod
        /// Samples where this method had an answer.
        public var sampleCount: Int
        /// Samples in the set where it did not — coverage matters as much as
        /// error, since a method that answers half the time is not better for
        /// being right when it does.
        public var missingCount: Int
        public var statistics: AccuracyStatistics
    }

    /// Every method's accuracy over the same samples, so they can be read
    /// side by side. Methods with no answers at all are omitted.
    public static func compareSources(
        _ samples: [ValidationSample],
        kind: AccuracyMeasureKind? = nil
    ) -> [SourceAccuracy] {
        let scoped = kind.map { k in samples.filter { $0.kind == k } } ?? samples
        guard !scoped.isEmpty else { return [] }
        var result: [SourceAccuracy] = []
        for source in MeasurementMethod.allCases {
            let projected = scoped.compactMap { sample -> AccuracySample? in
                guard let value = sample.measurements.value(for: source) else { return nil }
                var legacy = sample.legacySample
                legacy.measuredValue = value
                return legacy
            }
            guard let stats = AccuracyStatistics.compute(projected) else { continue }
            result.append(SourceAccuracy(
                source: source,
                sampleCount: projected.count,
                missingCount: scoped.count - projected.count,
                statistics: stats))
        }
        return result
    }

    /// The methods ordered by mean absolute error, closest first. Ordering is
    /// a reading of the data, not a decision: a method is only comparable to
    /// another where both answered, so `sampleCount` must be read with it.
    public static func rankedSources(_ samples: [ValidationSample]) -> [SourceAccuracy] {
        compareSources(samples).sorted { $0.statistics.meanAbsoluteError < $1.statistics.meanAbsoluteError }
    }

    /// Head-to-head over only the samples where both methods answered, which
    /// is the only fair comparison between two of them.
    public struct HeadToHead: Codable, Hashable, Sendable {
        public var a: MeasurementMethod
        public var b: MeasurementMethod
        public var pairCount: Int
        public var aCloserCount: Int
        public var bCloserCount: Int
        public var tiedCount: Int
        public var meanAbsoluteErrorA: Double
        public var meanAbsoluteErrorB: Double
    }

    public static func headToHead(
        _ samples: [ValidationSample],
        _ a: MeasurementMethod,
        _ b: MeasurementMethod,
        tolerance: Double = 1e-9
    ) -> HeadToHead? {
        var aErrors: [Double] = []
        var bErrors: [Double] = []
        var aCloser = 0, bCloser = 0, tied = 0
        for sample in samples {
            guard let ea = sample.error(for: a).map(abs),
                  let eb = sample.error(for: b).map(abs) else { continue }
            aErrors.append(ea)
            bErrors.append(eb)
            if abs(ea - eb) <= tolerance { tied += 1 }
            else if ea < eb { aCloser += 1 }
            else { bCloser += 1 }
        }
        guard !aErrors.isEmpty else { return nil }
        return HeadToHead(
            a: a, b: b,
            pairCount: aErrors.count,
            aCloserCount: aCloser,
            bCloserCount: bCloser,
            tiedCount: tied,
            meanAbsoluteErrorA: aErrors.reduce(0, +) / Double(aErrors.count),
            meanAbsoluteErrorB: bErrors.reduce(0, +) / Double(bErrors.count))
    }

    // MARK: Repeatability

    /// How much one method's answer for one real element moved between
    /// scans. Needs the samples to be linked by `physicalElementKey`: a
    /// rescan mints new element IDs, so identity cannot rest on a UUID.
    public struct RepeatabilitySpread: Codable, Hashable, Sendable {
        public var physicalElementKey: String
        public var kind: AccuracyMeasureKind
        public var source: MeasurementMethod
        public var scanCount: Int
        public var mean: Double
        /// Sample standard deviation; nil for a single scan.
        public var standardDeviation: Double?
        public var range: Double
        /// Mean signed error against the laser, when the samples carry one.
        public var bias: Double?
    }

    public static func repeatability(_ samples: [ValidationSample]) -> [RepeatabilitySpread] {
        struct Key: Hashable {
            var element: String
            var kind: AccuracyMeasureKind
            var source: MeasurementMethod
        }
        var buckets: [Key: [(value: Double, truth: Double)]] = [:]
        for sample in samples {
            guard let key = sample.physicalElementKey, !key.isEmpty else { continue }
            for source in MeasurementMethod.allCases {
                guard let value = sample.measurements.value(for: source) else { continue }
                buckets[Key(element: key, kind: sample.kind, source: source), default: []]
                    .append((value, sample.groundTruth))
            }
        }
        return buckets.map { key, entries in
            let values = entries.map(\.value)
            let mean = values.reduce(0, +) / Double(values.count)
            var deviation: Double? = nil
            if values.count > 1 {
                let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
                deviation = variance.squareRoot()
            }
            let errors = entries.map { $0.value - $0.truth }
            return RepeatabilitySpread(
                physicalElementKey: key.element,
                kind: key.kind,
                source: key.source,
                scanCount: values.count,
                mean: mean,
                standardDeviation: deviation,
                range: (values.max() ?? 0) - (values.min() ?? 0),
                bias: errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count))
        }
        .sorted {
            ($0.physicalElementKey, $0.kind.rawValue, $0.source.rawValue)
                < ($1.physicalElementKey, $1.kind.rawValue, $1.source.rawValue)
        }
    }

    // MARK: Does confidence predict error?

    /// Samples bucketed by the evidence score the element carried, with the
    /// error each bucket actually delivered. If the scores are meaningful the
    /// error falls as the score rises; if it does not, the score is decoration
    /// and the field data will say so.
    public struct CalibrationBucket: Codable, Hashable, Sendable {
        public var lowerBound: Double
        public var upperBound: Double
        public var sampleCount: Int
        public var meanAbsoluteError: Double
        public var meanPercentError: Double?
    }

    public static func confidenceCalibration(
        _ samples: [ValidationSample],
        source: MeasurementMethod = .canonical,
        bucketCount: Int = 5
    ) -> [CalibrationBucket] {
        guard bucketCount > 0 else { return [] }
        let width = 1.0 / Double(bucketCount)
        var buckets: [CalibrationBucket] = []
        for index in 0..<bucketCount {
            let lower = Double(index) * width
            let upper = lower + width
            let inBucket = samples.filter { sample in
                guard let confidence = sample.evidence.confidence,
                      sample.measurements.value(for: source) != nil else { return false }
                // The top bucket is closed so a score of exactly 1 lands in it.
                return confidence >= lower && (confidence < upper || (index == bucketCount - 1 && confidence <= upper))
            }
            guard !inBucket.isEmpty else { continue }
            let absolute = inBucket.compactMap { $0.error(for: source).map(abs) }
            let percents = inBucket.compactMap { $0.percentError(for: source).map(abs) }
            buckets.append(CalibrationBucket(
                lowerBound: lower,
                upperBound: upper,
                sampleCount: inBucket.count,
                meanAbsoluteError: absolute.reduce(0, +) / Double(absolute.count),
                meanPercentError: percents.isEmpty ? nil : percents.reduce(0, +) / Double(percents.count)))
        }
        return buckets
    }
}

// MARK: - Coverage of the test dataset

/// How much of the property has been physically checked. Not a target —
/// 100 % is never required — just a way to see at a glance what is left
/// while still standing in the building.
public struct ValidationProgress: Codable, Hashable, Sendable {
    public struct Line: Codable, Hashable, Sendable {
        public var kind: AccuracyMeasureKind
        public var tested: Int
        public var available: Int
        public var displayName: String { kind.displayName }
    }

    public var lines: [Line]
    /// Elements measured more than once, across scans of the same property.
    public var repeatedElementCount: Int
    public var totalSamples: Int
    public var problemMarkerCount: Int

    /// Counts what exists on the levels against what has been measured.
    /// `available` counts elements that could be checked, so it is a
    /// denominator for orientation, not a quota.
    public static func compute(
        levels: [LevelGeometry],
        samples: [ValidationSample],
        problemMarkers: [ProblemMarker] = []
    ) -> ValidationProgress {
        var available: [AccuracyMeasureKind: Int] = [:]
        for level in levels {
            available[.wallLength, default: 0] += level.walls.count
            available[.wallThickness, default: 0] += level.walls.filter { $0.thicknessSource != nil }.count
            for wall in level.walls {
                for opening in wall.openings {
                    switch opening.kind {
                    case .door:
                        available[.doorWidth, default: 0] += 1
                        available[.doorHeight, default: 0] += 1
                    case .window:
                        available[.windowWidth, default: 0] += 1
                        available[.windowHeight, default: 0] += 1
                        available[.windowSillHeight, default: 0] += 1
                    case .opening:
                        available[.openingHeight, default: 0] += 1
                    }
                }
            }
            available[.roomWidth, default: 0] += level.rooms.count
            available[.roomDepth, default: 0] += level.rooms.count
            available[.roomArea, default: 0] += level.rooms.count
            available[.ceilingHeight, default: 0] += level.rooms.filter { $0.ceilingHeight != nil }.count
            let stairs = level.fixtures.filter { $0.category == .stairs }.count
            if stairs > 0 {
                available[.stairWidth, default: 0] += stairs
                available[.stairTreadDepth, default: 0] += stairs
                available[.stairRiserHeight, default: 0] += stairs
            }
        }

        // Tested counts distinct elements, not samples: measuring one wall
        // three times is one wall checked.
        var tested: [AccuracyMeasureKind: Set<String>] = [:]
        for sample in samples {
            let identity = sample.elementID?.uuidString
                ?? sample.physicalElementKey
                ?? sample.elementLabel
            tested[sample.kind, default: []].insert(identity)
        }

        var repeated = 0
        var byPhysical: [String: Int] = [:]
        for sample in samples {
            guard let key = sample.physicalElementKey, !key.isEmpty else { continue }
            byPhysical["\(key)|\(sample.kind.rawValue)", default: 0] += 1
        }
        repeated = byPhysical.values.filter { $0 > 1 }.count

        let kinds = Set(available.keys).union(tested.keys)
        let lines = kinds.sorted { $0.rawValue < $1.rawValue }.map { kind in
            Line(kind: kind, tested: tested[kind]?.count ?? 0, available: available[kind] ?? 0)
        }
        return ValidationProgress(
            lines: lines.filter { $0.available > 0 || $0.tested > 0 },
            repeatedElementCount: repeated,
            totalSamples: samples.count,
            problemMarkerCount: problemMarkers.count)
    }

    /// Element IDs that already carry ground truth, for the plan overlay.
    public static func testedElementIDs(_ samples: [ValidationSample]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for sample in samples {
            guard let id = sample.elementID else { continue }
            counts[id, default: 0] += 1
        }
        return counts
    }
}
