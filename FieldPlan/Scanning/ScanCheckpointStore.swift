import Foundation
import RoomPlan
import FieldPlanCore

// MARK: - A room is safe the moment it is accepted (build 15, priority 2 and 3)
//
// Until build 15 accepted rooms lived in an array in `ScanCoordinator` until
// Finish Level ran. An iOS memory kill between the first room and the last
// one lost the entire walk — and the code claimed the opposite in a comment.
//
// Now Accept writes the raw capture, the USDZ and a checkpoint record before
// anything else happens. Reconstruction can still fail, the app can still be
// terminated, and the rooms remain on disk. Everything is keyed by RoomPlan's
// own `CapturedRoom.identifier`, so replaying a checkpoint cannot create the
// same room twice.

@MainActor
final class ScanCheckpointStore {
    static let shared = ScanCheckpointStore()

    private let store = ProjectStore.shared

    private func indexURL(_ projectID: UUID) -> URL {
        store.scansDir(projectID).appendingPathComponent("checkpoints.json")
    }

    /// Every checkpoint the project has, merged and outstanding alike.
    func checkpoints(for projectID: UUID) -> [RoomCheckpoint] {
        guard let data = try? Data(contentsOf: indexURL(projectID)),
              let list = try? ProjectArchive.decoder().decode([RoomCheckpoint].self, from: data)
        else { return [] }
        return list
    }

    private func write(_ checkpoints: [RoomCheckpoint], for projectID: UUID) {
        do {
            let data = try ProjectArchive.encoder().encode(checkpoints)
            try data.write(to: indexURL(projectID), options: .atomic)
        } catch {
            AppLog.store.error("Checkpoint index write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the room to disk and records it. Returns the checkpoint, or nil
    /// only if the raw capture itself could not be written — in which case
    /// the caller must tell the owner rather than carrying on as if the room
    /// were safe.
    @discardableResult
    func checkpoint(
        room: CapturedRoom,
        name: String,
        projectID: UUID,
        levelID: UUID?,
        scanSessionID: UUID?,
        worldMapCheckpointID: UUID?,
        cameraTransform: [Float]?,
        floorCoverage: Double?,
        wallCoverage: Double?,
        meshChunkCount: Int?
    ) -> RoomCheckpoint? {
        let scansDir = store.scansDir(projectID)
        let identifier = room.identifier
        var rawName: String?
        var usdzName: String?

        do {
            let data = try CapturedRoomBridge.rawJSON(for: room)
            let file = "\(identifier.uuidString).json"
            try data.write(to: scansDir.appendingPathComponent(file), options: .atomic)
            rawName = file
        } catch {
            // Without the raw capture there is nothing to recover from, so
            // this is the one failure the caller must surface.
            AppLog.scan.error("Checkpoint raw write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            let file = "\(identifier.uuidString).usdz"
            try room.export(to: scansDir.appendingPathComponent(file), exportOptions: .parametric)
            usdzName = file
        } catch {
            // A missing USDZ costs a preview, not the data.
            AppLog.scan.error("Checkpoint USDZ export failed: \(error.localizedDescription, privacy: .public)")
        }

        let checkpoint = RoomCheckpoint(
            id: identifier,
            projectID: projectID,
            levelID: levelID,
            scanSessionID: scanSessionID,
            roomName: name.isEmpty ? "Auto-labeled room" : name,
            suggestedType: nil,
            capturedAt: Date(),
            rawDataFileName: rawName,
            usdzFileName: usdzName,
            worldMapCheckpointID: worldMapCheckpointID,
            cameraTransform: cameraTransform,
            floorCoverage: floorCoverage,
            wallCoverage: wallCoverage,
            meshChunkCount: meshChunkCount)

        let merged = CheckpointStore.merge(checkpoints(for: projectID), with: [checkpoint])
        write(merged, for: projectID)
        AppLog.scan.info("Room checkpointed: \(checkpoint.roomName, privacy: .public)")
        return checkpoint
    }

    /// Marks rooms as folded into a snapshot. Safe to call twice.
    func markMerged(_ ids: Set<UUID>, snapshotID: UUID, projectID: UUID) {
        guard !ids.isEmpty else { return }
        write(CheckpointStore.markMerged(checkpoints(for: projectID), ids: ids, snapshotID: snapshotID),
              for: projectID)
    }

    /// What an interrupted walk left behind, or nil when there is nothing.
    func unfinished(for projectID: UUID) -> UnfinishedScan? {
        let maps = SpatialSession.loadLatestCheckpoint(in: worldMapsDir(projectID))
        return CheckpointStore.unfinished(
            projectID: projectID,
            checkpoints: checkpoints(for: projectID),
            worldMapAvailable: maps != nil)
    }

    func worldMapsDir(_ projectID: UUID) -> URL {
        let url = store.projectDir(projectID).appendingPathComponent("worldmaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Reads captured rooms back from their checkpoints, so a walk can be
    /// finished from what was saved even if nothing is still in memory.
    /// Rooms whose raw file will not decode are reported rather than skipped
    /// silently — a room that cannot be recovered is something the owner has
    /// to know about while still on site.
    func restoreRooms(_ checkpoints: [RoomCheckpoint], projectID: UUID)
        -> (rooms: [(checkpoint: RoomCheckpoint, room: CapturedRoom)], failed: [RoomCheckpoint]) {
        var restored: [(RoomCheckpoint, CapturedRoom)] = []
        var failed: [RoomCheckpoint] = []
        let scansDir = store.scansDir(projectID)
        for checkpoint in checkpoints {
            guard let file = checkpoint.rawDataFileName,
                  let data = try? Data(contentsOf: scansDir.appendingPathComponent(file)),
                  let room = try? CapturedRoomBridge.loadRawRoom(from: data)
            else {
                failed.append(checkpoint)
                continue
            }
            restored.append((checkpoint, room))
        }
        return (restored, failed)
    }

    /// Discards an unfinished session's checkpoints. Only ever called from an
    /// explicit choice — nothing here throws data away on its own.
    func discardUnfinished(for projectID: UUID) {
        let remaining = checkpoints(for: projectID).filter { $0.isMerged }
        write(remaining, for: projectID)
        AppLog.scan.info("Unfinished scan discarded on request")
    }
}
