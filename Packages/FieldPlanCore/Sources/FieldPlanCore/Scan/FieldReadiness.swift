import Foundation

// MARK: - Not losing a scan (build 15)
//
// A property walk is expensive: an hour on site, and a phone call or an iOS
// memory kill can end it. Everything here exists so that the moment a room is
// accepted it is already safe on disk, so an interrupted walk can be picked
// up rather than restarted, and so nothing fails silently while there is
// still time to fix it standing in the building.

// MARK: Room checkpoints

/// A room that has been accepted and written to disk. Written the instant
/// Accept is tapped, before any reconstruction — if iOS terminates the app a
/// second later, this is what proves the room was captured.
///
/// The identifier is RoomPlan's own `CapturedRoom.identifier`, which makes
/// the record idempotent: processing the same checkpoint twice cannot create
/// the room twice.
public struct RoomCheckpoint: Codable, Hashable, Identifiable, Sendable {
    /// `CapturedRoom.identifier` — the idempotency key.
    public var id: UUID
    public var projectID: UUID
    public var levelID: UUID?
    public var scanSessionID: UUID?
    public var roomName: String
    /// RoomPlan's own suggestion, kept raw so typing can be redone later.
    public var suggestedType: String?
    public var capturedAt: Date
    /// Relative to the project's `scans/` directory.
    public var rawDataFileName: String?
    public var usdzFileName: String?
    /// The world map checkpoint current when this room was accepted.
    public var worldMapCheckpointID: UUID?
    /// Camera pose at acceptance, for returning to the spot.
    public var cameraTransform: [Float]?
    /// Coverage as it stood, so a thin scan is visible without reprocessing.
    public var floorCoverage: Double?
    public var wallCoverage: Double?
    public var meshChunkCount: Int?
    /// Set once the room has been folded into a canonical snapshot. A
    /// checkpoint with this set is history; without it, it is outstanding
    /// work the app still owes the owner.
    public var mergedIntoSnapshotID: UUID?
    public var mergedAt: Date?

    public init(
        id: UUID,
        projectID: UUID,
        levelID: UUID? = nil,
        scanSessionID: UUID? = nil,
        roomName: String,
        suggestedType: String? = nil,
        capturedAt: Date = Date(),
        rawDataFileName: String? = nil,
        usdzFileName: String? = nil,
        worldMapCheckpointID: UUID? = nil,
        cameraTransform: [Float]? = nil,
        floorCoverage: Double? = nil,
        wallCoverage: Double? = nil,
        meshChunkCount: Int? = nil,
        mergedIntoSnapshotID: UUID? = nil,
        mergedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.levelID = levelID
        self.scanSessionID = scanSessionID
        self.roomName = roomName
        self.suggestedType = suggestedType
        self.capturedAt = capturedAt
        self.rawDataFileName = rawDataFileName
        self.usdzFileName = usdzFileName
        self.worldMapCheckpointID = worldMapCheckpointID
        self.cameraTransform = cameraTransform
        self.floorCoverage = floorCoverage
        self.wallCoverage = wallCoverage
        self.meshChunkCount = meshChunkCount
        self.mergedIntoSnapshotID = mergedIntoSnapshotID
        self.mergedAt = mergedAt
    }

    public var isMerged: Bool { mergedIntoSnapshotID != nil }
}

/// What an interrupted walk left behind.
public struct UnfinishedScan: Codable, Hashable, Identifiable, Sendable {
    /// One unfinished walk per project, so the project identifies it.
    public var id: UUID { projectID }
    public var projectID: UUID
    public var checkpoints: [RoomCheckpoint]
    public var lastRoomName: String?
    public var lastCapturedAt: Date?
    public var levelIDs: [UUID]
    public var worldMapAvailable: Bool

    public var roomCount: Int { checkpoints.count }
}

public enum CheckpointStore {

    /// Folds new checkpoints into the known set, keyed by room identifier.
    /// Re-accepting or reprocessing the same room replaces its record rather
    /// than adding a second one, which is what keeps Finish Level from
    /// duplicating rooms it has already seen.
    public static func merge(_ existing: [RoomCheckpoint], with incoming: [RoomCheckpoint]) -> [RoomCheckpoint] {
        var byID: [UUID: RoomCheckpoint] = [:]
        for checkpoint in existing { byID[checkpoint.id] = checkpoint }
        for checkpoint in incoming {
            if let current = byID[checkpoint.id] {
                // A later capture wins, but a merge already recorded is never
                // lost — otherwise a replay would re-import a merged room.
                var winner = checkpoint.capturedAt >= current.capturedAt ? checkpoint : current
                if winner.mergedIntoSnapshotID == nil, let merged = current.mergedIntoSnapshotID {
                    winner.mergedIntoSnapshotID = merged
                    winner.mergedAt = current.mergedAt
                }
                byID[checkpoint.id] = winner
            } else {
                byID[checkpoint.id] = checkpoint
            }
        }
        return byID.values.sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Checkpoints still owed a place in the canonical model.
    public static func outstanding(_ checkpoints: [RoomCheckpoint]) -> [RoomCheckpoint] {
        checkpoints.filter { !$0.isMerged }
    }

    /// Marks checkpoints as folded into a snapshot. Idempotent: a checkpoint
    /// already merged keeps its original stamp.
    public static func markMerged(
        _ checkpoints: [RoomCheckpoint],
        ids: Set<UUID>,
        snapshotID: UUID,
        at date: Date = Date()
    ) -> [RoomCheckpoint] {
        checkpoints.map { checkpoint in
            guard ids.contains(checkpoint.id), checkpoint.mergedIntoSnapshotID == nil else { return checkpoint }
            var updated = checkpoint
            updated.mergedIntoSnapshotID = snapshotID
            updated.mergedAt = date
            return updated
        }
    }

    /// Describes what is outstanding, for the recovery prompt. Nil when the
    /// project has nothing unfinished.
    public static func unfinished(
        projectID: UUID,
        checkpoints: [RoomCheckpoint],
        worldMapAvailable: Bool = false
    ) -> UnfinishedScan? {
        let pending = outstanding(checkpoints)
        guard !pending.isEmpty else { return nil }
        let last = pending.max { $0.capturedAt < $1.capturedAt }
        return UnfinishedScan(
            projectID: projectID,
            checkpoints: pending,
            lastRoomName: last?.roomName,
            lastCapturedAt: last?.capturedAt,
            levelIDs: Array(Set(pending.compactMap(\.levelID))),
            worldMapAvailable: worldMapAvailable)
    }
}

// MARK: World map checkpoints

/// A saved `ARWorldMap` and what was true when it was saved. Restoring one
/// is how a walk resumes in the same coordinate space instead of starting a
/// second, unrelated one.
public struct WorldMapCheckpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var scanSessionID: UUID?
    public var levelID: UUID?
    /// Relative to the session's `worldmaps/` directory.
    public var fileName: String
    public var savedAt: Date
    public var mappingStatus: WorldMappingQuality
    public var trackingState: TrackingQuality
    /// Camera pose when saved, so the owner can be sent back to the spot.
    public var cameraTransform: [Float]?
    /// A photo of roughly what the camera saw, shown during relocalization.
    public var referenceKeyframeFileName: String?
    public var lastAcceptedRoomID: UUID?
    public var acceptedRoomCount: Int
    /// Transform of the anchor planted before saving. After a restore, the
    /// same anchor coming back with the same transform is what proves the
    /// coordinate system survived rather than being silently replaced.
    public var originAnchorTransform: [Float]?
    public var originAnchorName: String

    public init(
        id: UUID = UUID(),
        scanSessionID: UUID? = nil,
        levelID: UUID? = nil,
        fileName: String,
        savedAt: Date = Date(),
        mappingStatus: WorldMappingQuality,
        trackingState: TrackingQuality = .normal,
        cameraTransform: [Float]? = nil,
        referenceKeyframeFileName: String? = nil,
        lastAcceptedRoomID: UUID? = nil,
        acceptedRoomCount: Int = 0,
        originAnchorTransform: [Float]? = nil,
        originAnchorName: String = WorldMapPolicy.originAnchorName
    ) {
        self.id = id
        self.scanSessionID = scanSessionID
        self.levelID = levelID
        self.fileName = fileName
        self.savedAt = savedAt
        self.mappingStatus = mappingStatus
        self.trackingState = trackingState
        self.cameraTransform = cameraTransform
        self.referenceKeyframeFileName = referenceKeyframeFileName
        self.lastAcceptedRoomID = lastAcceptedRoomID
        self.acceptedRoomCount = acceptedRoomCount
        self.originAnchorTransform = originAnchorTransform
        self.originAnchorName = originAnchorName
    }
}

public enum WorldMapPolicy {
    /// Name of the anchor planted so a restore can be verified.
    public static let originAnchorName = "FieldPlanOrigin"
    /// Only these mapping states are worth saving; a limited map relocalizes
    /// badly and would be worse than the one already held.
    public static let saveableStates: Set<WorldMappingQuality> = [.mapped, .extending]
    /// How much better a map has to be before the good one is replaced.
    public static func rank(_ status: WorldMappingQuality) -> Int {
        switch status {
        case .mapped: return 3
        case .extending: return 2
        case .limited: return 1
        case .notAvailable: return 0
        }
    }

    public static func isWorthSaving(_ status: WorldMappingQuality) -> Bool {
        saveableStates.contains(status)
    }

    /// Whether a new map should replace the one on hand. A fully mapped
    /// checkpoint is never overwritten by a weaker one — losing the last
    /// good map to a worse one is exactly how a resume becomes impossible.
    /// An equally good map replaces it, since it is more recent and closer
    /// to where the owner now stands.
    public static func shouldReplace(_ existing: WorldMapCheckpoint?, with status: WorldMappingQuality) -> Bool {
        guard isWorthSaving(status) else { return false }
        guard let existing else { return true }
        return rank(status) >= rank(existing.mappingStatus)
    }

    /// Whether a restored session is in the same coordinate space: the origin
    /// anchor came back and did not move. Compared loosely — relocalization
    /// is never bit-exact — but a metre of drift means the rooms would not
    /// line up and the scan must not be merged.
    public static func coordinatesCompatible(
        saved: [Float]?,
        restored: [Float]?,
        toleranceMeters: Double = 0.10
    ) -> Bool {
        guard let saved, let restored, saved.count == 16, restored.count == 16 else { return false }
        // Column-major 4×4: the translation is elements 12, 13, 14.
        let dx = Double(saved[12] - restored[12])
        let dy = Double(saved[13] - restored[13])
        let dz = Double(saved[14] - restored[14])
        return (dx * dx + dy * dy + dz * dz).squareRoot() <= toleranceMeters
    }
}

/// Where a resume attempt stands, so the screen can say one honest thing.
public enum RelocalizationState: String, Codable, Sendable {
    case idle
    case loadingMap
    case relocalizing
    case succeeded
    case failed

    public var message: String {
        switch self {
        case .idle: return ""
        case .loadingMap: return "Loading the last saved map…"
        case .relocalizing: return "Relocalizing… return to the last scanned area and slowly point the phone around the room."
        case .succeeded: return "Relocalization successful."
        case .failed: return "Unable to relocalize."
        }
    }
}

// MARK: Preflight

public enum PreflightStatus: String, Codable, Sendable {
    case ready, warning, blocked, unknown

    public var displayName: String {
        switch self {
        case .ready: return "Ready"
        case .warning: return "Check"
        case .blocked: return "Not available"
        case .unknown: return "Unknown"
        }
    }
}

/// One thing that has to be true before walking a property. Checked before
/// the first scan so a stupid failure is caught in the doorway rather than
/// after an hour of walking.
public struct PreflightCheck: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var status: PreflightStatus
    public var detail: String
    /// A critical check that is blocked stops the scan. A non-critical one —
    /// compass heading, say — only warns, because RoomPlan still works
    /// without it and a walk should not be refused over a north arrow.
    public var isCritical: Bool

    public init(id: String, title: String, status: PreflightStatus, detail: String = "", isCritical: Bool = false) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.isCritical = isCritical
    }
}

public struct PreflightReport: Codable, Hashable, Sendable {
    public var checks: [PreflightCheck]

    public init(checks: [PreflightCheck]) { self.checks = checks }

    public var blockers: [PreflightCheck] { checks.filter { $0.isCritical && $0.status == .blocked } }
    public var warnings: [PreflightCheck] { checks.filter { $0.status == .warning || (!$0.isCritical && $0.status == .blocked) } }
    public var canScan: Bool { blockers.isEmpty }

    public var summary: String {
        if let first = blockers.first {
            return blockers.count == 1
                ? "Cannot scan: \(first.title.lowercased()) — \(first.detail)"
                : "Cannot scan: \(blockers.count) problems, starting with \(first.title.lowercased())."
        }
        if warnings.isEmpty { return "Ready to scan." }
        return warnings.count == 1
            ? "Ready, with one caution: \(warnings[0].title.lowercased())."
            : "Ready, with \(warnings.count) cautions."
    }
}

// MARK: Storage

/// How much recording time is left, from what this session has actually
/// been writing. Warns while there is still time to do something about it.
public struct StorageEstimate: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable { case ok, low, critical }

    public var freeBytes: Int64
    public var sessionBytes: Int64
    public var bytesPerSecond: Double
    /// Nil when nothing has been written yet, so no rate can be honest.
    public var remainingSeconds: Double?
    public var level: Level

    public var remainingMinutes: Int? { remainingSeconds.map { Int(($0 / 60).rounded(.down)) } }

    public var message: String? {
        switch level {
        case .ok: return nil
        case .low:
            guard let minutes = remainingMinutes else { return "Storage getting low." }
            return "Storage getting low. Approximately \(minutes) minutes of validation recording remaining."
        case .critical:
            return "Storage critically low — everything has been checkpointed. Free space before scanning more."
        }
    }

    /// - Parameters:
    ///   - reserveBytes: space never counted as usable, so the phone does not
    ///     hit zero — iOS misbehaves badly before a volume is truly full.
    public static func estimate(
        sessionBytes: Int64,
        elapsedSeconds: Double,
        freeBytes: Int64,
        reserveBytes: Int64 = 500_000_000,
        lowSeconds: Double = 15 * 60,
        criticalSeconds: Double = 4 * 60
    ) -> StorageEstimate {
        let usable = max(0, freeBytes - reserveBytes)
        let rate = elapsedSeconds > 1 && sessionBytes > 0
            ? Double(sessionBytes) / elapsedSeconds
            : 0
        let remaining: Double? = rate > 0 ? Double(usable) / rate : nil
        let level: Level
        if usable <= 0 {
            level = .critical
        } else if let remaining {
            level = remaining <= criticalSeconds ? .critical : (remaining <= lowSeconds ? .low : .ok)
        } else {
            level = .ok
        }
        return StorageEstimate(
            freeBytes: freeBytes,
            sessionBytes: sessionBytes,
            bytesPerSecond: rate,
            remainingSeconds: remaining,
            level: level)
    }
}

// MARK: Before leaving the property

/// The last look before getting in the car. Built from what the app actually
/// knows, not from questions the owner has to answer honestly.
public struct FieldVisitChecklist: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var isSatisfied: Bool
        public var detail: String
    }

    public var items: [Item]
    public var unresolved: [Item] { items.filter { !$0.isSatisfied } }
    public var isReadyToLeave: Bool { unresolved.isEmpty }

    public struct Input: Sendable {
        public var levels: [LevelGeometry]
        public var findings: [SpaceFinding]
        public var lowCoverageWallCount: Int
        public var trackingFailed: Bool
        public var outstandingCheckpoints: Int
        public var worldMapSaved: Bool
        public var sensorSessionFinalized: Bool
        public var validationSampleCount: Int
        public var unsavedValidationEdits: Bool
        public var projectSaved: Bool
        public var bundleAvailable: Bool

        public init(
            levels: [LevelGeometry] = [],
            findings: [SpaceFinding] = [],
            lowCoverageWallCount: Int = 0,
            trackingFailed: Bool = false,
            outstandingCheckpoints: Int = 0,
            worldMapSaved: Bool = false,
            sensorSessionFinalized: Bool = false,
            validationSampleCount: Int = 0,
            unsavedValidationEdits: Bool = false,
            projectSaved: Bool = false,
            bundleAvailable: Bool = false
        ) {
            self.levels = levels
            self.findings = findings
            self.lowCoverageWallCount = lowCoverageWallCount
            self.trackingFailed = trackingFailed
            self.outstandingCheckpoints = outstandingCheckpoints
            self.worldMapSaved = worldMapSaved
            self.sensorSessionFinalized = sensorSessionFinalized
            self.validationSampleCount = validationSampleCount
            self.unsavedValidationEdits = unsavedValidationEdits
            self.projectSaved = projectSaved
            self.bundleAvailable = bundleAvailable
        }
    }

    public static func build(_ input: Input) -> FieldVisitChecklist {
        let roomCount = input.levels.reduce(0) { $0 + $1.rooms.count }
        var items: [Item] = []

        items.append(Item(
            id: "rooms",
            title: "All intended rooms captured",
            isSatisfied: roomCount > 0,
            detail: roomCount == 0 ? "No rooms in the plan yet." : "\(roomCount) rooms on the plan."))

        items.append(Item(
            id: "checkpoints",
            title: "Every accepted room folded into the plan",
            isSatisfied: input.outstandingCheckpoints == 0,
            detail: input.outstandingCheckpoints == 0
                ? "Nothing outstanding."
                : "\(input.outstandingCheckpoints) accepted rooms are saved but not yet in the plan."))

        items.append(Item(
            id: "findings",
            title: "No unresolved missing-space warnings",
            isSatisfied: input.findings.isEmpty,
            detail: input.findings.isEmpty
                ? "Nothing looks unscanned."
                : "\(input.findings.count) areas look unscanned."))

        items.append(Item(
            id: "coverage",
            title: "No critically low-coverage walls",
            isSatisfied: input.lowCoverageWallCount == 0,
            detail: input.lowCoverageWallCount == 0
                ? "Every wall has mesh behind it."
                : "\(input.lowCoverageWallCount) walls were barely seen."))

        items.append(Item(
            id: "tracking",
            title: "No unresolved tracking failure",
            isSatisfied: !input.trackingFailed,
            detail: input.trackingFailed ? "A tracking loss was never recovered." : "Tracking held."))

        items.append(Item(
            id: "validation",
            title: "All validation measurements saved",
            isSatisfied: !input.unsavedValidationEdits,
            detail: "\(input.validationSampleCount) ground-truth samples recorded."))

        items.append(Item(
            id: "worldmap",
            title: "World map checkpoint saved",
            isSatisfied: input.worldMapSaved,
            detail: input.worldMapSaved
                ? "A map is stored for resuming."
                : "No map saved — an interrupted return would start a separate scan."))

        items.append(Item(
            id: "sensor",
            title: "Sensor session finalized",
            isSatisfied: input.sensorSessionFinalized,
            detail: input.sensorSessionFinalized ? "Written and closed." : "Still open."))

        items.append(Item(
            id: "bundle",
            title: "Validation bundle available",
            isSatisfied: input.bundleAvailable,
            detail: input.bundleAvailable ? "Ready to export." : "Nothing to export yet."))

        items.append(Item(
            id: "saved",
            title: "Project saved successfully",
            isSatisfied: input.projectSaved,
            detail: input.projectSaved ? "Saved." : "The last save did not complete."))

        return FieldVisitChecklist(items: items)
    }
}
