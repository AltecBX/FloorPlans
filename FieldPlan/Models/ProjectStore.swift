import Foundation
import SwiftData
import UIKit
import FieldPlanCore

/// File-system storage for a project's heavy data (geometry snapshots, raw
/// scans, photos, exports) plus lifecycle operations. All writes are atomic;
/// a crash mid-write never corrupts an inspection (spec §4, §46).
///
/// Layout: Application Support/FieldPlan/Projects/<projectID>/
///   snapshots/<snapshotID>.json     PlanSnapshot (canonical geometry)
///   scans/<scanID>.json|.usdz       raw RoomPlan output
///   photos/<photoID>.jpg|-thumb.jpg
///   exports/<generated files>
@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    enum StoreError: LocalizedError {
        case snapshotMissing(UUID)
        case importUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .snapshotMissing(let id):
                return "Plan version \(id.uuidString.prefix(8)) is missing its geometry file."
            case .importUnreadable(let reason):
                return "Could not import the package: \(reason)"
            }
        }
    }

    let root: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("FieldPlan/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Directories

    func projectDir(_ projectID: UUID) -> URL {
        root.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    func dir(_ projectID: UUID, _ sub: String) -> URL {
        let url = projectDir(projectID).appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func snapshotsDir(_ id: UUID) -> URL { dir(id, "snapshots") }
    func scansDir(_ id: UUID) -> URL { dir(id, "scans") }
    func photosDir(_ id: UUID) -> URL { dir(id, "photos") }
    func exportsDir(_ id: UUID) -> URL { dir(id, "exports") }

    // MARK: - Snapshots (geometry versions)

    private var snapshotCache: [UUID: PlanSnapshot] = [:]

    func snapshotURL(projectID: UUID, snapshotID: UUID) -> URL {
        snapshotsDir(projectID).appendingPathComponent("\(snapshotID.uuidString).json")
    }

    func loadSnapshot(projectID: UUID, snapshotID: UUID) throws -> PlanSnapshot {
        if let cached = snapshotCache[snapshotID] { return cached }
        let url = snapshotURL(projectID: projectID, snapshotID: snapshotID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.snapshotMissing(snapshotID)
        }
        let data = try Data(contentsOf: url)
        let snapshot = try ProjectArchive.decoder().decode(PlanSnapshot.self, from: data)
        snapshotCache[snapshotID] = snapshot
        return snapshot
    }

    func saveSnapshot(_ snapshot: PlanSnapshot, projectID: UUID) throws {
        let url = snapshotURL(projectID: projectID, snapshotID: snapshot.id)
        let data = try ProjectArchive.encoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
        snapshotCache[snapshot.id] = snapshot
        AppLog.store.info("Saved snapshot \(snapshot.name, privacy: .public) (\(data.count) bytes)")
    }

    func deleteSnapshotFile(projectID: UUID, snapshotID: UUID) {
        snapshotCache[snapshotID] = nil
        try? FileManager.default.removeItem(at: snapshotURL(projectID: projectID, snapshotID: snapshotID))
    }

    func invalidateCache(_ snapshotID: UUID? = nil) {
        if let snapshotID {
            snapshotCache[snapshotID] = nil
        } else {
            snapshotCache.removeAll()
        }
    }

    /// The project's Existing Conditions snapshot, created on first use.
    func existingConditions(for project: ProjectRecord, context: ModelContext) throws -> PlanSnapshot {
        if let record = project.snapshots.first(where: { $0.kind == .existingConditions }) {
            return try loadSnapshot(projectID: project.id, snapshotID: record.id)
        }
        let snapshot = PlanSnapshot(
            name: "Existing Conditions",
            kind: .existingConditions,
            isLocked: false,
            levels: [LevelGeometry(name: "First Floor", storyIndex: 0)]
        )
        try saveSnapshot(snapshot, projectID: project.id)
        let record = SnapshotRecord(
            id: snapshot.id, name: snapshot.name, kind: .existingConditions, isLocked: false)
        record.project = project
        context.insert(record)
        if project.activeSnapshotID == nil {
            project.activeSnapshotID = snapshot.id
        }
        try context.save()
        return snapshot
    }

    /// Active (working) snapshot for a project; defaults to Existing Conditions.
    func activeSnapshot(for project: ProjectRecord, context: ModelContext) throws -> PlanSnapshot {
        if let id = project.activeSnapshotID,
           project.snapshots.contains(where: { $0.id == id }),
           let snapshot = try? loadSnapshot(projectID: project.id, snapshotID: id) {
            return snapshot
        }
        return try existingConditions(for: project, context: context)
    }

    /// Duplicates a snapshot into a new editable proposed plan (spec §23).
    @discardableResult
    func duplicateSnapshot(
        _ source: PlanSnapshot, named name: String,
        project: ProjectRecord, context: ModelContext
    ) throws -> PlanSnapshot {
        let copy = source.duplicatedAsProposed(named: name)
        try saveSnapshot(copy, projectID: project.id)
        let record = SnapshotRecord(id: copy.id, name: copy.name, kind: .proposed, isLocked: false)
        record.project = project
        context.insert(record)
        try context.save()
        return copy
    }

    /// Updates geometry of one level inside a snapshot and persists.
    func updateLevel(
        _ level: LevelGeometry, in snapshot: PlanSnapshot, projectID: UUID
    ) throws -> PlanSnapshot {
        var updated = snapshot
        if let index = updated.levels.firstIndex(where: { $0.id == level.id }) {
            updated.levels[index] = level
        } else {
            updated.levels.append(level)
        }
        try saveSnapshot(updated, projectID: projectID)
        return updated
    }

    // MARK: - Photos

    func savePhoto(
        _ image: UIImage, project: ProjectRecord, context: ModelContext,
        caption: String = "", roomID: UUID? = nil, levelID: UUID? = nil,
        wallID: UUID? = nil, measurementID: UUID? = nil
    ) throws -> PhotoRecord {
        let id = UUID()
        let fileName = "\(id.uuidString).jpg"
        let thumbName = "\(id.uuidString)-thumb.jpg"
        let dir = photosDir(project.id)

        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw StoreError.importUnreadable("photo could not be encoded")
        }
        try jpeg.write(to: dir.appendingPathComponent(fileName), options: .atomic)

        let thumb = Self.thumbnail(of: image, maxDimension: 400)
        if let thumbData = thumb.jpegData(compressionQuality: 0.7) {
            try? thumbData.write(to: dir.appendingPathComponent(thumbName), options: .atomic)
        }

        let record = PhotoRecord(
            id: id, fileName: fileName, thumbnailFileName: thumbName,
            caption: caption, roomID: roomID, levelID: levelID,
            wallID: wallID, measurementID: measurementID)
        record.project = project
        context.insert(record)
        project.updatedAt = Date()
        try context.save()
        return record
    }

    func photoURL(_ record: PhotoRecord, projectID: UUID) -> URL {
        photosDir(projectID).appendingPathComponent(record.fileName)
    }

    func thumbnailURL(_ record: PhotoRecord, projectID: UUID) -> URL? {
        record.thumbnailFileName.map { photosDir(projectID).appendingPathComponent($0) }
    }

    func loadImage(_ record: PhotoRecord, projectID: UUID, thumbnail: Bool = false) -> UIImage? {
        if thumbnail, let url = thumbnailURL(record, projectID: projectID),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        return UIImage(contentsOfFile: photoURL(record, projectID: projectID).path)
    }

    func deletePhotoFiles(_ record: PhotoRecord, projectID: UUID) {
        try? FileManager.default.removeItem(at: photoURL(record, projectID: projectID))
        if let thumbURL = thumbnailURL(record, projectID: projectID) {
            try? FileManager.default.removeItem(at: thumbURL)
        }
    }

    nonisolated static func thumbnail(of image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return image }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - Project lifecycle

    func deleteProjectFiles(_ projectID: UUID) {
        invalidateCache()
        try? FileManager.default.removeItem(at: projectDir(projectID))
    }

    /// Duplicates a whole project: records + files (spec §5).
    func duplicateProject(_ source: ProjectRecord, context: ModelContext) throws -> ProjectRecord {
        let copy = ProjectRecord(
            name: source.name + " Copy",
            clientName: source.clientName,
            address: source.address,
            unit: source.unit,
            jobType: source.jobType,
            status: source.status,
            inspectionDate: source.inspectionDate,
            clientPhone: source.clientPhone,
            clientEmail: source.clientEmail,
            notes: source.notes
        )
        context.insert(copy)

        // Copy the file tree wholesale.
        let sourceDir = projectDir(source.id)
        let destDir = projectDir(copy.id)
        if FileManager.default.fileExists(atPath: sourceDir.path) {
            try FileManager.default.copyItem(at: sourceDir, to: destDir)
        }

        // Mirror records (IDs preserved — they are scoped by project).
        for s in source.snapshots {
            let r = SnapshotRecord(id: s.id, name: s.name, kind: s.kind, isLocked: s.isLocked, createdAt: s.createdAt)
            r.project = copy
            context.insert(r)
        }
        for s in source.scans {
            let r = ScanRecord(id: s.id, levelID: s.levelID, roomName: s.roomName,
                               capturedAt: s.capturedAt, rawDataFileName: s.rawDataFileName,
                               usdzFileName: s.usdzFileName, isSampleData: s.isSampleData)
            r.project = copy
            context.insert(r)
        }
        for p in source.photos {
            let r = PhotoRecord(id: p.id, fileName: p.fileName, thumbnailFileName: p.thumbnailFileName,
                                caption: p.caption, roomID: p.roomID, levelID: p.levelID,
                                wallID: p.wallID, measurementID: p.measurementID, createdAt: p.createdAt)
            r.annotationData = p.annotationData
            r.project = copy
            context.insert(r)
        }
        for n in source.noteRecords {
            let r = NoteRecord(id: n.id, text: n.text, roomID: n.roomID, levelID: n.levelID,
                               wallID: n.wallID, measurementID: n.measurementID,
                               photoID: n.photoID, createdAt: n.createdAt)
            r.project = copy
            context.insert(r)
        }
        for m in source.measurements {
            let r = MeasurementRecord(model: m.model)
            r.project = copy
            context.insert(r)
        }
        for t in source.takeoffItems {
            if let item = t.item {
                let r = TakeoffItemRecord(item: item)
                r.project = copy
                context.insert(r)
            }
        }
        copy.activeSnapshotID = source.activeSnapshotID
        copy.coverPhotoID = source.coverPhotoID
        try context.save()
        return copy
    }

    // MARK: - .fieldplan package export / import (spec §40)

    func exportPackage(_ project: ProjectRecord) throws -> URL {
        var entries: [ZipEntry] = []

        // project.json
        var snapshots: [PlanSnapshot] = []
        for record in project.snapshots.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let snapshot = try? loadSnapshot(projectID: project.id, snapshotID: record.id) {
                snapshots.append(snapshot)
            }
        }
        let archive = ProjectArchive(
            appVersion: AppInfo.version,
            meta: project.meta,
            snapshots: snapshots,
            activeSnapshotID: project.activeSnapshotID,
            measurements: project.measurements.map(\.model),
            photos: project.photos.map { record in
                var meta = record.photoMeta
                meta.fileName = "photos/\(record.fileName)"
                meta.thumbnailFileName = record.thumbnailFileName.map { "photos/\($0)" }
                return meta
            },
            notes: project.noteRecords.map(\.noteMeta),
            scanSessions: project.scans.map { scan in
                ScanSessionMeta(
                    id: scan.id, levelID: scan.levelID, roomName: scan.roomName,
                    capturedAt: scan.capturedAt,
                    rawDataFileName: scan.rawDataFileName.map { "scans/\($0)" },
                    usdzFileName: scan.usdzFileName.map { "scans/\($0)" },
                    isSampleData: scan.isSampleData)
            },
            takeoffItems: project.takeoffItems.compactMap(\.item)
        )
        entries.append(ZipEntry(path: "project.json", data: try archive.jsonData()))

        // Asset files by directory.
        func addFiles(from dir: URL, prefix: String) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
            for file in files where !file.hasDirectoryPath {
                if let data = try? Data(contentsOf: file) {
                    entries.append(ZipEntry(path: "\(prefix)/\(file.lastPathComponent)", data: data))
                }
            }
        }
        addFiles(from: photosDir(project.id), prefix: "photos")
        addFiles(from: scansDir(project.id), prefix: "scans")

        let safeName = project.name
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .replacingOccurrences(of: " ", with: "-")
        let url = exportsDir(project.id)
            .appendingPathComponent("\(safeName.isEmpty ? "Project" : safeName).fieldplan")
        try ZipArchive.write(entries: entries, to: url)
        AppLog.export.info("Exported package to \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// Imports a .fieldplan package as a NEW project.
    @discardableResult
    func importPackage(from url: URL, context: ModelContext) throws -> ProjectRecord {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        let entries: [ZipEntry]
        do {
            entries = try ZipArchive.read(url: url)
        } catch {
            throw StoreError.importUnreadable(error.localizedDescription)
        }
        guard let projectEntry = entries.first(where: { $0.path == "project.json" }) else {
            throw StoreError.importUnreadable("project.json missing")
        }
        let archive = try ProjectArchive.decode(from: projectEntry.data)

        // New project identity to avoid clashing with an existing import.
        let project = ProjectRecord(
            name: archive.meta.name,
            clientName: archive.meta.clientName,
            address: archive.meta.address,
            unit: archive.meta.unit,
            jobType: archive.meta.jobType,
            status: archive.meta.status,
            inspectionDate: archive.meta.inspectionDate,
            clientPhone: archive.meta.clientPhone,
            clientEmail: archive.meta.clientEmail,
            notes: archive.meta.notes
        )
        context.insert(project)

        for snapshot in archive.snapshots {
            try saveSnapshot(snapshot, projectID: project.id)
            let record = SnapshotRecord(
                id: snapshot.id, name: snapshot.name, kind: snapshot.kind,
                isLocked: snapshot.isLocked, createdAt: snapshot.createdAt)
            record.project = project
            context.insert(record)
        }
        project.activeSnapshotID = archive.activeSnapshotID ?? archive.snapshots.first?.id

        for m in archive.measurements {
            let record = MeasurementRecord(model: m)
            record.project = project
            context.insert(record)
        }
        for n in archive.notes {
            let record = NoteRecord(id: n.id, text: n.text, roomID: n.roomID, levelID: n.levelID,
                                    wallID: n.wallID, measurementID: n.measurementID,
                                    photoID: n.photoID, createdAt: n.createdAt)
            record.project = project
            context.insert(record)
        }

        // Restore asset files.
        let photoDir = photosDir(project.id)
        let scanDir = scansDir(project.id)
        for entry in entries {
            if entry.path.hasPrefix("photos/") {
                let name = String(entry.path.dropFirst("photos/".count))
                guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { continue }
                try? entry.data.write(to: photoDir.appendingPathComponent(name), options: .atomic)
            } else if entry.path.hasPrefix("scans/") {
                let name = String(entry.path.dropFirst("scans/".count))
                guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { continue }
                try? entry.data.write(to: scanDir.appendingPathComponent(name), options: .atomic)
            }
        }
        for photo in archive.photos {
            let fileName = (photo.fileName as NSString).lastPathComponent
            let record = PhotoRecord(
                id: photo.id, fileName: fileName,
                thumbnailFileName: photo.thumbnailFileName.map { ($0 as NSString).lastPathComponent },
                caption: photo.caption, roomID: photo.roomID, levelID: photo.levelID,
                wallID: photo.wallID, measurementID: photo.measurementID, createdAt: photo.createdAt)
            record.project = project
            context.insert(record)
        }
        for scan in archive.scanSessions {
            let record = ScanRecord(
                id: scan.id, levelID: scan.levelID, roomName: scan.roomName,
                capturedAt: scan.capturedAt,
                rawDataFileName: scan.rawDataFileName.map { ($0 as NSString).lastPathComponent },
                usdzFileName: scan.usdzFileName.map { ($0 as NSString).lastPathComponent },
                isSampleData: scan.isSampleData)
            record.project = project
            context.insert(record)
        }
        for item in archive.takeoffItems {
            let record = TakeoffItemRecord(item: item)
            record.project = project
            context.insert(record)
        }

        try context.save()
        AppLog.store.info("Imported package \(url.lastPathComponent, privacy: .public)")
        return project
    }

    // MARK: - Sample project (spec §59)

    /// Creates a clearly-labeled SAMPLE project for exploring the app.
    @discardableResult
    func createSampleProject(context: ModelContext) throws -> ProjectRecord {
        let archive = SampleFixtures.sampleProject()
        let project = ProjectRecord(
            name: archive.meta.name,
            clientName: archive.meta.clientName,
            address: archive.meta.address,
            unit: archive.meta.unit,
            jobType: archive.meta.jobType,
            status: archive.meta.status,
            notes: "SAMPLE DATA — generated for exploring \(AppInfo.appName). Not field measurements."
        )
        context.insert(project)
        for snapshot in archive.snapshots {
            try saveSnapshot(snapshot, projectID: project.id)
            let record = SnapshotRecord(
                id: snapshot.id, name: snapshot.name, kind: snapshot.kind,
                isLocked: snapshot.isLocked, createdAt: snapshot.createdAt)
            record.project = project
            context.insert(record)
        }
        project.activeSnapshotID = archive.snapshots.first?.id
        for m in archive.measurements {
            let record = MeasurementRecord(model: m)
            record.project = project
            context.insert(record)
        }
        for n in archive.notes {
            let record = NoteRecord(id: n.id, text: n.text, createdAt: n.createdAt)
            record.project = project
            context.insert(record)
        }
        try context.save()
        return project
    }
}
