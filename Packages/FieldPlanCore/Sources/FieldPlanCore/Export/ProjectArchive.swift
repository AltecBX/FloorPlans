import Foundation

// MARK: - Portable project archive (spec §39, §40)
//
// project.json inside a .fieldplan package. The schema is versioned; assets
// (photos, scan data, USDZ) are referenced by relative path, never embedded.

/// Photo metadata as archived (binary lives at `fileName` inside the package).
public struct PhotoMeta: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var fileName: String
    public var thumbnailFileName: String?
    public var caption: String
    public var roomID: UUID?
    public var levelID: UUID?
    public var wallID: UUID?
    public var measurementID: UUID?
    public var createdAt: Date
    /// Annotation shapes drawn over the photo, serialized separately.
    public var annotationFileName: String?

    public init(
        id: UUID = UUID(),
        fileName: String,
        thumbnailFileName: String? = nil,
        caption: String = "",
        roomID: UUID? = nil,
        levelID: UUID? = nil,
        wallID: UUID? = nil,
        measurementID: UUID? = nil,
        createdAt: Date = Date(),
        annotationFileName: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.caption = caption
        self.roomID = roomID
        self.levelID = levelID
        self.wallID = wallID
        self.measurementID = measurementID
        self.createdAt = createdAt
        self.annotationFileName = annotationFileName
    }
}

/// A quick field note attached to any scope level.
public struct NoteMeta: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var roomID: UUID?
    public var levelID: UUID?
    public var wallID: UUID?
    public var measurementID: UUID?
    public var photoID: UUID?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        roomID: UUID? = nil,
        levelID: UUID? = nil,
        wallID: UUID? = nil,
        measurementID: UUID? = nil,
        photoID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.roomID = roomID
        self.levelID = levelID
        self.wallID = wallID
        self.measurementID = measurementID
        self.photoID = photoID
        self.createdAt = createdAt
    }
}

/// Record of a raw scan session (the CapturedRoom JSON + USDZ live as assets).
public struct ScanSessionMeta: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var levelID: UUID?
    public var roomName: String
    public var capturedAt: Date
    /// Relative path of the serialized raw scan (CapturedRoom JSON).
    public var rawDataFileName: String?
    public var usdzFileName: String?
    public var isSampleData: Bool

    public init(
        id: UUID = UUID(),
        levelID: UUID? = nil,
        roomName: String,
        capturedAt: Date = Date(),
        rawDataFileName: String? = nil,
        usdzFileName: String? = nil,
        isSampleData: Bool = false
    ) {
        self.id = id
        self.levelID = levelID
        self.roomName = roomName
        self.capturedAt = capturedAt
        self.rawDataFileName = rawDataFileName
        self.usdzFileName = usdzFileName
        self.isSampleData = isSampleData
    }
}

/// The complete portable project.
public struct ProjectArchive: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var appVersion: String
    public var meta: ProjectMeta
    /// All plan versions; the Existing Conditions snapshot is locked.
    public var snapshots: [PlanSnapshot]
    /// ID of the snapshot currently being worked on.
    public var activeSnapshotID: UUID?
    public var measurements: [FieldMeasurementModel]
    public var photos: [PhotoMeta]
    public var notes: [NoteMeta]
    public var scanSessions: [ScanSessionMeta]
    public var takeoffItems: [TakeoffItem]

    public init(
        schemaVersion: Int = ProjectArchive.currentSchemaVersion,
        exportedAt: Date = Date(),
        appVersion: String = "1.0",
        meta: ProjectMeta,
        snapshots: [PlanSnapshot] = [],
        activeSnapshotID: UUID? = nil,
        measurements: [FieldMeasurementModel] = [],
        photos: [PhotoMeta] = [],
        notes: [NoteMeta] = [],
        scanSessions: [ScanSessionMeta] = [],
        takeoffItems: [TakeoffItem] = []
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.meta = meta
        self.snapshots = snapshots
        self.activeSnapshotID = activeSnapshotID
        self.measurements = measurements
        self.photos = photos
        self.notes = notes
        self.scanSessions = scanSessions
        self.takeoffItems = takeoffItems
    }

    // MARK: - Serialization

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func jsonData() throws -> Data {
        try ProjectArchive.encoder().encode(self)
    }

    public enum ArchiveError: Error, LocalizedError {
        case unsupportedSchemaVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let v):
                return "This project was exported by a newer FieldPlan (schema v\(v)) and cannot be opened here."
            }
        }
    }

    public static func decode(from data: Data) throws -> ProjectArchive {
        // Read the schema version first so future migrations have a hook.
        struct VersionProbe: Codable { var schemaVersion: Int }
        let probe = try decoder().decode(VersionProbe.self, from: data)
        guard probe.schemaVersion <= currentSchemaVersion else {
            throw ArchiveError.unsupportedSchemaVersion(probe.schemaVersion)
        }
        // Future: switch on probe.schemaVersion and migrate older payloads.
        return try decoder().decode(ProjectArchive.self, from: data)
    }
}
