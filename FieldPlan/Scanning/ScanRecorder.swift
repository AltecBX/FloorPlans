import Foundation
import ARKit
import CoreImage
import CoreLocation
import CoreMedia
import CoreMotion
import ImageIO
import UIKit
import FieldPlanCore

/// Records the sensor stream behind a RoomPlan scan (spec §4, §5, §17, §21).
///
/// RoomPlan keeps its own `ARSession`; this object sits on that session's
/// delegate chain — forwarding everything to whoever was there before — and
/// writes what the sensors saw: camera poses with tracking state and light,
/// depth confidence, every mesh anchor the LiDAR reconstructs, gyro, compass
/// heading, pose-tagged keyframes and positioned photos. The live quality
/// engine and coverage grid run on the same stream so advice appears while
/// the owner is still standing in the room.
///
/// Nothing here touches the AR configuration. RoomPlan configured the
/// session; the recorder only observes it. Frames are reduced to a small
/// snapshot on ARKit's delegate queue and never retained; heavy work happens
/// on a serial queue; the main actor receives a small `LiveStatus` a few
/// times a second.
final class ScanRecorder: NSObject, ObservableObject {

    /// What the scan screen shows.
    struct LiveStatus: Equatable {
        var quality = ScanQualityState()
        var meshAnchorCount = 0
        var photoCount = 0
        var keyframeCount = 0
        var floorCells: [Vec2] = []
        var wallCells: [Vec2] = []
        var path: [Vec2] = []
        var position: Vec2? = nil
        var heading: Double? = nil
        var liveWalls: [Wall] = []
        var wallCoverage: [UUID: Double] = [:]
        var observedFloorArea: Double = 0
        /// Space left, expressed as scanning time remaining (build 15 §7).
        var storage: StorageEstimate? = nil
        /// Seconds since this sensor session started.
        var elapsed: TimeInterval = 0
    }

    /// Everything a frame contributes, extracted on the delegate queue so the
    /// `ARFrame` itself is released immediately.
    private struct FrameSnapshot {
        var timestamp: TimeInterval
        var transform: [Float]
        var intrinsics: [Float]
        var imageResolution: CGSize
        var tracking: TrackingQuality
        var depthAvailable: Bool
        var depthConfidence: DepthConfidenceStats?
        var ambientIntensity: Double?
        var ambientColorTemperature: Double?
        var worldMapping: WorldMappingQuality
        /// Only set when a keyframe or photo is due.
        var image: CIImage?
        var photoCaption: String?
    }

    @Published private(set) var live = LiveStatus()

    let projectID: UUID
    let levelID: UUID?
    let sessionID: UUID
    /// The session FieldPlan owns. The recorder is its delegate and feeds it
    /// tracking and mapping state; it never re-configures the session.
    weak var spatial: SpatialSession?
    let directory: URL

    private let queue = DispatchQueue(label: "com.fieldplan.scanrecorder", qos: .userInitiated)
    private let imageQueue = DispatchQueue(label: "com.fieldplan.scanrecorder.images", qos: .utility)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Delegate-queue state (ARKit calls the delegate serially).
    private var startTimestamp: TimeInterval? = nil
    private var lastDepthStatsTime: TimeInterval = -1
    private var lastDepthStats: DepthConfidenceStats? = nil
    private var lastKeyframePosition: Vec3? = nil
    private var lastKeyframeForward: Vec3? = nil
    private var lastChunkUpdate: [UUID: TimeInterval] = [:]
    private var framesSeen = 0

    // Shared between the delegate queue and callers (photo button).
    private let requestLock = NSLock()
    private var photoRequests: [String] = []

    // Recorder-queue state.
    private var log: ScanSessionLog
    private var engine = ScanQualityEngine()
    private var lastPoseTime: TimeInterval = -1
    private var lastPublish: TimeInterval = -1
    private var lastCoverageBuild: TimeInterval = -1
    private var lastCheckpoint: TimeInterval = -1
    private var latestChunks: [UUID: MeshChunk] = [:]
    private var chunkRevisions: [UUID: Int] = [:]
    private var chunkDirty: Set<UUID> = []
    private var grid: CoverageGrid? = nil
    private var liveLevel: LevelGeometry? = nil
    private var latestWallCoverage: [UUID: Double] = [:]
    private var latestPlanHeading: Double? = nil
    private var externalInstruction: ScanAdviceKind? = nil
    private var finished = false
    private var storage: StorageEstimate? = nil
    private var lastStorageLevel: StorageEstimate.Level = .ok

    // Sensors.
    private weak var session: ARSession? = nil
    private weak var previousDelegate: ARSessionDelegate? = nil
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var location: CLLocationManager? = nil

    /// Throttles, in seconds and meters.
    private let poseInterval: TimeInterval = 0.1
    private let depthStatsInterval: TimeInterval = 0.5
    private let publishInterval: TimeInterval = 0.25
    private let coverageInterval: TimeInterval = 2.0
    private let checkpointInterval: TimeInterval = 30
    private let meshUpdateInterval: TimeInterval = 0.5
    private let keyframeDistance = 0.8
    private let keyframeAngle = 25.0 * .pi / 180
    private let keyframeLongEdge: CGFloat = 1024

    init(projectID: UUID, levelID: UUID?, directory: URL) {
        self.projectID = projectID
        self.levelID = levelID
        self.sessionID = UUID()
        self.directory = directory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        var log = ScanSessionLog(id: sessionID, levelID: levelID)
        log.device = DeviceInfo(
            model: ScanRecorder.machineModel(),
            systemVersion: UIDevice.current.systemVersion,
            appVersion: AppInfo.version,
            appBuild: AppInfo.build,
            hasLiDAR: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh))
        self.log = log
        super.init()
        motionQueue.maxConcurrentOperationCount = 1
        for sub in [ScanSessionLog.meshDirectory, ScanSessionLog.keyframeDirectory, ScanSessionLog.photoDirectory] {
            try? FileManager.default.createDirectory(
                at: self.directory.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    // MARK: - Lifecycle

    /// Joins the session's delegate chain and starts the motion and heading
    /// sensors. Safe to call once per session.
    func attach(to session: ARSession) {
        self.session = session
        if session.delegate !== self {
            previousDelegate = session.delegate
            session.delegate = self
        }
        startMotion()
        startHeading()
        record(.sessionStarted)
        AppLog.scan.info("Scan recorder attached to session \(self.sessionID.uuidString, privacy: .public)")
    }

    /// RoomPlan may install its own delegate after `run`. If no frame has
    /// reached the recorder, rejoin the chain behind the current delegate.
    func ensureAttached() {
        guard let session, !finished else { return }
        let seen = queue.sync { framesSeen }
        if seen == 0, session.delegate !== self {
            previousDelegate = session.delegate
            session.delegate = self
            record(.delegateReattached, detail: "RoomPlan replaced the ARSession delegate")
            AppLog.scan.warning("Scan recorder re-attached: no frames received after attach")
        }
    }

    /// Restores the previous delegate, stops sensors, writes everything and
    /// returns the finished log.
    @discardableResult
    func finish() -> ScanSessionLog {
        if let session, session.delegate === self {
            session.delegate = previousDelegate
        }
        motion.stopDeviceMotionUpdates()
        location?.stopUpdatingHeading()
        var result = log
        queue.sync {
            guard !finished else { result = log; return }
            finished = true
            record(.sessionEnded, now: nil)
            log.finalize()
            writeMeshes(all: true)
            writeLog()
            result = log
        }
        imageQueue.sync {}
        AppLog.scan.info("Scan recorder finished: \(result.poses.count) poses, \(result.meshes.count) meshes, \(result.photos.count) photos")
        return result
    }

    /// The coverage grid as last built during the scan.
    var coverageGrid: CoverageGrid? {
        queue.sync { grid }
    }

    /// Latest mesh chunks (one per anchor).
    var meshChunks: [MeshChunk] {
        queue.sync { Array(latestChunks.values) }
    }

    // MARK: - Inputs from the capture flow

    func record(_ kind: SessionEvent.Kind, detail: String? = nil) {
        queue.async { self.record(kind, detail: detail, now: nil) }
    }

    private func record(_ kind: SessionEvent.Kind, detail: String? = nil, now: TimeInterval?) {
        let time = now ?? currentSessionTime()
        log.events.append(SessionEvent(time: time, kind: kind, detail: detail))
    }

    func noteAcceptedRoom(_ id: UUID) {
        queue.async { self.log.roomScanIDs.append(id) }
    }

    /// RoomPlan's own coaching instruction, folded into the advice list.
    func setInstruction(_ kind: ScanAdviceKind?) {
        queue.async {
            if let previous = self.externalInstruction, previous != kind {
                self.engine.setExternal(previous, active: false, time: self.currentSessionTime())
            }
            if let kind {
                self.engine.setExternal(kind, active: true, time: self.currentSessionTime())
                self.record(.instruction, detail: kind.rawValue, now: nil)
            }
            self.externalInstruction = kind
            self.publish(force: true)
        }
    }

    /// The room RoomPlan is building right now, for live wall coverage.
    func updateLiveRoom(_ dto: ScannedRoomDTO) {
        queue.async {
            let conversion = ScanConversion.convert(rooms: [dto])
            self.liveLevel = LevelGeometry(name: "live", walls: conversion.walls, rooms: conversion.rooms)
        }
    }

    /// Takes a full-resolution photo from the next camera frame, positioned
    /// where the camera is (spec §17).
    func takePhoto(caption: String = "") {
        requestLock.lock()
        photoRequests.append(caption)
        requestLock.unlock()
    }

    // MARK: - Session time

    private func currentSessionTime() -> TimeInterval {
        guard let start = startTimestamp else { return 0 }
        return ProcessInfo.processInfo.systemUptime - start
    }

    // MARK: - Frames (delegate queue → snapshot → recorder queue)

    private func snapshot(from frame: ARFrame) -> FrameSnapshot {
        if startTimestamp == nil { startTimestamp = frame.timestamp }
        framesSeen += 1
        let now = frame.timestamp - (startTimestamp ?? frame.timestamp)
        let camera = frame.camera
        let transform = ScanRecorder.floats(camera.transform)
        let tracking = ScanRecorder.trackingQuality(camera.trackingState)

        // Depth confidence statistics, at a lower rate than frames.
        var depthAvailable = false
        if let depth = frame.sceneDepth {
            depthAvailable = true
            if now - lastDepthStatsTime >= depthStatsInterval {
                lastDepthStats = ScanRecorder.confidenceStats(depth.confidenceMap)
                lastDepthStatsTime = now
            }
        } else {
            lastDepthStats = nil
        }

        // Keyframe: enough travel or turn since the last one, under normal
        // tracking. Photo: requested by the owner.
        var image: CIImage? = nil
        var caption: String? = nil
        requestLock.lock()
        let photoRequest = photoRequests.isEmpty ? nil : photoRequests.removeFirst()
        requestLock.unlock()
        if let photoRequest {
            image = CIImage(cvPixelBuffer: frame.capturedImage)
            caption = photoRequest
        } else if tracking.isNormal {
            let pose = PoseSample(time: now, transform: transform)
            var want = false
            if let lastPosition = lastKeyframePosition, let lastForward = lastKeyframeForward {
                let moved = pose.position.distance(to: lastPosition)
                let cosine = max(-1, min(1, lastForward.normalized.dot(pose.forward.normalized)))
                want = moved >= keyframeDistance || acos(cosine) >= keyframeAngle
            } else {
                want = true
            }
            if want {
                lastKeyframePosition = pose.position
                lastKeyframeForward = pose.forward
                image = CIImage(cvPixelBuffer: frame.capturedImage)
            }
        }

        return FrameSnapshot(
            timestamp: now,
            transform: transform,
            intrinsics: ScanRecorder.floats(camera.intrinsics),
            imageResolution: camera.imageResolution,
            tracking: tracking,
            depthAvailable: depthAvailable,
            depthConfidence: depthAvailable ? lastDepthStats : nil,
            ambientIntensity: frame.lightEstimate.map { Double($0.ambientIntensity) },
            ambientColorTemperature: frame.lightEstimate.map { Double($0.ambientColorTemperature) },
            worldMapping: ScanRecorder.mappingQuality(frame.worldMappingStatus),
            image: image,
            photoCaption: caption)
    }

    private func handle(_ snapshot: FrameSnapshot) {
        if finished { return }
        let now = snapshot.timestamp
        if log.device?.sceneReconstruction == nil,
           let configuration = session?.configuration as? ARWorldTrackingConfiguration {
            log.device?.sceneReconstruction = String(describing: configuration.sceneReconstruction)
            log.device?.sceneDepthEnabled = configuration.frameSemantics.contains(.sceneDepth)
        }

        let pose = PoseSample(
            time: now,
            transform: snapshot.transform,
            tracking: snapshot.tracking,
            depthAvailable: snapshot.depthAvailable,
            depthConfidence: snapshot.depthConfidence,
            ambientIntensity: snapshot.ambientIntensity,
            ambientColorTemperature: snapshot.ambientColorTemperature,
            worldMapping: snapshot.worldMapping)
        latestPlanHeading = pose.planHeading

        if now - lastPoseTime >= poseInterval {
            lastPoseTime = now
            log.poses.append(pose)
            engine.ingest(pose)
            // The session that owns the world map needs to know when tracking
            // recovers, so a resume can be verified the moment it does.
            let tracking = snapshot.tracking
            let mapping = snapshot.worldMapping
            DispatchQueue.main.async { [weak self] in
                self?.spatial?.update(tracking: tracking, mapping: mapping)
            }
        }

        if let image = snapshot.image {
            if let caption = snapshot.photoCaption {
                encodePhoto(image, pose: pose, caption: caption)
            } else {
                encodeKeyframe(image, snapshot: snapshot)
            }
        }

        if now - lastCoverageBuild >= coverageInterval {
            lastCoverageBuild = now
            rebuildCoverage(now: now)
        }
        if now - lastCheckpoint >= checkpointInterval {
            lastCheckpoint = now
            writeMeshes(all: false)
            writeLog()
            measureStorage(elapsed: now)
        }
        publish(force: false, now: now)
    }

    private func rebuildCoverage(now: TimeInterval) {
        let chunks = Array(latestChunks.values)
        guard !chunks.isEmpty || !log.poses.isEmpty else { return }
        grid = CoverageGrid.build(chunks: chunks, poses: log.poses)
        if let level = liveLevel, let grid {
            let report = CoverageAdvisor.report(level: level, grid: grid)
            // Only nag about coverage once the room has had a chance to be
            // walked: a wall seen for the first time is not "not covered".
            let matured = now > 20
            engine.setCoverageAdvice(matured ? report.advice : [], time: now)
            latestWallCoverage = report.wallCoverage.mapValues(\.fraction)
        }
        publish(force: true, now: now)
    }

    private func publish(force: Bool, now: TimeInterval? = nil) {
        let time = now ?? currentSessionTime()
        guard force || time - lastPublish >= publishInterval else { return }
        lastPublish = time
        var status = LiveStatus()
        status.quality = engine.state
        status.meshAnchorCount = latestChunks.count
        status.photoCount = log.photos.count
        status.keyframeCount = log.keyframes.count
        if let grid {
            status.floorCells = grid.observedFloorCells()
            status.wallCells = grid.observedWallCells()
            status.observedFloorArea = grid.observedFloorArea
        }
        let step = max(1, log.poses.count / 400)
        status.path = stride(from: 0, to: log.poses.count, by: step).map { log.poses[$0].planPosition }
        status.position = log.poses.last?.planPosition
        status.heading = log.poses.last?.planHeading
        status.liveWalls = liveLevel?.walls ?? []
        status.wallCoverage = latestWallCoverage
        status.storage = storage
        status.elapsed = time
        DispatchQueue.main.async { [weak self] in
            self?.live = status
        }
    }

    // MARK: - Storage (build 15, priority 7)

    /// How much room is left, in minutes of scanning rather than gigabytes —
    /// a number that means something while walking a house. Measured on the
    /// recorder queue at the checkpoint interval, because it walks the
    /// session directory.
    private func measureStorage(elapsed: TimeInterval) {
        let bytes = ScanRecorder.directorySize(directory)
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
        let estimate = StorageEstimate.estimate(
            sessionBytes: bytes,
            elapsedSeconds: elapsed,
            freeBytes: free ?? 0)
        storage = estimate
        // Say it once per level change, not every 30 seconds.
        if estimate.level != lastStorageLevel {
            lastStorageLevel = estimate.level
            if estimate.level != .ok {
                record(.storageWarning, detail: estimate.message, now: elapsed)
            }
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Images

    private func encodeKeyframe(_ image: CIImage, snapshot: FrameSnapshot) {
        let fileName = String(format: "kf-%06.2f.jpg", snapshot.timestamp)
        let longEdge = max(image.extent.width, image.extent.height)
        let scale = min(1, keyframeLongEdge / max(longEdge, 1))
        let url = directory.appendingPathComponent(ScanSessionLog.keyframeDirectory).appendingPathComponent(fileName)
        imageQueue.async { [ciContext] in
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).oriented(.right)
            ScanRecorder.writeJPEG(scaled, to: url, quality: 0.72, context: ciContext)
        }
        log.keyframes.append(KeyframeRecord(
            time: snapshot.timestamp, fileName: fileName, transform: snapshot.transform,
            intrinsics: snapshot.intrinsics,
            imageWidth: Int(snapshot.imageResolution.width * scale),
            imageHeight: Int(snapshot.imageResolution.height * scale),
            tracking: snapshot.tracking))
    }

    private func encodePhoto(_ image: CIImage, pose: PoseSample, caption: String) {
        let photo = PositionedPhotoRecord(
            time: pose.time,
            fileName: "photo-\(log.photos.count + 1).jpg",
            transform: pose.transform,
            planPosition: pose.planPosition,
            planHeading: pose.planHeading ?? latestPlanHeading ?? 0,
            levelID: levelID,
            caption: caption)
        let url = directory.appendingPathComponent(ScanSessionLog.photoDirectory).appendingPathComponent(photo.fileName)
        let oriented = image.oriented(.right)
        imageQueue.async { [ciContext] in
            ScanRecorder.writeJPEG(oriented, to: url, quality: 0.9, context: ciContext)
        }
        log.photos.append(photo)
        record(.photoTaken, detail: photo.fileName, now: pose.time)
        publish(force: true, now: pose.time)
    }

    private static func writeJPEG(_ image: CIImage, to url: URL, quality: CGFloat, context: CIContext) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            AppLog.scan.error("JPEG encoding failed for \(url.lastPathComponent, privacy: .public)")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.scan.error("Keyframe write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Meshes

    /// Copies updated anchors on the delegate queue (buffers are only valid
    /// there) and hands the plain chunks to the recorder queue.
    private func handle(meshAnchors: [ARMeshAnchor], removed: Bool) {
        let now = currentSessionTime()
        var chunks: [MeshChunk] = []
        var removedIDs: [UUID] = []
        for anchor in meshAnchors {
            if removed {
                lastChunkUpdate[anchor.identifier] = nil
                removedIDs.append(anchor.identifier)
                continue
            }
            if let last = lastChunkUpdate[anchor.identifier], now - last < meshUpdateInterval { continue }
            lastChunkUpdate[anchor.identifier] = now
            chunks.append(ScanRecorder.chunk(from: anchor))
        }
        guard !chunks.isEmpty || !removedIDs.isEmpty else { return }
        queue.async {
            guard !self.finished else { return }
            for id in removedIDs {
                self.latestChunks[id] = nil
                self.chunkDirty.insert(id)
            }
            for chunk in chunks {
                self.latestChunks[chunk.anchorID] = chunk
                self.chunkRevisions[chunk.anchorID, default: 0] += 1
                self.chunkDirty.insert(chunk.anchorID)
            }
        }
    }

    /// Copies an anchor's geometry out of Metal buffers into plain arrays.
    private static func chunk(from anchor: ARMeshAnchor) -> MeshChunk {
        let geometry = anchor.geometry
        let source = geometry.vertices
        var vertices = [Float]()
        vertices.reserveCapacity(source.count * 3)
        let base = source.buffer.contents().advanced(by: source.offset)
        for i in 0..<source.count {
            let pointer = base.advanced(by: i * source.stride).assumingMemoryBound(to: Float.self)
            vertices.append(pointer[0])
            vertices.append(pointer[1])
            vertices.append(pointer[2])
        }

        let element = geometry.faces
        var faces = [UInt32]()
        let indexCount = element.count * element.indexCountPerPrimitive
        faces.reserveCapacity(indexCount)
        let facesBase = element.buffer.contents()
        for i in 0..<indexCount {
            if element.bytesPerIndex == 4 {
                faces.append(facesBase.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee)
            } else {
                faces.append(UInt32(facesBase.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee))
            }
        }

        var classification: [UInt8]? = nil
        if let classSource = geometry.classification {
            var values = [UInt8]()
            values.reserveCapacity(classSource.count)
            let classBase = classSource.buffer.contents().advanced(by: classSource.offset)
            for i in 0..<classSource.count {
                values.append(classBase.advanced(by: i * classSource.stride).assumingMemoryBound(to: UInt8.self).pointee)
            }
            classification = values
        }

        return MeshChunk(anchorID: anchor.identifier,
                         transform: floats(anchor.transform),
                         vertices: vertices, faces: faces, classification: classification)
    }

    private func writeMeshes(all: Bool) {
        let ids = all ? Set(latestChunks.keys).union(chunkDirty) : chunkDirty
        let meshDir = directory.appendingPathComponent(ScanSessionLog.meshDirectory, isDirectory: true)
        let now = currentSessionTime()
        for id in ids {
            let fileName = "\(id.uuidString).\(ScanSessionLog.meshFileExtension)"
            let url = meshDir.appendingPathComponent(fileName)
            guard let chunk = latestChunks[id] else {
                try? FileManager.default.removeItem(at: url)
                log.meshes.removeAll { $0.anchorID == id }
                continue
            }
            do {
                try MeshChunkCodec.encode(chunk).write(to: url, options: .atomic)
                let summary = chunk.summary(fileName: fileName, revision: chunkRevisions[id] ?? 1, updatedAt: now)
                if let index = log.meshes.firstIndex(where: { $0.anchorID == id }) {
                    log.meshes[index] = summary
                } else {
                    log.meshes.append(summary)
                }
            } catch {
                AppLog.scan.error("Mesh write failed: \(error.localizedDescription)")
            }
        }
        chunkDirty.removeAll()
    }

    private func writeLog() {
        do {
            let data = try ProjectArchive.encoder().encode(log)
            try data.write(to: directory.appendingPathComponent(ScanSessionLog.fileName), options: .atomic)
        } catch {
            AppLog.scan.error("Session log write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Motion and heading

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.queue.async {
                guard !self.finished, let start = self.startTimestamp else { return }
                let sample = MotionSample(
                    time: data.timestamp - start,
                    gravity: Vec3(data.gravity.x, data.gravity.y, data.gravity.z),
                    rotationRate: Vec3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z),
                    userAcceleration: Vec3(data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z))
                self.log.motion.append(sample)
                self.engine.ingest(motion: sample)
            }
        }
    }

    private func startHeading() {
        guard location == nil, CLLocationManager.headingAvailable() else { return }
        let manager = CLLocationManager()
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        manager.delegate = self
        manager.headingFilter = 2
        manager.startUpdatingHeading()
        location = manager
    }

    // MARK: - Conversions

    static func floats(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    static func floats(_ m: simd_float3x3) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z,
            m.columns.1.x, m.columns.1.y, m.columns.1.z,
            m.columns.2.x, m.columns.2.y, m.columns.2.z,
        ]
    }

    static func trackingQuality(_ state: ARCamera.TrackingState) -> TrackingQuality {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .initializing
            case .excessiveMotion: return .excessiveMotion
            case .insufficientFeatures: return .insufficientFeatures
            case .relocalizing: return .relocalizing
            @unknown default: return .insufficientFeatures
            }
        }
    }

    static func mappingQuality(_ status: ARFrame.WorldMappingStatus) -> WorldMappingQuality {
        switch status {
        case .notAvailable: return .notAvailable
        case .limited: return .limited
        case .extending: return .extending
        case .mapped: return .mapped
        @unknown default: return .limited
        }
    }

    /// Shares of low/medium/high confidence, sampling every 8th pixel.
    static func confidenceStats(_ map: CVPixelBuffer?) -> DepthConfidenceStats? {
        guard let map else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        var counts = [0, 0, 0]
        var y = 0
        while y < height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < width {
                let value = Int(row[x])
                if value < 3 { counts[value] += 1 }
                x += 8
            }
            y += 8
        }
        let total = Double(counts.reduce(0, +))
        guard total > 0 else { return nil }
        return DepthConfidenceStats(high: Double(counts[2]) / total,
                                    medium: Double(counts[1]) / total,
                                    low: Double(counts[0]) / total)
    }

    static func machineModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

// MARK: - ARSessionDelegate (forwarding)

extension ScanRecorder: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        previousDelegate?.session?(session, didUpdate: frame)
        let snapshot = snapshot(from: frame)
        queue.async { self.handle(snapshot) }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        previousDelegate?.session?(session, didAdd: anchors)
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        if !meshes.isEmpty { handle(meshAnchors: meshes, removed: false) }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        previousDelegate?.session?(session, didUpdate: anchors)
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        if !meshes.isEmpty { handle(meshAnchors: meshes, removed: false) }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        previousDelegate?.session?(session, didRemove: anchors)
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        if !meshes.isEmpty { handle(meshAnchors: meshes, removed: true) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        previousDelegate?.session?(session, didFailWithError: error)
        record(.warning, detail: "session error: \(error.localizedDescription)")
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        previousDelegate?.session?(session, cameraDidChangeTrackingState: camera)
        let quality = ScanRecorder.trackingQuality(camera.trackingState)
        record(.trackingChanged, detail: quality.rawValue)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        previousDelegate?.sessionWasInterrupted?(session)
        queue.async {
            self.record(.interrupted, now: nil)
            self.engine.setExternal(.holdSteady, active: true, time: self.currentSessionTime())
            self.publish(force: true)
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        previousDelegate?.sessionInterruptionEnded?(session)
        queue.async {
            self.record(.interruptionEnded, now: nil)
            self.record(.relocalized, now: nil)
            self.engine.setExternal(.holdSteady, active: false, time: self.currentSessionTime())
            self.publish(force: true)
        }
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        previousDelegate?.sessionShouldAttemptRelocalization?(session) ?? true
    }

    func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        previousDelegate?.session?(session, didOutputAudioSampleBuffer: audioSampleBuffer)
    }

    func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
        previousDelegate?.session?(session, didOutputCollaborationData: data)
    }
}

// MARK: - Heading

extension ScanRecorder: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let magnetic = newHeading.magneticHeading
        let trueHeading: Double? = newHeading.trueHeading >= 0 ? newHeading.trueHeading : nil
        let accuracy = newHeading.headingAccuracy
        queue.async {
            guard !self.finished else { return }
            self.log.headings.append(HeadingSample(
                time: self.currentSessionTime(),
                magneticHeading: magnetic,
                trueHeading: trueHeading,
                accuracy: accuracy,
                cameraPlanHeading: self.latestPlanHeading))
        }
    }
}
