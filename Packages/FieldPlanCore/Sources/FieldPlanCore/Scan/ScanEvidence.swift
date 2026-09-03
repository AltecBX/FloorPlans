import Foundation

// MARK: - Sensor observation log (spec §4, §21)
//
// What the scanner actually saw, kept separately from what RoomPlan made of
// it. A session log is written by the app's ScanRecorder while the ARSession
// runs; everything here is Foundation-only so a future reconstruction pass —
// or a Mac tool — can read old sessions without the property.
//
// Coordinates are ARKit world space (meters, +Y up). Plan projection follows
// `Vec3.planProjection`: plan X = world X, plan Y = -world Z.

/// ARKit's camera tracking state, flattened for logging and quality checks.
public enum TrackingQuality: String, Codable, Sendable, CaseIterable {
    case normal
    case initializing
    case excessiveMotion
    case insufficientFeatures
    case relocalizing
    case notAvailable

    public var isNormal: Bool { self == .normal }

    public var displayName: String {
        switch self {
        case .normal: return "Tracking normal"
        case .initializing: return "Initializing"
        case .excessiveMotion: return "Moving too fast"
        case .insufficientFeatures: return "Not enough visual detail"
        case .relocalizing: return "Relocating"
        case .notAvailable: return "Tracking unavailable"
        }
    }
}

/// ARKit's world-mapping status.
public enum WorldMappingQuality: String, Codable, Sendable, CaseIterable {
    case notAvailable, limited, extending, mapped
}

/// Share of a depth frame's pixels at each LiDAR confidence level.
public struct DepthConfidenceStats: Codable, Hashable, Sendable {
    public var high: Double
    public var medium: Double
    public var low: Double

    public init(high: Double, medium: Double, low: Double) {
        self.high = high
        self.medium = medium
        self.low = low
    }
}

/// One camera pose with the per-frame signals that matter for quality.
public struct PoseSample: Codable, Hashable, Sendable {
    /// Seconds since the session started.
    public var time: Double
    /// Camera-to-world transform, 16 floats column-major (ARKit convention).
    public var transform: [Float]
    public var tracking: TrackingQuality
    public var depthAvailable: Bool
    public var depthConfidence: DepthConfidenceStats?
    /// ARKit ambient intensity estimate (1000 ≈ well lit).
    public var ambientIntensity: Double?
    public var ambientColorTemperature: Double?
    public var worldMapping: WorldMappingQuality?

    public init(
        time: Double,
        transform: [Float],
        tracking: TrackingQuality = .normal,
        depthAvailable: Bool = false,
        depthConfidence: DepthConfidenceStats? = nil,
        ambientIntensity: Double? = nil,
        ambientColorTemperature: Double? = nil,
        worldMapping: WorldMappingQuality? = nil
    ) {
        self.time = time
        self.transform = transform.count == 16 ? transform : PoseSample.identity
        self.tracking = tracking
        self.depthAvailable = depthAvailable
        self.depthConfidence = depthConfidence
        self.ambientIntensity = ambientIntensity
        self.ambientColorTemperature = ambientColorTemperature
        self.worldMapping = worldMapping
    }

    public static let identity: [Float] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ]

    /// Camera-to-world transform for a camera at `position` looking along the
    /// plan direction `yaw` (radians, plan convention), tilted down by `pitch`.
    /// Used by tests and by tools that synthesise a walk.
    public static func transform(position: Vec3, yaw: Double, pitch: Double = 0) -> [Float] {
        // Plan forward (cos, sin) is world (cos, 0, -sin).
        let forward = Vec3(cos(yaw) * cos(pitch), -sin(pitch), -sin(yaw) * cos(pitch)).normalized
        let worldUp = Vec3(0, 1, 0)
        var right = forward.cross(worldUp)
        if right.length < 1e-6 { right = Vec3(1, 0, 0) }
        right = right.normalized
        let up = right.cross(forward).normalized
        let back = forward * -1
        return [
            Float(right.x), Float(right.y), Float(right.z), 0,
            Float(up.x), Float(up.y), Float(up.z), 0,
            Float(back.x), Float(back.y), Float(back.z), 0,
            Float(position.x), Float(position.y), Float(position.z), 1,
        ]
    }

    public var position: Vec3 {
        Vec3(Double(transform[12]), Double(transform[13]), Double(transform[14]))
    }

    /// Where the camera looks: its local -Z axis in world space.
    public var forward: Vec3 {
        Vec3(-Double(transform[8]), -Double(transform[9]), -Double(transform[10]))
    }

    public var up: Vec3 {
        Vec3(Double(transform[4]), Double(transform[5]), Double(transform[6]))
    }

    public var planPosition: Vec2 { position.planProjection }

    /// Plan direction the camera faces, or nil when it looks nearly straight
    /// up or down.
    public var planHeading: Double? {
        let f = forward.planProjection
        return f.length > 0.2 ? f.angle : nil
    }
}

/// CoreMotion sample.
public struct MotionSample: Codable, Hashable, Sendable {
    public var time: Double
    public var gravity: Vec3
    /// Radians per second about the device axes.
    public var rotationRate: Vec3
    /// In g, gravity removed.
    public var userAcceleration: Vec3

    public init(time: Double, gravity: Vec3, rotationRate: Vec3, userAcceleration: Vec3) {
        self.time = time
        self.gravity = gravity
        self.rotationRate = rotationRate
        self.userAcceleration = userAcceleration
    }

    public var rotationSpeedDegrees: Double { rotationRate.length * 180 / .pi }
}

/// Compass sample paired with the camera's plan heading at that instant, so
/// north can be placed on the plan (`NorthEstimator`).
public struct HeadingSample: Codable, Hashable, Sendable {
    public var time: Double
    /// Degrees clockwise from magnetic north to the device's pointing direction.
    public var magneticHeading: Double
    /// Degrees clockwise from true north, when the location service knows it.
    public var trueHeading: Double?
    /// Reported accuracy in degrees; negative means invalid.
    public var accuracy: Double
    /// Plan angle (radians) the camera faced when the heading was read.
    public var cameraPlanHeading: Double?

    public init(time: Double, magneticHeading: Double, trueHeading: Double? = nil,
                accuracy: Double, cameraPlanHeading: Double? = nil) {
        self.time = time
        self.magneticHeading = magneticHeading
        self.trueHeading = trueHeading
        self.accuracy = accuracy
        self.cameraPlanHeading = cameraPlanHeading
    }

    /// The heading to trust: true when available and valid, else magnetic.
    public var bestHeading: Double? {
        guard accuracy >= 0 else { return nil }
        if let trueHeading, trueHeading >= 0 { return trueHeading }
        return magneticHeading >= 0 ? magneticHeading : nil
    }
}

/// A pose-tagged reduced-resolution camera frame kept for evidence.
public struct KeyframeRecord: Codable, Hashable, Sendable {
    public var time: Double
    public var fileName: String
    public var transform: [Float]
    /// 3×3 intrinsics column-major: fx = [0], fy = [4], cx = [6], cy = [7].
    public var intrinsics: [Float]
    public var imageWidth: Int
    public var imageHeight: Int
    public var tracking: TrackingQuality

    public init(time: Double, fileName: String, transform: [Float], intrinsics: [Float],
                imageWidth: Int, imageHeight: Int, tracking: TrackingQuality) {
        self.time = time
        self.fileName = fileName
        self.transform = transform
        self.intrinsics = intrinsics
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.tracking = tracking
    }
}

/// A full-resolution photo taken during the scan, with where it was taken
/// from and which way it looked (spec §17).
public struct PositionedPhotoRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var time: Double
    public var fileName: String
    public var transform: [Float]
    public var planPosition: Vec2
    /// Plan angle (radians) of the camera's view direction.
    public var planHeading: Double
    public var levelID: UUID?
    public var roomID: UUID?
    public var caption: String

    public init(id: UUID = UUID(), time: Double, fileName: String, transform: [Float],
                planPosition: Vec2, planHeading: Double, levelID: UUID? = nil,
                roomID: UUID? = nil, caption: String = "") {
        self.id = id
        self.time = time
        self.fileName = fileName
        self.transform = transform
        self.planPosition = planPosition
        self.planHeading = planHeading
        self.levelID = levelID
        self.roomID = roomID
        self.caption = caption
    }
}

/// Something that happened during the session.
public struct SessionEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case sessionStarted, sessionEnded
        case roomStarted, roomFinished, roomDiscarded
        case interrupted, interruptionEnded, relocalized
        case trackingChanged, instruction, warning, photoTaken
        // Build 15: what a field visit needs to explain a bad scan later.
        case checkpoint, worldMapSaved, relocalizationFailed
        case storageWarning, thermalWarning, delegateReattached
    }

    public var time: Double
    public var kind: Kind
    public var detail: String?

    public init(time: Double, kind: Kind, detail: String? = nil) {
        self.time = time
        self.kind = kind
        self.detail = detail
    }
}

/// Index entry for one mesh anchor's binary chunk.
public struct MeshChunkSummary: Codable, Hashable, Identifiable, Sendable {
    public var anchorID: UUID
    public var fileName: String
    public var revision: Int
    public var updatedAt: Double
    public var vertexCount: Int
    public var faceCount: Int
    public var boundsMin: Vec3?
    public var boundsMax: Vec3?
    /// Face counts per `MeshFaceClass` raw value (8 buckets).
    public var classificationCounts: [Int]

    public var id: UUID { anchorID }

    public init(anchorID: UUID, fileName: String, revision: Int, updatedAt: Double,
                vertexCount: Int, faceCount: Int, boundsMin: Vec3? = nil, boundsMax: Vec3? = nil,
                classificationCounts: [Int] = Array(repeating: 0, count: 8)) {
        self.anchorID = anchorID
        self.fileName = fileName
        self.revision = revision
        self.updatedAt = updatedAt
        self.vertexCount = vertexCount
        self.faceCount = faceCount
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.classificationCounts = classificationCounts
    }
}

public struct DeviceInfo: Codable, Hashable, Sendable {
    public var model: String
    public var systemVersion: String
    public var appVersion: String
    public var appBuild: String
    public var hasLiDAR: Bool
    /// The scene reconstruction the AR configuration reported, if readable.
    public var sceneReconstruction: String?
    public var sceneDepthEnabled: Bool?

    public init(model: String, systemVersion: String, appVersion: String, appBuild: String,
                hasLiDAR: Bool, sceneReconstruction: String? = nil, sceneDepthEnabled: Bool? = nil) {
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.hasLiDAR = hasLiDAR
        self.sceneReconstruction = sceneReconstruction
        self.sceneDepthEnabled = sceneDepthEnabled
    }
}

/// Computed once at the end of a session.
public struct SessionSummary: Codable, Hashable, Sendable {
    public var duration: Double
    public var distanceWalked: Double
    public var meanSpeed: Double
    public var maxSpeed: Double
    public var trackingNormalFraction: Double
    public var depthAvailableFraction: Double
    public var meanDepthHighConfidence: Double?
    public var meshVertexTotal: Int
    public var meshFaceTotal: Int
    public var poseCount: Int
    public var keyframeCount: Int
    public var photoCount: Int

    public init(duration: Double = 0, distanceWalked: Double = 0, meanSpeed: Double = 0,
                maxSpeed: Double = 0, trackingNormalFraction: Double = 0,
                depthAvailableFraction: Double = 0, meanDepthHighConfidence: Double? = nil,
                meshVertexTotal: Int = 0, meshFaceTotal: Int = 0, poseCount: Int = 0,
                keyframeCount: Int = 0, photoCount: Int = 0) {
        self.duration = duration
        self.distanceWalked = distanceWalked
        self.meanSpeed = meanSpeed
        self.maxSpeed = maxSpeed
        self.trackingNormalFraction = trackingNormalFraction
        self.depthAvailableFraction = depthAvailableFraction
        self.meanDepthHighConfidence = meanDepthHighConfidence
        self.meshVertexTotal = meshVertexTotal
        self.meshFaceTotal = meshFaceTotal
        self.poseCount = poseCount
        self.keyframeCount = keyframeCount
        self.photoCount = photoCount
    }
}

/// The complete record of one scanning session (one continuous ARSession).
public struct ScanSessionLog: Codable, Hashable, Identifiable, Sendable {
    public static let fileName = "session.json"
    public static let meshDirectory = "meshes"
    public static let keyframeDirectory = "keyframes"
    public static let photoDirectory = "photos"
    public static let meshFileExtension = "fpmesh"

    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var device: DeviceInfo?
    /// RoomPlan capture identifiers accepted during this session, in order.
    public var roomScanIDs: [UUID]
    public var levelID: UUID?
    public var poses: [PoseSample]
    public var motion: [MotionSample]
    public var headings: [HeadingSample]
    public var keyframes: [KeyframeRecord]
    public var photos: [PositionedPhotoRecord]
    public var meshes: [MeshChunkSummary]
    public var events: [SessionEvent]
    public var summary: SessionSummary?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        device: DeviceInfo? = nil,
        roomScanIDs: [UUID] = [],
        levelID: UUID? = nil,
        poses: [PoseSample] = [],
        motion: [MotionSample] = [],
        headings: [HeadingSample] = [],
        keyframes: [KeyframeRecord] = [],
        photos: [PositionedPhotoRecord] = [],
        meshes: [MeshChunkSummary] = [],
        events: [SessionEvent] = [],
        summary: SessionSummary? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.device = device
        self.roomScanIDs = roomScanIDs
        self.levelID = levelID
        self.poses = poses
        self.motion = motion
        self.headings = headings
        self.keyframes = keyframes
        self.photos = photos
        self.meshes = meshes
        self.events = events
        self.summary = summary
    }

    /// Distance walked, ignoring jumps larger than `jumpLimit` (relocalisation
    /// or tracking resets, not walking).
    public func distanceWalked(jumpLimit: Double = 2.0) -> Double {
        var total = 0.0
        for i in 1..<max(poses.count, 1) {
            let d = poses[i].position.distance(to: poses[i - 1].position)
            if d < jumpLimit { total += d }
        }
        return total
    }

    /// Fills in `summary` from the streams.
    public mutating func finalize(endedAt end: Date = Date()) {
        endedAt = end
        summary = computeSummary()
    }

    public func computeSummary() -> SessionSummary {
        var s = SessionSummary()
        s.poseCount = poses.count
        s.keyframeCount = keyframes.count
        s.photoCount = photos.count
        s.meshVertexTotal = meshes.reduce(0) { $0 + $1.vertexCount }
        s.meshFaceTotal = meshes.reduce(0) { $0 + $1.faceCount }
        s.duration = max((endedAt ?? Date()).timeIntervalSince(startedAt), poses.last?.time ?? 0)
        s.distanceWalked = distanceWalked()
        guard !poses.isEmpty else { return s }

        s.trackingNormalFraction = Double(poses.filter { $0.tracking.isNormal }.count) / Double(poses.count)
        s.depthAvailableFraction = Double(poses.filter(\.depthAvailable).count) / Double(poses.count)
        let highs = poses.compactMap { $0.depthConfidence?.high }
        if !highs.isEmpty { s.meanDepthHighConfidence = highs.reduce(0, +) / Double(highs.count) }

        // Speeds over one-second windows so a single noisy pose does not set
        // the maximum.
        var windowStart = 0
        var maxSpeed = 0.0
        for i in poses.indices {
            while poses[i].time - poses[windowStart].time > 1.0 { windowStart += 1 }
            let dt = poses[i].time - poses[windowStart].time
            if dt >= 0.5 {
                let d = poses[i].position.distance(to: poses[windowStart].position)
                if d < 2.0 { maxSpeed = max(maxSpeed, d / dt) }
            }
        }
        s.maxSpeed = maxSpeed
        let elapsed = max(poses.last!.time - poses.first!.time, 1e-6)
        s.meanSpeed = s.distanceWalked / elapsed
        return s
    }
}

// MARK: - North from the compass

public enum NorthEstimator {
    /// Plan angle of north relative to +Y (`LevelGeometry.northAngle`),
    /// estimated from heading samples paired with the camera's plan heading.
    ///
    /// A heading is the clockwise angle from north to the direction the device
    /// points, so on the plan (counter-clockwise positive) the camera's plan
    /// heading equals north minus the heading. Samples are weighted by their
    /// reported accuracy and averaged on the circle. Returns nil when fewer
    /// than `minimumSamples` usable samples exist.
    public static func northAngle(from samples: [HeadingSample], minimumSamples: Int = 5) -> Double? {
        var sumX = 0.0
        var sumY = 0.0
        var count = 0
        for sample in samples {
            guard let heading = sample.bestHeading, let camera = sample.cameraPlanHeading else { continue }
            let northPlanAngle = camera + heading * .pi / 180
            let weight = 1.0 / max(sample.accuracy, 1.0)
            sumX += cos(northPlanAngle) * weight
            sumY += sin(northPlanAngle) * weight
            count += 1
        }
        guard count >= minimumSamples, (sumX * sumX + sumY * sumY) > 1e-12 else { return nil }
        let northPlanAngle = atan2(sumY, sumX)
        return GeometryAngle.normalize(northPlanAngle - .pi / 2)
    }
}
