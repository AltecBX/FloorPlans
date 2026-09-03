import Foundation

// MARK: - Field validation dataset (build 15)
//
// The purpose of a field visit is not a good-looking plan; it is a dataset
// that can later say which algorithm was closest to a laser. That only works
// if every competing measurement is kept side by side, unmodified, next to
// the ground truth — never averaged, never arbitrated, never quietly
// replaced. Nothing in this file changes geometry. It records what each
// method said and what the tape said, and reports the difference.

/// One method's answer for one element. Every field is optional because a
/// method may not have produced an answer for that element, and an absent
/// answer must never be confused with a wrong one.
public struct CompetingMeasurements: Codable, Hashable, Sendable {
    /// What the app currently shows — the canonical model's value.
    public var canonical: Double?
    /// RoomPlan's own value for the element, as captured.
    public var roomPlan: Double?
    /// The line fitted to the LiDAR mesh beside the element.
    public var meshFit: Double?
    /// Residual RMS of that fit, in meters.
    public var meshResidual: Double?
    /// Mesh points that supported the fit.
    public var meshInlierCount: Int?
    /// The value at capture, before any edit.
    public var originalScanned: Double?
    /// A value typed in the editor, when the element was corrected by hand.
    public var userEdited: Double?

    public init(
        canonical: Double? = nil,
        roomPlan: Double? = nil,
        meshFit: Double? = nil,
        meshResidual: Double? = nil,
        meshInlierCount: Int? = nil,
        originalScanned: Double? = nil,
        userEdited: Double? = nil
    ) {
        self.canonical = canonical
        self.roomPlan = roomPlan
        self.meshFit = meshFit
        self.meshResidual = meshResidual
        self.meshInlierCount = meshInlierCount
        self.originalScanned = originalScanned
        self.userEdited = userEdited
    }

    public func value(for source: MeasurementMethod) -> Double? {
        switch source {
        case .canonical: return canonical
        case .roomPlan: return roomPlan
        case .meshFit: return meshFit
        case .originalScanned: return originalScanned
        case .userEdited: return userEdited
        }
    }
}

/// The methods whose accuracy the field visit will compare.
public enum MeasurementMethod: String, Codable, CaseIterable, Sendable {
    case canonical
    case roomPlan
    case meshFit
    case originalScanned
    case userEdited

    public var displayName: String {
        switch self {
        case .canonical: return "FieldPlan (current)"
        case .roomPlan: return "RoomPlan"
        case .meshFit: return "LiDAR mesh fit"
        case .originalScanned: return "As scanned"
        case .userEdited: return "Hand edited"
        }
    }
}

/// How the trusted value was taken. Recorded because a laser to a finished
/// face and a tape at the baseboard are not the same measurement, and the
/// difference will show up in the statistics.
public enum GroundTruthMethod: String, Codable, CaseIterable, Sendable {
    case laser
    case tape
    case other

    public var displayName: String {
        switch self {
        case .laser: return "Laser Meter"
        case .tape: return "Tape Measure"
        case .other: return "Other"
        }
    }
}

/// Evidence the element carried at the moment the sample was taken, so a
/// later pass can ask whether confidence actually predicted accuracy.
public struct SampleEvidence: Codable, Hashable, Sendable {
    public var confidence: Double?
    public var coverage: Double?
    public var captureConfidence: CaptureConfidence?
    public var trackingQuality: Double?
    public var observationCount: Int?
    public var thicknessSource: ThicknessSource?

    public init(
        confidence: Double? = nil,
        coverage: Double? = nil,
        captureConfidence: CaptureConfidence? = nil,
        trackingQuality: Double? = nil,
        observationCount: Int? = nil,
        thicknessSource: ThicknessSource? = nil
    ) {
        self.confidence = confidence
        self.coverage = coverage
        self.captureConfidence = captureConfidence
        self.trackingQuality = trackingQuality
        self.observationCount = observationCount
        self.thicknessSource = thicknessSource
    }
}

/// One ground-truth observation: every method's answer for one element,
/// beside what the laser said.
public struct ValidationSample: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var validationSessionID: UUID
    /// The sensor session the element was captured in.
    public var scanSessionID: UUID?
    public var levelID: UUID?
    public var levelName: String
    public var roomID: UUID?
    public var roomName: String
    public var elementID: UUID?
    public var kind: AccuracyMeasureKind
    /// What was measured in words, e.g. "Kitchen north wall".
    public var elementLabel: String
    public var measurements: CompetingMeasurements
    /// The trusted value, meters or square meters.
    public var groundTruth: Double
    public var method: GroundTruthMethod
    public var note: String
    public var evidence: SampleEvidence
    /// Ties repeat scans of the same real wall together. A rescan makes new
    /// element IDs, so identity cannot be left to a UUID.
    public var physicalElementKey: String?
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        validationSessionID: UUID,
        scanSessionID: UUID? = nil,
        levelID: UUID? = nil,
        levelName: String = "",
        roomID: UUID? = nil,
        roomName: String = "",
        elementID: UUID? = nil,
        kind: AccuracyMeasureKind,
        elementLabel: String,
        measurements: CompetingMeasurements = CompetingMeasurements(),
        groundTruth: Double,
        method: GroundTruthMethod = .laser,
        note: String = "",
        evidence: SampleEvidence = SampleEvidence(),
        physicalElementKey: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.validationSessionID = validationSessionID
        self.scanSessionID = scanSessionID
        self.levelID = levelID
        self.levelName = levelName
        self.roomID = roomID
        self.roomName = roomName
        self.elementID = elementID
        self.kind = kind
        self.elementLabel = elementLabel
        self.measurements = measurements
        self.groundTruth = groundTruth
        self.method = method
        self.note = note
        self.evidence = evidence
        self.physicalElementKey = physicalElementKey
        self.recordedAt = recordedAt
    }

    /// Signed error of one method against the laser. Nil when that method
    /// had no answer for this element.
    public func error(for source: MeasurementMethod) -> Double? {
        measurements.value(for: source).map { $0 - groundTruth }
    }

    /// The same error as a share of the trusted value.
    public func percentError(for source: MeasurementMethod) -> Double? {
        guard abs(groundTruth) > 1e-9, let error = error(for: source) else { return nil }
        return error / groundTruth * 100
    }

    /// The sample in the older `AccuracySample` shape, so the existing
    /// statistics screen keeps working on build 15 data.
    public var legacySample: AccuracySample {
        AccuracySample(
            id: id,
            kind: kind,
            name: elementLabel,
            knownValue: groundTruth,
            measuredValue: measurements.canonical ?? groundTruth,
            alternateValue: measurements.meshFit,
            predictedConfidence: evidence.confidence,
            elementID: elementID,
            roomID: roomID,
            scanSessionID: scanSessionID,
            recordedAt: recordedAt,
            notes: note)
    }
}

/// One pass over a property. Repeat passes (A, B, C) of the same property
/// are separate sessions so scan-to-scan spread can be measured.
public struct ValidationSession: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var projectID: UUID
    /// "Property Scan A" and so on.
    public var name: String
    /// Conditions that may explain error: occupied, mirrors, dark hallway,
    /// direct sun, doors open, heavy clutter.
    public var notes: String
    public var appVersion: String
    public var buildNumber: String
    public var deviceModel: String
    public var systemVersion: String
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        name: String,
        notes: String = "",
        appVersion: String = "",
        buildNumber: String = "",
        deviceModel: String = "",
        systemVersion: String = "",
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.notes = notes
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

// MARK: - Problem markers

/// Something visibly wrong, flagged while standing in front of it. Far more
/// useful than trying to remember it in the car afterwards.
public enum ProblemKind: String, Codable, CaseIterable, Sendable {
    case wrongWall, missingWall, wrongCorner
    case missingDoor, wrongDoorWidth, missingWindow, wrongWindow
    case wrongRoomBoundary, wrongFixture, wrongRoomLabel
    case wrongFloor, floorAlignment, stairs, coverage, other

    public var displayName: String {
        switch self {
        case .wrongWall: return "Wrong wall"
        case .missingWall: return "Missing wall"
        case .wrongCorner: return "Wrong corner"
        case .missingDoor: return "Missing door"
        case .wrongDoorWidth: return "Wrong door width"
        case .missingWindow: return "Missing window"
        case .wrongWindow: return "Wrong window"
        case .wrongRoomBoundary: return "Wrong room boundary"
        case .wrongFixture: return "Wrong fixture"
        case .wrongRoomLabel: return "Wrong room label"
        case .wrongFloor: return "Wrong floor"
        case .floorAlignment: return "Floor alignment issue"
        case .stairs: return "Stair issue"
        case .coverage: return "Coverage issue"
        case .other: return "Other"
        }
    }
}

public struct ProblemMarker: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var validationSessionID: UUID?
    public var scanSessionID: UUID?
    public var levelID: UUID?
    public var roomID: UUID?
    public var elementID: UUID?
    public var kind: ProblemKind
    public var note: String
    /// Where on the plan, when the marker was dropped from the plan.
    public var planX: Double?
    public var planY: Double?
    /// Camera pose at the time, when flagged during a scan.
    public var cameraTransform: [Float]?
    public var photoFileName: String?
    public var screenshotFileName: String?
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        validationSessionID: UUID? = nil,
        scanSessionID: UUID? = nil,
        levelID: UUID? = nil,
        roomID: UUID? = nil,
        elementID: UUID? = nil,
        kind: ProblemKind,
        note: String = "",
        planX: Double? = nil,
        planY: Double? = nil,
        cameraTransform: [Float]? = nil,
        photoFileName: String? = nil,
        screenshotFileName: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.validationSessionID = validationSessionID
        self.scanSessionID = scanSessionID
        self.levelID = levelID
        self.roomID = roomID
        self.elementID = elementID
        self.kind = kind
        self.note = note
        self.planX = planX
        self.planY = planY
        self.cameraTransform = cameraTransform
        self.photoFileName = photoFileName
        self.screenshotFileName = screenshotFileName
        self.recordedAt = recordedAt
    }

    public var planPosition: Vec2? {
        guard let planX, let planY else { return nil }
        return Vec2(planX, planY)
    }
}
