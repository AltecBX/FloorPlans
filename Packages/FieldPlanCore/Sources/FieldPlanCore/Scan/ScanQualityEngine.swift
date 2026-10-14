import Foundation

// MARK: - Live scan quality (spec §5)
//
// A pure state machine: poses (and optionally gyro samples) go in, a
// prioritised list of advice comes out. Every condition has an enter and an
// exit threshold, a minimum duration before it is shown and a minimum time it
// stays shown, so the chip on screen does not flicker with every frame. The
// thresholds are constants so field testing can tune them in one place.

public struct ScanQualityThresholds: Sendable {
    /// Walking faster than this earns "slow down"; below `speedExit` clears it.
    public var speedEnter = 1.4
    public var speedExit = 1.0
    /// Degrees per second of camera rotation.
    public var angularEnter = 110.0
    public var angularExit = 70.0
    /// ARKit ambient intensity (≈1000 is a well-lit room).
    public var lowLightEnter = 300.0
    public var lowLightExit = 450.0
    /// Share of depth pixels at high confidence.
    public var depthLowEnter = 0.35
    public var depthLowExit = 0.55
    /// Seconds a condition must hold before it is shown, and stays shown.
    public var minimumConditionDuration = 0.5
    public var minimumDisplayDuration = 2.0
    /// Seconds of pose history used to estimate speed and rotation.
    public var smoothingWindow = 0.6

    public init() {}
}

public enum ScanAdviceKind: String, Codable, CaseIterable, Sendable {
    case trackingNotAvailable
    case trackingInitializing
    case trackingRelocalizing
    case excessiveMotion
    case insufficientFeatures
    case slowDown
    case turnSlowly
    case lowLight
    case lowDepthConfidence
    case moveCloser
    case moveAway
    case lowTexture
    case holdSteady
    case wallNotCovered
    case cornerNotCovered
    case openingNotCovered
    case possibleMissingWall

    /// Lower is more urgent.
    public var priority: Int {
        switch self {
        case .trackingNotAvailable: return 0
        case .trackingRelocalizing: return 1
        case .trackingInitializing: return 1
        case .holdSteady: return 1
        case .excessiveMotion: return 2
        case .insufficientFeatures: return 2
        case .lowLight: return 3
        case .slowDown: return 4
        case .turnSlowly: return 4
        case .lowDepthConfidence: return 5
        case .moveCloser: return 6
        case .moveAway: return 6
        case .lowTexture: return 6
        case .possibleMissingWall: return 7
        case .wallNotCovered: return 8
        case .openingNotCovered: return 8
        case .cornerNotCovered: return 9
        }
    }

    public var message: String {
        switch self {
        case .trackingNotAvailable: return "Tracking unavailable — hold still with the walls in view"
        case .trackingInitializing: return "Starting tracking — hold steady a moment"
        case .trackingRelocalizing: return "Relocating — look at a part of the room you already scanned"
        case .excessiveMotion: return "Moving too fast for tracking"
        case .insufficientFeatures: return "Not enough detail here — step back so doorways or furniture are in view"
        case .slowDown: return "Slow down"
        case .turnSlowly: return "Turn slowly"
        case .lowLight: return "Too dark — turn on the lights"
        case .lowDepthConfidence: return "Low LiDAR confidence — avoid glass and mirrors, keep 5–10 ft from walls"
        case .moveCloser: return "Move closer to the wall"
        case .moveAway: return "Move farther from the wall"
        case .lowTexture: return "Low detail — scan surrounding features"
        case .holdSteady: return "Interrupted — return to where you were and hold steady"
        case .wallNotCovered: return "Wall not fully captured — walk along it"
        case .cornerNotCovered: return "Scan this corner again"
        case .openingNotCovered: return "Doorway or window needs another pass"
        case .possibleMissingWall: return "Possible missing wall — look along the gap"
        }
    }

    /// Conditions read straight from a state, shown without delay.
    var isImmediate: Bool {
        switch self {
        case .trackingNotAvailable, .trackingRelocalizing, .trackingInitializing, .holdSteady:
            return true
        default:
            return false
        }
    }
}

public struct ScanAdvice: Hashable, Identifiable, Sendable {
    public var kind: ScanAdviceKind
    public var since: Double

    public var id: ScanAdviceKind { kind }
    public var message: String { kind.message }
    public var priority: Int { kind.priority }

    public init(kind: ScanAdviceKind, since: Double) {
        self.kind = kind
        self.since = since
    }
}

public enum OverallScanQuality: String, Sendable {
    case good, caution, poor
}

public struct ScanQualityState: Hashable, Sendable {
    public var elapsed: Double = 0
    public var speed: Double = 0
    public var angularSpeed: Double = 0
    public var tracking: TrackingQuality = .notAvailable
    public var ambientIntensity: Double? = nil
    public var depthHighFraction: Double? = nil
    public var depthAvailable = false
    public var distanceWalked: Double = 0
    /// Active advice, most urgent first.
    public var advice: [ScanAdvice] = []

    public init() {}

    public var primaryAdvice: ScanAdvice? { advice.first }

    public var overall: OverallScanQuality {
        if advice.contains(where: { $0.priority <= 2 }) { return .poor }
        if !advice.isEmpty { return .caution }
        return .good
    }
}

public struct ScanQualityEngine: Sendable {
    public var thresholds: ScanQualityThresholds
    public private(set) var state = ScanQualityState()

    private struct Recent {
        var time: Double
        var position: Vec3
        var forward: Vec3
    }

    private var recent: [Recent] = []
    private var lastPosition: Vec3? = nil
    private var gyroAngular: Double? = nil
    private var gyroTime: Double = -1
    /// Time a condition first held continuously.
    private var conditionSince: [ScanAdviceKind: Double] = [:]
    /// Time a condition last held.
    private var lastTrue: [ScanAdviceKind: Double] = [:]
    /// Time each shown advice became active.
    private var activeSince: [ScanAdviceKind: Double] = [:]
    /// Advice controlled from outside (RoomPlan instructions, coverage).
    private var external: Set<ScanAdviceKind> = []
    private var now: Double = 0
    /// Tracking advice only means something once a frame has arrived.
    private var hasPose = false

    public init(thresholds: ScanQualityThresholds = ScanQualityThresholds()) {
        self.thresholds = thresholds
    }

    // MARK: Inputs

    /// Feeds one camera pose and returns the updated state.
    @discardableResult
    public mutating func ingest(_ pose: PoseSample) -> ScanQualityState {
        now = pose.time
        hasPose = true
        state.elapsed = pose.time
        state.tracking = pose.tracking
        state.ambientIntensity = pose.ambientIntensity
        state.depthAvailable = pose.depthAvailable
        state.depthHighFraction = pose.depthConfidence?.high

        let position = pose.position
        if let last = lastPosition {
            let step = position.distance(to: last)
            if step < 2.0 { state.distanceWalked += step }
        }
        lastPosition = position

        recent.append(Recent(time: pose.time, position: position, forward: pose.forward))
        while let first = recent.first, pose.time - first.time > thresholds.smoothingWindow, recent.count > 2 {
            recent.removeFirst()
        }
        if let first = recent.first, recent.count >= 2 {
            let dt = pose.time - first.time
            if dt > 0.05 {
                let d = position.distance(to: first.position)
                state.speed = d < 2.0 ? d / dt : state.speed
                let cosine = max(-1, min(1, first.forward.normalized.dot(pose.forward.normalized)))
                let poseAngular = acos(cosine) * 180 / .pi / dt
                // Gyro is the better rotation sensor when it is fresh.
                if let gyro = gyroAngular, pose.time - gyroTime < 0.3 {
                    state.angularSpeed = gyro
                } else {
                    state.angularSpeed = poseAngular
                }
            }
        }
        evaluate()
        return state
    }

    /// Feeds a gyroscope sample; rotation speed then comes from the gyro.
    public mutating func ingest(motion: MotionSample) {
        let degrees = motion.rotationSpeedDegrees
        gyroAngular = gyroAngular.map { $0 * 0.6 + degrees * 0.4 } ?? degrees
        gyroTime = motion.time
    }

    /// Advice driven by something other than the pose stream: RoomPlan's own
    /// coaching instruction, an interruption, or coverage analysis.
    public mutating func setExternal(_ kind: ScanAdviceKind, active: Bool, time: Double? = nil) {
        if let time { now = max(now, time) }
        if active {
            external.insert(kind)
        } else {
            external.remove(kind)
            clear(kind)
        }
        evaluate()
    }

    /// Replaces every external advice of the coverage family at once.
    public mutating func setCoverageAdvice(_ kinds: Set<ScanAdviceKind>, time: Double? = nil) {
        if let time { now = max(now, time) }
        let coverageKinds: Set<ScanAdviceKind> = [.wallNotCovered, .cornerNotCovered, .openingNotCovered, .possibleMissingWall]
        for kind in coverageKinds where !kinds.contains(kind) { clear(kind) }
        external.subtract(coverageKinds)
        external.formUnion(kinds.intersection(coverageKinds))
        evaluate()
    }

    /// Externally controlled advice goes as soon as its source withdraws it.
    private mutating func clear(_ kind: ScanAdviceKind) {
        conditionSince[kind] = nil
        lastTrue[kind] = nil
        activeSince[kind] = nil
    }

    public mutating func reset() {
        self = ScanQualityEngine(thresholds: thresholds)
    }

    // MARK: Evaluation

    private mutating func evaluate() {
        var holds: [ScanAdviceKind: Bool] = [:]

        if hasPose {
            switch state.tracking {
            case .notAvailable: holds[.trackingNotAvailable] = true
            case .initializing: holds[.trackingInitializing] = true
            case .relocalizing: holds[.trackingRelocalizing] = true
            case .excessiveMotion: holds[.excessiveMotion] = true
            case .insufficientFeatures: holds[.insufficientFeatures] = true
            case .normal: break
            }
        }

        holds[.slowDown] = hysteresis(.slowDown, value: state.speed,
                                      enter: thresholds.speedEnter, exit: thresholds.speedExit, above: true)
        holds[.turnSlowly] = hysteresis(.turnSlowly, value: state.angularSpeed,
                                        enter: thresholds.angularEnter, exit: thresholds.angularExit, above: true)
        if let light = state.ambientIntensity {
            holds[.lowLight] = hysteresis(.lowLight, value: light,
                                          enter: thresholds.lowLightEnter, exit: thresholds.lowLightExit, above: false)
        }
        if state.depthAvailable, let high = state.depthHighFraction {
            holds[.lowDepthConfidence] = hysteresis(.lowDepthConfidence, value: high,
                                                    enter: thresholds.depthLowEnter, exit: thresholds.depthLowExit, above: false)
        }
        for kind in external { holds[kind] = true }

        var active: [ScanAdvice] = []
        for kind in ScanAdviceKind.allCases {
            let holding = holds[kind] ?? false
            if holding {
                if conditionSince[kind] == nil { conditionSince[kind] = now }
                lastTrue[kind] = now
                let held = now - (conditionSince[kind] ?? now)
                let immediate = kind.isImmediate || external.contains(kind)
                if immediate || held >= thresholds.minimumConditionDuration {
                    if activeSince[kind] == nil { activeSince[kind] = now }
                }
            } else {
                conditionSince[kind] = nil
                if activeSince[kind] != nil {
                    let quietFor = now - (lastTrue[kind] ?? now)
                    let immediate = kind.isImmediate || external.contains(kind)
                    if immediate || quietFor >= thresholds.minimumDisplayDuration {
                        activeSince[kind] = nil
                    }
                }
            }
            if let since = activeSince[kind] {
                active.append(ScanAdvice(kind: kind, since: since))
            }
        }
        state.advice = active.sorted {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.since < $1.since
        }
    }

    /// Schmitt-trigger style threshold: once the condition entered, it holds
    /// until the value crosses the exit threshold.
    private func hysteresis(_ kind: ScanAdviceKind, value: Double, enter: Double, exit: Double, above: Bool) -> Bool {
        let wasHolding = conditionSince[kind] != nil || activeSince[kind] != nil
        if above {
            return wasHolding ? value > exit : value > enter
        } else {
            return wasHolding ? value < exit : value < enter
        }
    }
}
