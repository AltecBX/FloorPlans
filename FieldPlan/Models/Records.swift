import Foundation
import SwiftData
import FieldPlanCore

// MARK: - SwiftData persistence models
//
// SwiftData stores project METADATA and lightweight records for querying.
// Heavy structured data — geometry snapshots, raw scans, photos — lives in
// per-project files managed by ProjectStore, referenced by file name. This
// keeps the database small, makes autosave cheap, and lets the whole project
// round-trip through the portable .fieldplan package.
//
// Schema evolution (spec §52): FieldPlanSchemaV1 is a named VersionedSchema;
// future versions add a SchemaMigrationPlan without breaking stored data.

enum FieldPlanSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ProjectRecord.self, SnapshotRecord.self, ScanRecord.self,
         PhotoRecord.self, NoteRecord.self, MeasurementRecord.self,
         TakeoffItemRecord.self, AccuracyTestRecord.self]
    }
}

@Model
final class ProjectRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var clientName: String
    var address: String
    var unit: String
    var jobTypeRaw: String
    var statusRaw: String
    var inspectionDate: Date?
    var clientPhone: String
    var clientEmail: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
    var isArchived: Bool
    var coverPhotoID: UUID?
    /// The snapshot currently open for viewing/editing.
    var activeSnapshotID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \SnapshotRecord.project)
    var snapshots: [SnapshotRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \ScanRecord.project)
    var scans: [ScanRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \PhotoRecord.project)
    var photos: [PhotoRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \NoteRecord.project)
    var noteRecords: [NoteRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \MeasurementRecord.project)
    var measurements: [MeasurementRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \TakeoffItemRecord.project)
    var takeoffItems: [TakeoffItemRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \AccuracyTestRecord.project)
    var accuracyTests: [AccuracyTestRecord] = []

    init(
        id: UUID = UUID(),
        name: String,
        clientName: String = "",
        address: String = "",
        unit: String = "",
        jobType: JobType = .other,
        status: ProjectStatus = .lead,
        inspectionDate: Date? = nil,
        clientPhone: String = "",
        clientEmail: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.clientName = clientName
        self.address = address
        self.unit = unit
        self.jobTypeRaw = jobType.rawValue
        self.statusRaw = status.rawValue
        self.inspectionDate = inspectionDate
        self.clientPhone = clientPhone
        self.clientEmail = clientEmail
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isArchived = false
    }

    var jobType: JobType {
        get { JobType(rawValue: jobTypeRaw) ?? .other }
        set { jobTypeRaw = newValue.rawValue }
    }

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRaw) ?? .lead }
        set { statusRaw = newValue.rawValue }
    }

    var meta: ProjectMeta {
        ProjectMeta(
            id: id, name: name, clientName: clientName, address: address,
            unit: unit, jobType: jobType, status: status,
            inspectionDate: inspectionDate, clientPhone: clientPhone,
            clientEmail: clientEmail, notes: notes, createdAt: createdAt
        )
    }
}

/// One plan version. Geometry lives in `snapshots/<id>.json` (a PlanSnapshot).
@Model
final class SnapshotRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    var isLocked: Bool
    var createdAt: Date
    var updatedAt: Date
    var project: ProjectRecord?

    init(id: UUID, name: String, kind: PlanKind, isLocked: Bool, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.isLocked = isLocked
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var kind: PlanKind {
        get { PlanKind(rawValue: kindRaw) ?? .proposed }
        set { kindRaw = newValue.rawValue }
    }
}

/// A raw scan session. The serialized CapturedRoom JSON and USDZ live in
/// `scans/` so processing can be re-run later without revisiting the
/// property (spec §10).
@Model
final class ScanRecord {
    @Attribute(.unique) var id: UUID
    var levelID: UUID?
    var roomName: String
    var capturedAt: Date
    var rawDataFileName: String?
    var usdzFileName: String?
    var isSampleData: Bool
    var project: ProjectRecord?

    init(
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

@Model
final class PhotoRecord {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var thumbnailFileName: String?
    var caption: String
    var roomID: UUID?
    var levelID: UUID?
    var wallID: UUID?
    var measurementID: UUID?
    var createdAt: Date
    /// Serialized annotation shapes (PhotoAnnotationDocument JSON).
    var annotationData: Data?
    var project: ProjectRecord?

    init(
        id: UUID = UUID(),
        fileName: String,
        thumbnailFileName: String? = nil,
        caption: String = "",
        roomID: UUID? = nil,
        levelID: UUID? = nil,
        wallID: UUID? = nil,
        measurementID: UUID? = nil,
        createdAt: Date = Date()
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
    }

    var photoMeta: PhotoMeta {
        PhotoMeta(
            id: id, fileName: fileName, thumbnailFileName: thumbnailFileName,
            caption: caption, roomID: roomID, levelID: levelID, wallID: wallID,
            measurementID: measurementID, createdAt: createdAt
        )
    }
}

@Model
final class NoteRecord {
    @Attribute(.unique) var id: UUID
    var text: String
    var roomID: UUID?
    var levelID: UUID?
    var wallID: UUID?
    var measurementID: UUID?
    var photoID: UUID?
    var createdAt: Date
    var project: ProjectRecord?

    init(
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

    var noteMeta: NoteMeta {
        NoteMeta(
            id: id, text: text, roomID: roomID, levelID: levelID,
            wallID: wallID, measurementID: measurementID, photoID: photoID,
            createdAt: createdAt
        )
    }
}

/// Field measurement with full provenance (mirrors FieldMeasurementModel).
@Model
final class MeasurementRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var categoryRaw: String
    var kindRaw: String
    /// Meters (m² for areas). Full precision, never rounded.
    var value: Double
    var originalValue: Double?
    var sourceRaw: String
    var verificationRaw: String
    var isCritical: Bool
    var confidenceRaw: String
    var notes: String
    var roomID: UUID?
    var levelID: UUID?
    var elementID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var project: ProjectRecord?

    init(model: FieldMeasurementModel) {
        self.id = model.id
        self.name = model.name
        self.categoryRaw = model.category.rawValue
        self.kindRaw = model.kind.rawValue
        self.value = model.value
        self.originalValue = model.originalValue
        self.sourceRaw = model.source.rawValue
        self.verificationRaw = model.verification.rawValue
        self.isCritical = model.isCritical
        self.confidenceRaw = model.confidence.rawValue
        self.notes = model.notes
        self.roomID = model.roomID
        self.levelID = model.levelID
        self.elementID = model.elementID
        self.createdAt = model.createdAt
        self.updatedAt = model.updatedAt
    }

    var model: FieldMeasurementModel {
        FieldMeasurementModel(
            id: id,
            name: name,
            category: MeasurementCategory(rawValue: categoryRaw) ?? .custom,
            kind: MeasurementKind(rawValue: kindRaw) ?? .length,
            value: value,
            originalValue: originalValue,
            source: MeasurementSource(rawValue: sourceRaw) ?? .manualEntry,
            verification: VerificationStatus(rawValue: verificationRaw) ?? .unverified,
            isCritical: isCritical,
            confidence: CaptureConfidence(rawValue: confidenceRaw) ?? .medium,
            notes: notes,
            roomID: roomID,
            levelID: levelID,
            elementID: elementID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Applies an edited value, preserving the original (spec §12).
    func applyEdit(newValue: Double, source: MeasurementSource = .edited) {
        let edited = model.editingValue(to: newValue, source: source)
        value = edited.value
        originalValue = edited.originalValue
        sourceRaw = edited.source.rawValue
        verificationRaw = edited.verification.rawValue
        updatedAt = edited.updatedAt
    }

    func apply(_ m: FieldMeasurementModel) {
        name = m.name
        categoryRaw = m.category.rawValue
        kindRaw = m.kind.rawValue
        value = m.value
        originalValue = m.originalValue
        sourceRaw = m.source.rawValue
        verificationRaw = m.verification.rawValue
        isCritical = m.isCritical
        confidenceRaw = m.confidence.rawValue
        notes = m.notes
        roomID = m.roomID
        levelID = m.levelID
        elementID = m.elementID
        updatedAt = Date()
    }
}

/// Takeoff item; scoped selections stored as encoded TakeoffItem JSON so the
/// nested structure survives schema changes without table churn.
@Model
final class TakeoffItemRecord {
    @Attribute(.unique) var id: UUID
    var categoryRaw: String
    var name: String
    var itemJSON: Data
    var createdAt: Date
    var project: ProjectRecord?

    init(item: TakeoffItem) {
        self.id = item.id
        self.categoryRaw = item.category.rawValue
        self.name = item.name
        self.itemJSON = (try? JSONEncoder().encode(item)) ?? Data()
        self.createdAt = Date()
    }

    var item: TakeoffItem? {
        try? JSONDecoder().decode(TakeoffItem.self, from: itemJSON)
    }

    func apply(_ item: TakeoffItem) {
        categoryRaw = item.category.rawValue
        name = item.name
        if let data = try? JSONEncoder().encode(item) {
            itemJSON = data
        } else {
            AppLog.store.error("Failed to encode takeoff item \(item.id)")
        }
    }
}

/// Known-dimension accuracy test (spec §31): compare a value the app produced
/// against a trusted physical measurement.
@Model
final class AccuracyTestRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Meters.
    var knownValue: Double
    var appValue: Double
    var sourceRaw: String
    var createdAt: Date
    var project: ProjectRecord?

    init(id: UUID = UUID(), name: String, knownValue: Double, appValue: Double, source: MeasurementSource) {
        self.id = id
        self.name = name
        self.knownValue = knownValue
        self.appValue = appValue
        self.sourceRaw = source.rawValue
        self.createdAt = Date()
    }

    var delta: Double { appValue - knownValue }
}
