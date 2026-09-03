import ARKit
import Foundation
import RoomPlan
import UIKit
import FieldPlanCore

// MARK: - FieldPlan owns the world (build 15, priority 0 and 1)
//
// Before this, RoomPlan created the ARSession and the recorder squeezed onto
// its delegate chain, re-attaching on a timer when RoomPlan replaced the
// delegate. That made FieldPlan a guest in its own coordinate system, and
// there was nowhere to keep an ARWorldMap.
//
// Now FieldPlan creates the ARSession and hands it to RoomPlan through the
// supported `RoomCaptureView(frame:arSession:)` initializer. RoomPlan still
// owns the *configuration* — that is required, and nothing here overrides
// what it sets — but the session, its delegate and its world map belong to
// the app. That is what makes a checkpoint and a resume possible.
//
// One honest caveat, recorded here because the field visit will settle it:
// RoomPlan re-runs the session with its own configuration when a capture
// starts, and Apple does not document whether an `initialWorldMap` survives
// that. So a resume is *attempted* and then *verified* — see
// `verifyRelocalization` — and if the coordinate system did not survive, the
// walk continues as a separate session that needs registration later rather
// than silently merging rooms into a space they do not belong to.

@MainActor
final class SpatialSession: NSObject, ObservableObject {

    /// The one session for the whole property walk.
    let arSession = ARSession()

    @Published private(set) var relocalization: RelocalizationState = .idle
    @Published private(set) var trackingState: TrackingQuality = .notAvailable
    @Published private(set) var mappingState: WorldMappingQuality = .notAvailable
    /// Set when a resume finished but the coordinates did not line up.
    @Published private(set) var coordinatesDiverged = false

    /// Where world maps for this project are written.
    private var mapsDirectory: URL?
    private var projectID: UUID?
    private var levelID: UUID?
    private var scanSessionID: UUID?

    /// The map that will be restored on a resume. Only ever replaced by one
    /// at least as good — losing the last good map is how a resume becomes
    /// impossible.
    @Published private(set) var bestCheckpoint: WorldMapCheckpoint?
    private var savingMap = false
    private var lastSaveAttempt: Date = .distantPast
    /// Transform of the origin anchor as it was when the map was saved.
    private var savedOriginTransform: [Float]?

    /// Delegate the recorder installs. Held so the session can be re-run
    /// without losing it.
    weak var recorderDelegate: ARSessionDelegate?

    // MARK: Lifecycle

    func configure(projectID: UUID, levelID: UUID?, scanSessionID: UUID?, mapsDirectory: URL) {
        self.projectID = projectID
        self.levelID = levelID
        self.scanSessionID = scanSessionID
        self.mapsDirectory = mapsDirectory
        try? FileManager.default.createDirectory(at: mapsDirectory, withIntermediateDirectories: true)
        if bestCheckpoint == nil { bestCheckpoint = Self.loadLatestCheckpoint(in: mapsDirectory) }
    }

    /// A RoomPlan view bound to *our* session. This is the supported path
    /// for supplying an existing ARSession.
    func makeCaptureView() -> RoomCaptureView {
        RoomCaptureView(frame: .zero, arSession: arSession)
    }

    /// Plants the anchor a later resume is verified against. Cheap, and the
    /// only way to know afterwards whether relocalization actually restored
    /// the same coordinate system.
    func plantOriginAnchor() {
        guard !arSession.currentFrame.map({ frame in
            frame.anchors.contains { $0.name == WorldMapPolicy.originAnchorName }
        }).isTrue else { return }
        let anchor = ARAnchor(name: WorldMapPolicy.originAnchorName, transform: matrix_identity_float4x4)
        arSession.add(anchor: anchor)
    }

    // MARK: World map checkpointing

    /// Asks for a world map when the mapping quality is worth keeping. Called
    /// on a timer and after every accepted room; cheap to call often because
    /// it refuses early when the map would be worse than the one on hand.
    func checkpointWorldMap(
        acceptedRoomCount: Int,
        lastAcceptedRoomID: UUID?,
        referenceKeyframe: String?,
        minimumInterval: TimeInterval = 20,
        completion: ((WorldMapCheckpoint?) -> Void)? = nil
    ) {
        guard let mapsDirectory, !savingMap else { completion?(nil); return }
        guard let frame = arSession.currentFrame else { completion?(nil); return }
        let status = Self.mappingQuality(frame.worldMappingStatus)
        guard WorldMapPolicy.shouldReplace(bestCheckpoint, with: status) else { completion?(nil); return }
        guard Date().timeIntervalSince(lastSaveAttempt) >= minimumInterval else { completion?(nil); return }

        savingMap = true
        lastSaveAttempt = Date()
        let cameraTransform = Self.floats(frame.camera.transform)
        let originTransform = frame.anchors
            .first { $0.name == WorldMapPolicy.originAnchorName }
            .map { Self.floats($0.transform) }
        let sessionID = scanSessionID
        let levelID = self.levelID

        arSession.getCurrentWorldMap { [weak self] map, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.savingMap = false }
                guard let map else {
                    AppLog.scan.error("World map checkpoint failed: \(error?.localizedDescription ?? "no map", privacy: .public)")
                    completion?(nil)
                    return
                }
                let id = UUID()
                let fileName = "\(id.uuidString).arworldmap"
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    try data.write(to: mapsDirectory.appendingPathComponent(fileName), options: .atomic)
                } catch {
                    AppLog.scan.error("World map write failed: \(error.localizedDescription, privacy: .public)")
                    completion?(nil)
                    return
                }
                let checkpoint = WorldMapCheckpoint(
                    id: id,
                    scanSessionID: sessionID,
                    levelID: levelID,
                    fileName: fileName,
                    mappingStatus: status,
                    trackingState: self.trackingState,
                    cameraTransform: cameraTransform,
                    referenceKeyframeFileName: referenceKeyframe,
                    lastAcceptedRoomID: lastAcceptedRoomID,
                    acceptedRoomCount: acceptedRoomCount,
                    originAnchorTransform: originTransform)
                self.bestCheckpoint = checkpoint
                self.savedOriginTransform = originTransform
                self.writeIndex(checkpoint, in: mapsDirectory)
                AppLog.scan.info("World map checkpoint saved (\(status.rawValue, privacy: .public))")
                completion?(checkpoint)
            }
        }
    }

    /// Metadata for every saved map, newest first, so the recovery screen can
    /// show where the owner was standing.
    static func loadLatestCheckpoint(in directory: URL) -> WorldMapCheckpoint? {
        let url = directory.appendingPathComponent("checkpoints.json")
        guard let data = try? Data(contentsOf: url),
              let all = try? ProjectArchive.decoder().decode([WorldMapCheckpoint].self, from: data)
        else { return nil }
        return all.max { $0.savedAt < $1.savedAt }
    }

    private func writeIndex(_ checkpoint: WorldMapCheckpoint, in directory: URL) {
        let url = directory.appendingPathComponent("checkpoints.json")
        var all = (try? Data(contentsOf: url))
            .flatMap { try? ProjectArchive.decoder().decode([WorldMapCheckpoint].self, from: $0) } ?? []
        all.removeAll { $0.id == checkpoint.id }
        all.append(checkpoint)
        // Keep the recent history; older maps are large and of no further use.
        all.sort { $0.savedAt < $1.savedAt }
        if all.count > 12 {
            for stale in all.prefix(all.count - 12) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale.fileName))
            }
            all = Array(all.suffix(12))
        }
        if let data = try? ProjectArchive.encoder().encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Resuming

    /// Restores the last good map and waits for ARKit to find itself again.
    /// Never merges anything: the caller must wait for `.succeeded` and then
    /// ask `verifyRelocalization` before letting a new room be scanned.
    func beginRelocalization() {
        guard let mapsDirectory, let checkpoint = bestCheckpoint else {
            relocalization = .failed
            return
        }
        relocalization = .loadingMap
        coordinatesDiverged = false
        let url = mapsDirectory.appendingPathComponent(checkpoint.fileName)
        guard let data = try? Data(contentsOf: url),
              let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
        else {
            AppLog.scan.error("World map could not be read for resume")
            relocalization = .failed
            return
        }
        savedOriginTransform = checkpoint.originAnchorTransform

        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = map
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        relocalization = .relocalizing
        AppLog.scan.info("Relocalization started from map \(checkpoint.id.uuidString, privacy: .public)")
    }

    /// Whether the restored session is in the same coordinate space as the
    /// rooms already captured. Called once tracking is normal again.
    ///
    /// A resume that cannot be verified is treated as a failure, not as a
    /// success — merging rooms into a coordinate system that has silently
    /// shifted produces a plan that looks fine and is wrong.
    func verifyRelocalization() -> Bool {
        guard let frame = arSession.currentFrame else { return false }
        let restored = frame.anchors
            .first { $0.name == WorldMapPolicy.originAnchorName }
            .map { Self.floats($0.transform) }
        let compatible = WorldMapPolicy.coordinatesCompatible(
            saved: savedOriginTransform, restored: restored)
        coordinatesDiverged = !compatible
        relocalization = compatible ? .succeeded : .failed
        if !compatible {
            AppLog.scan.error("Relocalization produced an incompatible coordinate system; refusing to merge")
        }
        return compatible
    }

    /// Gives up on the resume and continues as a separate session that will
    /// need registering against the earlier rooms later.
    func abandonRelocalization() {
        relocalization = .failed
        coordinatesDiverged = true
    }

    func clearRelocalization() {
        relocalization = .idle
        coordinatesDiverged = false
    }

    // MARK: Observed state

    /// Fed by the recorder, which is the delegate; the session does not
    /// compete for the delegate slot.
    func update(tracking: TrackingQuality, mapping: WorldMappingQuality) {
        if trackingState != tracking { trackingState = tracking }
        if mappingState != mapping { mappingState = mapping }
        if relocalization == .relocalizing, tracking == .normal {
            _ = verifyRelocalization()
        }
    }

    /// True while a new room must not be started.
    var isBusyRelocalizing: Bool {
        relocalization == .loadingMap || relocalization == .relocalizing
    }

    // MARK: Conversions

    static func mappingQuality(_ status: ARFrame.WorldMappingStatus) -> WorldMappingQuality {
        switch status {
        case .notAvailable: return .notAvailable
        case .limited: return .limited
        case .extending: return .extending
        case .mapped: return .mapped
        @unknown default: return .notAvailable
        }
    }

    static func floats(_ m: simd_float4x4) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
         m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
         m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }
}

private extension Optional where Wrapped == Bool {
    var isTrue: Bool { self ?? false }
}
