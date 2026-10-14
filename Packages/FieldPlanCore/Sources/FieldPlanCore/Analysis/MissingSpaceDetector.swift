import Foundation

// MARK: - Missing-space detection (spec §15)
//
// The QA engine reasons about what exists. This reasons about what is absent:
// a doorway whose far side is enclosed but belongs to no room, a void inside
// the footprint no room explains, a room edge with nothing behind it, stairs
// that lead to a story that was never scanned. Findings are shown; geometry
// is never changed.

public struct SpaceFinding: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case doorwayToUnscannedSpace
        case footprintVoid
        case openRoomEdge
        case stairsToUnscannedLevel

        public var displayName: String {
            switch self {
            case .doorwayToUnscannedSpace: return "Doorway to Unscanned Space"
            case .footprintVoid: return "Possible Unscanned Space"
            case .openRoomEdge: return "Room Edge Without a Wall"
            case .stairsToUnscannedLevel: return "Stairs to an Unscanned Level"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var message: String
    public var levelID: UUID?
    public var elementID: UUID?
    /// Where to point on the plan.
    public var location: Vec2
    /// Extent to hatch, when known (axis-aligned rectangle corners, CCW).
    public var region: [Vec2]
    /// Cell centres inside the region, for a hatch that follows the shape.
    public var cells: [Vec2]
    public var estimatedArea: Double?
    public var severity: QASeverity

    public init(
        id: UUID = UUID(),
        kind: Kind,
        message: String,
        levelID: UUID? = nil,
        elementID: UUID? = nil,
        location: Vec2,
        region: [Vec2] = [],
        cells: [Vec2] = [],
        estimatedArea: Double? = nil,
        severity: QASeverity = .review
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.levelID = levelID
        self.elementID = elementID
        self.location = location
        self.region = region
        self.cells = cells
        self.estimatedArea = estimatedArea
        self.severity = severity
    }
}

/// Raster of a level: what each cell is, from the walls and rooms.
public struct FootprintRaster: Sendable {
    public enum CellKind: UInt8, Sendable {
        case unknown = 0
        case wall = 1
        case room = 2
        case outside = 3
        /// Enclosed by walls but inside no room.
        case unexplained = 4
    }

    public let cellSize: Double
    public let origin: Vec2
    public let columns: Int
    public let rows: Int
    public private(set) var kinds: [CellKind]
    /// Room index per cell, or -1.
    public private(set) var roomIndex: [Int]

    public init(level: LevelGeometry, cellSize: Double = 0.15, margin: Double = 1.0) {
        self.cellSize = cellSize
        var bounds = level.bounds
        if bounds.isNull { bounds = Rect2(minX: 0, minY: 0, maxX: 1, maxY: 1) }
        bounds = bounds.expanded(by: margin)
        origin = Vec2(bounds.minX, bounds.minY)
        columns = max(1, Int((bounds.width / cellSize).rounded(.up)) + 1)
        rows = max(1, Int((bounds.height / cellSize).rounded(.up)) + 1)
        kinds = Array(repeating: .unknown, count: columns * rows)
        roomIndex = Array(repeating: -1, count: columns * rows)
        rasterize(level: level)
    }

    public func index(_ x: Int, _ y: Int) -> Int { y * columns + x }

    public func cell(containing p: Vec2) -> (x: Int, y: Int)? {
        let x = Int(((p.x - origin.x) / cellSize).rounded(.down))
        let y = Int(((p.y - origin.y) / cellSize).rounded(.down))
        guard x >= 0, y >= 0, x < columns, y < rows else { return nil }
        return (x, y)
    }

    public func center(_ x: Int, _ y: Int) -> Vec2 {
        Vec2(origin.x + (Double(x) + 0.5) * cellSize, origin.y + (Double(y) + 0.5) * cellSize)
    }

    public func kind(at p: Vec2) -> CellKind {
        guard let c = cell(containing: p) else { return .outside }
        return kinds[index(c.x, c.y)]
    }

    private mutating func rasterize(level: LevelGeometry) {
        // Rooms first, walls on top (a wall cell is a wall even inside a
        // polygon that reaches the wall's centreline).
        for (r, room) in level.rooms.enumerated() where room.polygon.count >= 3 {
            let b = Rect2(containing: room.polygon)
            guard let lo = cell(containing: Vec2(b.minX, b.minY)),
                  let hi = cell(containing: Vec2(b.maxX, b.maxY)) else { continue }
            for y in lo.y...hi.y {
                for x in lo.x...hi.x where GeometryOps.polygonContains(room.polygon, center(x, y)) {
                    kinds[index(x, y)] = .room
                    roomIndex[index(x, y)] = r
                }
            }
        }
        for wall in level.walls where wall.length > 0.01 {
            let halfWidth = wall.thickness / 2 + cellSize * 0.5
            let b = Rect2(containing: [wall.start, wall.end]).expanded(by: halfWidth + cellSize)
            guard let lo = cell(containing: Vec2(max(b.minX, origin.x), max(b.minY, origin.y))),
                  let hi = cell(containing: Vec2(min(b.maxX, origin.x + Double(columns - 1) * cellSize),
                                                 min(b.maxY, origin.y + Double(rows - 1) * cellSize))) else { continue }
            for y in lo.y...hi.y {
                for x in lo.x...hi.x {
                    let c = center(x, y)
                    if GeometryOps.distanceToSegment(c, wall.start, wall.end) <= halfWidth {
                        kinds[index(x, y)] = .wall
                    }
                }
            }
        }
        // Flood from the border through everything that is not wall.
        var stack: [Int] = []
        for x in 0..<columns {
            stack.append(index(x, 0))
            stack.append(index(x, rows - 1))
        }
        for y in 0..<rows {
            stack.append(index(0, y))
            stack.append(index(columns - 1, y))
        }
        var visited = Array(repeating: false, count: kinds.count)
        while let i = stack.popLast() {
            guard !visited[i] else { continue }
            visited[i] = true
            guard kinds[i] != .wall else { continue }
            if kinds[i] == .unknown { kinds[i] = .outside }
            let x = i % columns
            let y = i / columns
            if x > 0 { stack.append(i - 1) }
            if x < columns - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - columns) }
            if y < rows - 1 { stack.append(i + columns) }
        }
        for i in kinds.indices where kinds[i] == .unknown {
            kinds[i] = .unexplained
        }
    }

    /// Connected clusters of unexplained cells (4-connectivity).
    public func unexplainedClusters() -> [[Int]] {
        var visited = Array(repeating: false, count: kinds.count)
        var clusters: [[Int]] = []
        for start in kinds.indices where kinds[start] == .unexplained && !visited[start] {
            var cluster: [Int] = []
            var stack = [start]
            visited[start] = true
            while let i = stack.popLast() {
                cluster.append(i)
                let x = i % columns
                let y = i / columns
                let neighbours = [
                    x > 0 ? i - 1 : -1, x < columns - 1 ? i + 1 : -1,
                    y > 0 ? i - columns : -1, y < rows - 1 ? i + columns : -1,
                ]
                for n in neighbours where n >= 0 && !visited[n] && kinds[n] == .unexplained {
                    visited[n] = true
                    stack.append(n)
                }
            }
            clusters.append(cluster)
        }
        return clusters
    }
}

public enum MissingSpaceDetector {

    public struct Options: Sendable {
        public var cellSize = 0.15
        /// Smallest enclosed void worth reporting.
        public var minimumVoidArea = 1.2
        /// Voids narrower than this are wall-thickness slivers, not rooms.
        public var minimumVoidWidth = 0.6
        /// Room edges shorter than this are not checked for a backing wall.
        public var minimumEdgeLength = 0.8
        /// A wall within this distance backs a room edge.
        public var wallBackingTolerance = 0.25
        /// Share of an edge that must be backed before it counts as walled.
        public var backedFraction = 0.5
        public var probeDistance = 0.35

        public init() {}
    }

    /// All findings for a level. Pass the whole snapshot's levels to check
    /// stairs against adjacent stories.
    public static func findings(
        for level: LevelGeometry,
        levels: [LevelGeometry] = [],
        options: Options = Options()
    ) -> [SpaceFinding] {
        guard !(level.walls.isEmpty && level.rooms.isEmpty) else { return [] }
        var findings: [SpaceFinding] = []
        let raster = FootprintRaster(level: level, cellSize: options.cellSize)

        findings.append(contentsOf: voids(level: level, raster: raster, options: options))
        findings.append(contentsOf: doorways(level: level, raster: raster, options: options))
        findings.append(contentsOf: openEdges(level: level, raster: raster, options: options))
        findings.append(contentsOf: stairs(level: level, levels: levels))

        return findings.sorted { $0.severity > $1.severity }
    }

    // MARK: Voids

    static func voids(level: LevelGeometry, raster: FootprintRaster, options: Options) -> [SpaceFinding] {
        var findings: [SpaceFinding] = []
        let cellArea = raster.cellSize * raster.cellSize
        let formatter = UnitFormatter()
        // The raster's wall band eats half a wall plus half a cell on every
        // side of a void, so the reported extent is grown back by that much
        // and the area scaled by how much of its box the cluster fills.
        let meanThickness = level.walls.isEmpty ? 0.1143
            : level.walls.map(\.thickness).reduce(0, +) / Double(level.walls.count)
        let grow = meanThickness / 2 + raster.cellSize / 2
        for cluster in raster.unexplainedClusters() {
            let cellsArea = Double(cluster.count) * cellArea
            guard cellsArea >= options.minimumVoidArea * 0.6 else { continue }
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            for i in cluster {
                let x = i % raster.columns
                let y = i / raster.columns
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            let width = Double(maxX - minX + 1) * raster.cellSize
            let height = Double(maxY - minY + 1) * raster.cellSize
            let fill = cellsArea / max(width * height, 1e-9)
            let area = (width + 2 * grow) * (height + 2 * grow) * fill
            guard area >= options.minimumVoidArea else { continue }
            guard min(width, height) + 2 * grow >= options.minimumVoidWidth else { continue }
            let lo = raster.center(minX, minY) - Vec2(raster.cellSize / 2 + grow, raster.cellSize / 2 + grow)
            let hi = raster.center(maxX, maxY) + Vec2(raster.cellSize / 2 + grow, raster.cellSize / 2 + grow)
            let region = [lo, Vec2(hi.x, lo.y), hi, Vec2(lo.x, hi.y)]
            let cells = cluster.map { raster.center($0 % raster.columns, $0 / raster.columns) }
            var sum = Vec2.zero
            for c in cells { sum += c }
            let centroid = sum / Double(cells.count)
            findings.append(SpaceFinding(
                kind: .footprintVoid,
                message: "About \(formatter.area(area)) is enclosed by walls but belongs to no scanned room.",
                levelID: level.id,
                location: centroid,
                region: region,
                cells: cells,
                estimatedArea: area,
                severity: .review))
        }
        return findings
    }

    // MARK: Doorways

    static func doorways(level: LevelGeometry, raster: FootprintRaster, options: Options) -> [SpaceFinding] {
        var findings: [SpaceFinding] = []
        for wall in level.walls {
            let perpendicular = wall.direction.perpendicular
            let reach = wall.thickness / 2 + options.probeDistance
            for opening in wall.openings where opening.kind == .door || opening.kind == .opening {
                let center = wall.point(atOffset: opening.centerOffset)
                let sides = [center + perpendicular * reach, center - perpendicular * reach]
                for probe in sides where raster.kind(at: probe) == .unexplained {
                    findings.append(SpaceFinding(
                        kind: .doorwayToUnscannedSpace,
                        message: "A \(opening.kind.displayName.lowercased()) leads into space that was not scanned.",
                        levelID: level.id,
                        elementID: opening.id,
                        location: probe,
                        severity: .review))
                    break
                }
            }
        }
        return findings
    }

    // MARK: Open edges

    static func openEdges(level: LevelGeometry, raster: FootprintRaster, options: Options) -> [SpaceFinding] {
        var findings: [SpaceFinding] = []
        for room in level.rooms where room.polygon.count >= 3 {
            let polygon = room.polygon
            let n = polygon.count
            for i in 0..<n {
                let a = polygon[i]
                let b = polygon[(i + 1) % n]
                let length = a.distance(to: b)
                guard length >= options.minimumEdgeLength else { continue }
                let samples = max(3, Int(length / 0.2))
                var backed = 0
                for s in 0..<samples {
                    let p = a.lerp(to: b, t: (Double(s) + 0.5) / Double(samples))
                    if level.walls.contains(where: { GeometryOps.distanceToSegment(p, $0.start, $0.end) <= options.wallBackingTolerance }) {
                        backed += 1
                    }
                }
                guard Double(backed) / Double(samples) < options.backedFraction else { continue }
                // Something is on the other side: another room means an
                // open-plan boundary, which is fine.
                let outward = -(b - a).normalized.perpendicular   // polygon is CCW; interior is to the left
                let probe = a.midpoint(b) + outward * options.probeDistance
                let otherRoom = level.rooms.first { $0.id != room.id && GeometryOps.polygonContains($0.polygon, probe) }
                guard otherRoom == nil else { continue }
                let kind = raster.kind(at: probe)
                let continues = kind == .unexplained
                findings.append(SpaceFinding(
                    kind: .openRoomEdge,
                    message: continues
                        ? "\(room.name) has no wall along one side and the space beyond it was not scanned."
                        : "\(room.name) has no wall along one side — the boundary may be incomplete.",
                    levelID: level.id,
                    elementID: room.id,
                    location: a.midpoint(b),
                    region: [a, b],
                    severity: .review))
            }
        }
        return findings
    }

    // MARK: Stairs

    static func stairs(level: LevelGeometry, levels: [LevelGeometry]) -> [SpaceFinding] {
        let stairFixtures = level.fixtures.filter { $0.category == .stairs }
        guard !stairFixtures.isEmpty else { return [] }
        let others = levels.filter { $0.id != level.id && !($0.walls.isEmpty && $0.rooms.isEmpty) }
        let hasAdjacent = others.contains { abs($0.storyIndex - level.storyIndex) == 1 }
        guard !hasAdjacent else { return [] }
        return stairFixtures.map { stair in
            SpaceFinding(
                kind: .stairsToUnscannedLevel,
                message: levels.count <= 1
                    ? "Stairs lead to a level that has not been scanned."
                    : "Stairs on \(level.name) lead to a story with no scanned geometry.",
                levelID: level.id,
                elementID: stair.id,
                location: stair.center,
                region: stair.corners,
                severity: .review)
        }
    }
}
