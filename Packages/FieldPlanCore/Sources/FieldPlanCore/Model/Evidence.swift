import Foundation

// MARK: - Evidence behind an element (spec §8, §21, §28)
//
// Confidence here is an *evidence score*, not an accuracy claim. It says how
// well an element was observed: what the scanner thought of it, how much of
// it has mesh behind it, how good tracking was while it was seen. The
// accuracy framework (`AccuracyStatistics`) is what turns scores into
// measured error, by recording what each score actually delivered against a
// tape. Nothing here ever changes geometry.

/// Where a wall's thickness came from.
public enum ThicknessSource: String, Codable, CaseIterable, Sendable {
    /// A default (no second face was ever seen).
    case assumed
    /// Measured between two captured faces of the same wall.
    case measured
    /// Typed in the editor.
    case edited

    public var displayName: String {
        switch self {
        case .assumed: return "Assumed"
        case .measured: return "Measured"
        case .edited: return "Edited"
        }
    }
}

/// How a door operates. A scan sees only the hole and, at best, whether the
/// leaf was open, so anything other than hinged is set in the editor.
public enum DoorStyle: String, Codable, CaseIterable, Sendable {
    case hinged
    case doubleHinged
    case sliding
    case pocket
    case bifold
    case garage

    public var displayName: String {
        switch self {
        case .hinged: return "Hinged"
        case .doubleHinged: return "Double"
        case .sliding: return "Sliding"
        case .pocket: return "Pocket"
        case .bifold: return "Bi-fold"
        case .garage: return "Garage"
        }
    }

    /// Whether the plan draws a swing arc.
    public var hasSwing: Bool {
        switch self {
        case .hinged, .doubleHinged: return true
        default: return false
        }
    }
}

/// One factor that went into a confidence score.
public struct ConfidenceFactor: Codable, Hashable, Sendable {
    public var name: String
    /// The observed value (0…1 where meaningful).
    public var value: Double
    /// Multiplier the factor applied to the score.
    public var multiplier: Double

    public init(name: String, value: Double, multiplier: Double) {
        self.name = name
        self.value = value
        self.multiplier = multiplier
    }
}

/// A second, independent measurement of the same element (e.g. a line fitted
/// to the mesh next to a RoomPlan wall) kept for comparison — never used in
/// place of the primary value until validation shows it is better.
public struct AlternateMeasurement: Codable, Hashable, Sendable {
    public var method: String
    public var value: Double
    /// Residual RMS of the fit in meters, when the method has one.
    public var residual: Double?
    public var sampleCount: Int?

    public init(method: String, value: Double, residual: Double? = nil, sampleCount: Int? = nil) {
        self.method = method
        self.value = value
        self.residual = residual
        self.sampleCount = sampleCount
    }
}

public struct ElementEvidence: Codable, Hashable, Sendable {
    /// Combined evidence score, 0.05…0.99.
    public var confidence: Double
    public var factors: [ConfidenceFactor]
    public var scannerConfidence: CaptureConfidence?
    /// Fraction of the element with mesh evidence behind it.
    public var coverage: Double?
    /// Supporting observations (mesh faces near the element, samples…).
    public var observationCount: Int?
    /// Share of the session's poses under normal tracking while the element
    /// was being observed.
    public var trackingQuality: Double?
    public var bothSidesSeen: Bool?
    public var sessionID: UUID?
    public var alternate: AlternateMeasurement?
    public var notes: [String]

    public init(
        confidence: Double,
        factors: [ConfidenceFactor] = [],
        scannerConfidence: CaptureConfidence? = nil,
        coverage: Double? = nil,
        observationCount: Int? = nil,
        trackingQuality: Double? = nil,
        bothSidesSeen: Bool? = nil,
        sessionID: UUID? = nil,
        alternate: AlternateMeasurement? = nil,
        notes: [String] = []
    ) {
        self.confidence = confidence
        self.factors = factors
        self.scannerConfidence = scannerConfidence
        self.coverage = coverage
        self.observationCount = observationCount
        self.trackingQuality = trackingQuality
        self.bothSidesSeen = bothSidesSeen
        self.sessionID = sessionID
        self.alternate = alternate
        self.notes = notes
    }

    /// "92%" — display of the score.
    public var percentText: String { "\(ConfidenceModel.percent(confidence))%" }
    public var band: ConfidenceBand { ConfidenceModel.band(for: confidence) }
}

public enum ConfidenceBand: String, Codable, Sendable {
    case high, medium, low

    public var displayName: String { rawValue.capitalized }
}

/// The scoring rules. Deliberately simple and written down so a calibration
/// pass can change one number and see the effect.
public enum ConfidenceModel {
    public static let minimum = 0.05
    public static let maximum = 0.99
    public static let highBand = 0.85
    public static let mediumBand = 0.60

    public static func percent(_ confidence: Double) -> Int {
        Int((clamp(confidence) * 100).rounded())
    }

    public static func band(for confidence: Double) -> ConfidenceBand {
        if confidence >= highBand { return .high }
        if confidence >= mediumBand { return .medium }
        return .low
    }

    public static func clamp(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    /// Base score by the scanner's own bucket.
    public static func base(for scanner: CaptureConfidence?) -> Double {
        switch scanner {
        case .high: return 0.90
        case .medium: return 0.75
        case .low: return 0.55
        case nil: return 0.70
        }
    }

    /// Score for a wall, opening or fixture from the evidence available.
    /// Every factor that is unknown is simply skipped, so a plan with no
    /// session log still gets a score from the scanner bucket alone.
    public static func evidence(
        scanner: CaptureConfidence?,
        coverage: Double? = nil,
        observationCount: Int? = nil,
        trackingQuality: Double? = nil,
        bothSidesSeen: Bool? = nil,
        sessionID: UUID? = nil,
        alternate: AlternateMeasurement? = nil,
        notes: [String] = []
    ) -> ElementEvidence {
        var score = base(for: scanner)
        var factors = [ConfidenceFactor(name: "scanner", value: score, multiplier: 1)]

        if let coverage {
            let c = min(max(coverage, 0), 1)
            let multiplier = 0.60 + 0.40 * c
            score *= multiplier
            factors.append(ConfidenceFactor(name: "coverage", value: c, multiplier: multiplier))
        }
        if let observationCount {
            let multiplier = observationCount < 20 ? 0.85 : (observationCount < 60 ? 0.95 : 1.0)
            score *= multiplier
            factors.append(ConfidenceFactor(name: "observations", value: Double(observationCount), multiplier: multiplier))
        }
        if let trackingQuality {
            let t = min(max(trackingQuality, 0), 1)
            let multiplier = 0.70 + 0.30 * t
            score *= multiplier
            factors.append(ConfidenceFactor(name: "tracking", value: t, multiplier: multiplier))
        }
        if bothSidesSeen == true {
            score = min(score + 0.03, maximum)
            factors.append(ConfidenceFactor(name: "bothSides", value: 1, multiplier: 1.0))
        }
        if let alternate, let residual = alternate.residual {
            // A tight independent fit corroborates; a loose one casts doubt.
            let multiplier = residual < 0.01 ? 1.02 : (residual < 0.03 ? 1.0 : 0.92)
            score *= multiplier
            factors.append(ConfidenceFactor(name: "alternateFit", value: residual, multiplier: multiplier))
        }

        return ElementEvidence(
            confidence: clamp(score),
            factors: factors,
            scannerConfidence: scanner,
            coverage: coverage,
            observationCount: observationCount,
            trackingQuality: trackingQuality,
            bothSidesSeen: bothSidesSeen,
            sessionID: sessionID,
            alternate: alternate,
            notes: notes)
    }

    /// A room's score: the weakest of its walls matters most (one unseen wall
    /// makes the whole area suspect), tempered by floor coverage and closure.
    public static func roomEvidence(
        wallEvidence: [ElementEvidence],
        floorCoverage: Double?,
        isClosed: Bool,
        sessionID: UUID? = nil
    ) -> ElementEvidence {
        var factors: [ConfidenceFactor] = []
        var score: Double
        if wallEvidence.isEmpty {
            score = 0.60
            factors.append(ConfidenceFactor(name: "walls", value: 0, multiplier: 1))
        } else {
            let weakest = wallEvidence.map(\.confidence).min() ?? 0
            let mean = wallEvidence.map(\.confidence).reduce(0, +) / Double(wallEvidence.count)
            score = weakest * 0.6 + mean * 0.4
            factors.append(ConfidenceFactor(name: "weakestWall", value: weakest, multiplier: 0.6))
            factors.append(ConfidenceFactor(name: "meanWall", value: mean, multiplier: 0.4))
        }
        if let floorCoverage {
            let c = min(max(floorCoverage, 0), 1)
            let multiplier = 0.70 + 0.30 * c
            score *= multiplier
            factors.append(ConfidenceFactor(name: "floorCoverage", value: c, multiplier: multiplier))
        }
        if !isClosed {
            score *= 0.75
            factors.append(ConfidenceFactor(name: "closure", value: 0, multiplier: 0.75))
        }
        return ElementEvidence(
            confidence: clamp(score),
            factors: factors,
            coverage: floorCoverage,
            sessionID: sessionID)
    }
}

// MARK: - Attaching evidence to a level

public enum EvidenceAttachment {
    /// Scores every scanned element of a level against a coverage grid and a
    /// session's tracking record. Elements that already carry evidence from a
    /// hand edit are left alone.
    public static func attach(
        to level: LevelGeometry,
        grid: CoverageGrid?,
        trackingNormalFraction: Double?,
        sessionID: UUID?
    ) -> LevelGeometry {
        var result = level
        var wallScores: [UUID: ElementEvidence] = [:]

        for i in result.walls.indices {
            let wall = result.walls[i]
            guard wall.source == .lidarScanned else { continue }
            let coverage = grid?.wallCoverage(wall)
            let evidence = ConfidenceModel.evidence(
                scanner: wall.confidence,
                coverage: coverage?.fraction,
                observationCount: coverage.map { Int($0.meanHits * Double($0.coveredSamples)) },
                trackingQuality: trackingNormalFraction,
                bothSidesSeen: wall.thicknessSource == .measured ? true : nil,
                sessionID: sessionID)
            result.walls[i].evidence = evidence
            wallScores[wall.id] = evidence

            for j in result.walls[i].openings.indices {
                let opening = result.walls[i].openings[j]
                guard opening.source == .lidarScanned else { continue }
                let c = grid?.openingCoverage(on: wall, opening: opening)
                result.walls[i].openings[j].evidence = ConfidenceModel.evidence(
                    scanner: opening.confidence,
                    coverage: c,
                    trackingQuality: trackingNormalFraction,
                    sessionID: sessionID)
            }
        }

        for i in result.rooms.indices {
            let room = result.rooms[i]
            let walls = result.walls(for: room)
            let scores = walls.compactMap { wallScores[$0.id] }
            let closed = room.polygon.count >= 3 && !GeometryOps.polygonSelfIntersects(room.polygon)
            result.rooms[i].evidence = ConfidenceModel.roomEvidence(
                wallEvidence: scores,
                floorCoverage: grid?.floorCoverage(of: room.polygon),
                isClosed: closed,
                sessionID: sessionID)
        }

        for i in result.fixtures.indices {
            let fixture = result.fixtures[i]
            guard fixture.source == .lidarScanned else { continue }
            result.fixtures[i].evidence = ConfidenceModel.evidence(
                scanner: fixture.confidence,
                trackingQuality: trackingNormalFraction,
                sessionID: sessionID)
        }
        return result
    }
}
