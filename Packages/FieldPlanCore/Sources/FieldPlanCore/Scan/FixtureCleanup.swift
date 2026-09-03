import Foundation

// MARK: - Fixture cleanup (brief §11: drawing intelligence)
//
// RoomPlan reports every cabinet as "storage": a kitchen arrives as a row of
// boxes with no idea which are base cabinets, which hang on the wall, and
// which stand free as an island. A drafter draws a run. This pass reads what
// the scan measured — how high off the floor a box sits, how tall and deep
// it is, whether its neighbour continues it, whether a wall stands behind
// it — and turns boxes into base runs, upper cabinets and islands.

public enum FixtureCleanup {

    public struct Options: Sendable {
        /// Storage whose bottom is at least this high is wall-hung.
        public var upperCabinetMinimumBottom = 0.9
        public var upperCabinetMaximumHeight = 1.3
        /// Counter-height box proportions for a base cabinet.
        public var baseHeightRange = 0.75...1.05
        public var baseDepthRange = 0.40...0.80
        public var baseMinimumLength = 0.45
        /// Neighbouring runs join across a gap this wide.
        public var joinGap = 0.12
        public var joinLateral = 0.12
        public var joinAngle = GeometryAngle.radians(6)
        /// A run further than half its depth plus this from every wall is an island.
        public var islandClearance = 0.25
        public init() {}
    }

    /// Category for a scanned "storage" object from its measured box.
    public static func storageCategory(
        _ object: ScannedObjectDTO, floorY: Double, options: Options = Options()
    ) -> FixtureCategory {
        let height = object.dimensions.y
        let bottom = object.center.y - height / 2 - floorY
        let depth = min(object.dimensions.x, object.dimensions.z)
        let length = max(object.dimensions.x, object.dimensions.z)
        if bottom >= options.upperCabinetMinimumBottom, height <= options.upperCabinetMaximumHeight {
            return .cabinetUpper
        }
        if bottom < 0.3,
           options.baseHeightRange.contains(height),
           options.baseDepthRange.contains(depth),
           length >= options.baseMinimumLength {
            return .cabinetBase
        }
        return .storage
    }

    /// Joins scanned base cabinets that continue each other into one run and
    /// marks runs with no wall behind them as islands. Hand-placed fixtures
    /// are never touched.
    public static func mergeCabinetRuns(
        _ fixtures: [FixtureItem], walls: [Wall], options: Options = Options()
    ) -> [FixtureItem] {
        let isRun: (FixtureItem) -> Bool = { $0.category == .cabinetBase && $0.source == .lidarScanned }
        var runs = fixtures.filter(isRun)
        let others = fixtures.filter { !isRun($0) }
        guard !runs.isEmpty else { return fixtures }

        var merged = true
        while merged {
            merged = false
            search: for i in runs.indices {
                for j in runs.indices where j > i {
                    if let union = joined(runs[i], runs[j], options: options) {
                        runs[i] = union
                        runs.remove(at: j)
                        merged = true
                        break search
                    }
                }
            }
        }

        for i in runs.indices {
            let run = runs[i]
            let depth = min(run.size.x, run.size.y)
            let nearestWall = walls.map { GeometryOps.distanceToSegment(run.center, $0.start, $0.end) }.min()
            if let nearestWall, nearestWall > depth / 2 + options.islandClearance {
                runs[i].category = .island
            } else if nearestWall == nil {
                runs[i].category = .island
            }
        }
        return others + runs
    }

    /// The long axis of a fixture in plan, with its length and depth.
    static func axis(of fixture: FixtureItem) -> (direction: Vec2, length: Double, depth: Double) {
        let along = Vec2(cos(fixture.rotation), sin(fixture.rotation))
        if fixture.size.x >= fixture.size.y {
            return (along, fixture.size.x, fixture.size.y)
        }
        return (along.perpendicular, fixture.size.y, fixture.size.x)
    }

    /// One run covering both, when `b` continues `a` along its axis.
    static func joined(_ a: FixtureItem, _ b: FixtureItem, options: Options) -> FixtureItem? {
        let axisA = axis(of: a)
        let axisB = axis(of: b)
        let angle = GeometryAngle.difference(axisA.direction.angle, axisB.direction.angle)
        guard min(angle, abs(.pi - angle)) <= options.joinAngle else { return nil }
        guard abs(axisA.depth - axisB.depth) <= 0.15 else { return nil }
        let offset = b.center - a.center
        guard abs(offset.cross(axisA.direction)) <= options.joinLateral else { return nil }
        let t = offset.dot(axisA.direction)
        let aRange = (-axisA.length / 2)...(axisA.length / 2)
        let bRange = (t - axisB.length / 2)...(t + axisB.length / 2)
        let gap = max(bRange.lowerBound - aRange.upperBound, aRange.lowerBound - bRange.upperBound)
        guard gap <= options.joinGap else { return nil }

        let lo = min(aRange.lowerBound, bRange.lowerBound)
        let hi = max(aRange.upperBound, bRange.upperBound)
        var run = a
        run.center = a.center + axisA.direction * ((lo + hi) / 2)
        let length = hi - lo
        let depth = max(axisA.depth, axisB.depth)
        run.size = a.size.x >= a.size.y ? Vec2(length, depth) : Vec2(depth, length)
        run.height = [a.height, b.height].compactMap { $0 }.max() ?? a.height
        if run.roomID == nil { run.roomID = b.roomID }
        run.confidence = min(a.confidence, b.confidence)
        return run
    }
}

extension CaptureConfidence: Comparable {
    public static func < (lhs: CaptureConfidence, rhs: CaptureConfidence) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ value: CaptureConfidence) -> Int {
        switch value {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}
