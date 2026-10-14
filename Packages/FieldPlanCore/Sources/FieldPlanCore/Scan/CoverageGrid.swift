import Foundation

// MARK: - Coverage map (spec §6)
//
// A sparse plan grid that remembers what the scanner has *observed*, not
// where the camera merely pointed: each classified mesh face lands in the cell
// under its centroid, and each pose adds a visit. Walls, floors, corners and
// openings are then scored by how much of them has mesh behind them.

public struct GridKey: Hashable, Sendable {
    public var x: Int32
    public var y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}

public struct CoverageCell: Hashable, Sendable {
    public var floorHits = 0
    public var wallHits = 0
    public var ceilingHits = 0
    public var openingHits = 0
    public var otherHits = 0
    public var visits = 0
    public var lastSeen: Double = 0
    /// Closest camera position (plan meters) at any visit.
    public var nearestCamera: Double = .greatestFiniteMagnitude
    /// Accumulated absolute plan components of the wall faces' normals, so a
    /// wall's coverage counts only faces that run along it — the neighbouring
    /// wall's faces at a corner do not count for both walls.
    public var wallNormalX: Double = 0
    public var wallNormalY: Double = 0

    public init() {}

    public var totalHits: Int { floorHits + wallHits + ceilingHits + openingHits + otherHits }

    /// Dominant wall-face normal direction (absolute components), or nil.
    public var wallNormal: Vec2? {
        let n = Vec2(wallNormalX, wallNormalY)
        return n.length > 1e-9 ? n.normalized : nil
    }
}

/// How much of a wall segment has mesh evidence behind it.
public struct WallCoverage: Hashable, Sendable {
    public var fraction: Double
    public var sampleCount: Int
    public var coveredSamples: Int
    public var meanHits: Double
    /// Uncovered ranges as (startOffset, endOffset) along the wall, meters.
    public var gaps: [Range]

    public struct Range: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var length: Double { end - start }
    }
}

public struct CoverageGrid: Sendable {
    public let cellSize: Double
    public private(set) var cells: [GridKey: CoverageCell] = [:]
    public private(set) var floorElevation: Double?
    public private(set) var ceilingElevation: Double?
    public var classifier = MeshFaceClassifier()

    public init(cellSize: Double = 0.25) {
        self.cellSize = max(cellSize, 0.05)
    }

    // MARK: Building

    public func key(for p: Vec2) -> GridKey {
        GridKey(x: Int32((p.x / cellSize).rounded(.down)), y: Int32((p.y / cellSize).rounded(.down)))
    }

    public func center(of key: GridKey) -> Vec2 {
        Vec2((Double(key.x) + 0.5) * cellSize, (Double(key.y) + 0.5) * cellSize)
    }

    /// Builds a grid from the latest revision of every mesh chunk plus the
    /// camera path. Elevations are estimated from the meshes unless given.
    public static func build(
        chunks: [MeshChunk],
        poses: [PoseSample] = [],
        floorElevation: Double? = nil,
        cellSize: Double = 0.25
    ) -> CoverageGrid {
        var grid = CoverageGrid(cellSize: cellSize)
        let floor = floorElevation ?? MeshFaceClassifier.estimateFloorElevation(chunks)
        grid.floorElevation = floor
        if let floor {
            grid.ceilingElevation = MeshFaceClassifier.estimateCeilingElevation(chunks, floorElevation: floor)
        }
        for chunk in chunks { grid.add(chunk) }
        for pose in poses { grid.addCameraPosition(pose.planPosition, time: pose.time) }
        return grid
    }

    /// Accumulates one chunk. Add each anchor's *latest* revision once; the
    /// grid does not de-duplicate updates of the same anchor.
    public mutating func add(_ chunk: MeshChunk) {
        for face in 0..<chunk.faceCount {
            let kind = classifier.classify(chunk, face: face, floorElevation: floorElevation, ceilingElevation: ceilingElevation)
            let key = self.key(for: chunk.faceCentroid(face).planProjection)
            var cell = cells[key] ?? CoverageCell()
            switch kind {
            case .floor: cell.floorHits += 1
            case .wall:
                cell.wallHits += 1
                let normal = chunk.faceNormal(face)
                cell.wallNormalX += abs(normal.x)
                cell.wallNormalY += abs(normal.z)
            case .ceiling: cell.ceilingHits += 1
            case .door, .window: cell.openingHits += 1
            case .table, .seat, .none: cell.otherHits += 1
            }
            cells[key] = cell
        }
    }

    public mutating func addCameraPosition(_ plan: Vec2, time: Double) {
        let key = self.key(for: plan)
        var cell = cells[key] ?? CoverageCell()
        cell.visits += 1
        cell.lastSeen = max(cell.lastSeen, time)
        cell.nearestCamera = 0
        cells[key] = cell
        // Neighbours within one cell learn how close the camera came.
        for dx in -1...1 {
            for dy in -1...1 where dx != 0 || dy != 0 {
                let neighbour = GridKey(x: key.x + Int32(dx), y: key.y + Int32(dy))
                var n = cells[neighbour] ?? CoverageCell()
                n.nearestCamera = min(n.nearestCamera, plan.distance(to: center(of: neighbour)))
                cells[neighbour] = n
            }
        }
    }

    public mutating func setElevations(floor: Double?, ceiling: Double?) {
        floorElevation = floor
        ceilingElevation = ceiling
    }

    // MARK: Queries

    /// Fraction of the polygon's cells that have floor mesh.
    public func floorCoverage(of polygon: [Vec2]) -> Double {
        let keys = cellKeys(inside: polygon)
        guard !keys.isEmpty else { return 0 }
        let covered = keys.filter { (cells[$0]?.floorHits ?? 0) > 0 }.count
        return Double(covered) / Double(keys.count)
    }

    /// Cell centres inside the polygon without floor evidence.
    public func unobservedFloorCells(in polygon: [Vec2]) -> [Vec2] {
        cellKeys(inside: polygon)
            .filter { (cells[$0]?.floorHits ?? 0) == 0 }
            .map(center(of:))
    }

    /// Cell centres anywhere with floor evidence.
    public func observedFloorCells() -> [Vec2] {
        cells.filter { $0.value.floorHits > 0 }.map { center(of: $0.key) }
    }

    /// Cell centres anywhere with wall evidence.
    public func observedWallCells() -> [Vec2] {
        cells.filter { $0.value.wallHits > 0 }.map { center(of: $0.key) }
    }

    /// Observed floor area in square meters.
    public var observedFloorArea: Double {
        Double(cells.values.filter { $0.floorHits > 0 }.count) * cellSize * cellSize
    }

    /// Whether any cell within `radius` of `p` has at least `minHits` wall
    /// faces. With `along` given, only cells whose wall faces run in that
    /// direction count, so the perpendicular wall at a corner is ignored.
    public func hasWallEvidence(near p: Vec2, radius: Double, minHits: Int, along direction: Vec2? = nil) -> Bool {
        let reach = Int32((radius / cellSize).rounded(.up))
        let k = key(for: p)
        let wallNormal = direction.map { Vec2(abs($0.y), abs($0.x)) }
        for dx in -reach...reach {
            for dy in -reach...reach {
                let neighbour = GridKey(x: k.x + dx, y: k.y + dy)
                guard let cell = cells[neighbour], cell.wallHits >= minHits else { continue }
                guard center(of: neighbour).distance(to: p) <= radius + cellSize * 0.71 else { continue }
                if let wallNormal, let cellNormal = cell.wallNormal, cellNormal.dot(wallNormal) < 0.6 {
                    continue
                }
                return true
            }
        }
        return false
    }

    /// Wall coverage sampled every `spacing` meters along the segment.
    public func wallCoverage(from a: Vec2, to b: Vec2, spacing: Double = 0.15,
                             lateralTolerance: Double = 0.30, minHits: Int = 2) -> WallCoverage {
        let length = a.distance(to: b)
        guard length > 1e-6 else {
            return WallCoverage(fraction: 0, sampleCount: 0, coveredSamples: 0, meanHits: 0, gaps: [])
        }
        let count = max(2, Int((length / spacing).rounded(.up)) + 1)
        let direction = (b - a) / length
        var covered = 0
        var hitsTotal = 0
        var gaps: [WallCoverage.Range] = []
        var gapStart: Double? = nil
        for i in 0..<count {
            let offset = length * Double(i) / Double(count - 1)
            let p = a + direction * offset
            let isCovered = hasWallEvidence(near: p, radius: lateralTolerance, minHits: minHits, along: direction)
            if isCovered {
                covered += 1
                hitsTotal += cells[key(for: p)]?.wallHits ?? 0
                if let start = gapStart {
                    gaps.append(WallCoverage.Range(start: start, end: offset))
                    gapStart = nil
                }
            } else if gapStart == nil {
                gapStart = offset
            }
        }
        if let start = gapStart { gaps.append(WallCoverage.Range(start: start, end: length)) }
        return WallCoverage(
            fraction: Double(covered) / Double(count),
            sampleCount: count,
            coveredSamples: covered,
            meanHits: covered > 0 ? Double(hitsTotal) / Double(covered) : 0,
            gaps: gaps.filter { $0.length >= spacing * 0.5 })
    }

    public func wallCoverage(_ wall: Wall) -> WallCoverage {
        wallCoverage(from: wall.start, to: wall.end)
    }

    /// Share of cells within `radius` of a corner that carry wall evidence.
    public func cornerCoverage(at p: Vec2, radius: Double = 0.4, minHits: Int = 1) -> Double {
        let reach = Int32((radius / cellSize).rounded(.up))
        let k = key(for: p)
        var total = 0
        var covered = 0
        for dx in -reach...reach {
            for dy in -reach...reach {
                let neighbour = GridKey(x: k.x + dx, y: k.y + dy)
                guard center(of: neighbour).distance(to: p) <= radius else { continue }
                total += 1
                if (cells[neighbour]?.wallHits ?? 0) >= minHits { covered += 1 }
            }
        }
        return total > 0 ? Double(covered) / Double(total) : 0
    }

    /// Coverage of the wall span an opening occupies, counting wall, door and
    /// window faces (a scanned doorway has jambs and a header, not wall).
    public func openingCoverage(on wall: Wall, opening: WallOpening, spacing: Double = 0.12) -> Double {
        let start = wall.point(atOffset: max(0, opening.startOffset))
        let end = wall.point(atOffset: min(wall.length, opening.endOffset))
        let length = start.distance(to: end)
        guard length > 1e-6 else { return 0 }
        let count = max(2, Int((length / spacing).rounded(.up)) + 1)
        let direction = (end - start) / length
        var covered = 0
        for i in 0..<count {
            let p = start + direction * (length * Double(i) / Double(count - 1))
            let reach: Int32 = 1
            let k = key(for: p)
            var found = false
            for dx in -reach...reach where !found {
                for dy in -reach...reach where !found {
                    if let cell = cells[GridKey(x: k.x + dx, y: k.y + dy)],
                       cell.wallHits + cell.openingHits >= 1 {
                        found = true
                    }
                }
            }
            if found { covered += 1 }
        }
        return Double(covered) / Double(count)
    }

    /// Camera visits inside a polygon (was the room entered?).
    public func visits(in polygon: [Vec2]) -> Int {
        cellKeys(inside: polygon).reduce(0) { $0 + (cells[$1]?.visits ?? 0) }
    }

    func cellKeys(inside polygon: [Vec2]) -> [GridKey] {
        guard polygon.count >= 3 else { return [] }
        let bounds = Rect2(containing: polygon)
        let minKey = key(for: Vec2(bounds.minX, bounds.minY))
        let maxKey = key(for: Vec2(bounds.maxX, bounds.maxY))
        var keys: [GridKey] = []
        for x in minKey.x...maxKey.x {
            for y in minKey.y...maxKey.y {
                let k = GridKey(x: x, y: y)
                if GeometryOps.polygonContains(polygon, center(of: k)) { keys.append(k) }
            }
        }
        return keys
    }
}

// MARK: - Coverage advice

public enum CoverageAdvisor {
    public struct Report: Sendable {
        public var wallCoverage: [UUID: WallCoverage] = [:]
        public var openingCoverage: [UUID: Double] = [:]
        public var cornerCoverage: [Vec2: Double] = [:]
        public var floorCoverage: [UUID: Double] = [:]
        public var advice: Set<ScanAdviceKind> = []
        public init() {}
    }

    /// Scores every element of a level against the grid and derives the
    /// coverage advice the quality engine should show.
    public static func report(
        level: LevelGeometry,
        grid: CoverageGrid,
        wallThreshold: Double = 0.6,
        openingThreshold: Double = 0.5,
        cornerThreshold: Double = 0.25,
        floorThreshold: Double = 0.5
    ) -> Report {
        var report = Report()
        for wall in level.walls where wall.length > 0.3 {
            let coverage = grid.wallCoverage(wall)
            report.wallCoverage[wall.id] = coverage
            if coverage.fraction < wallThreshold { report.advice.insert(.wallNotCovered) }
            for opening in wall.openings {
                let c = grid.openingCoverage(on: wall, opening: opening)
                report.openingCoverage[opening.id] = c
                if c < openingThreshold { report.advice.insert(.openingNotCovered) }
            }
        }
        let graph = WallGraph(walls: level.walls, tolerance: 0.1)
        for node in graph.nodes where node.degree >= 2 {
            let c = grid.cornerCoverage(at: node.position)
            report.cornerCoverage[node.position] = c
            if c < cornerThreshold { report.advice.insert(.cornerNotCovered) }
        }
        for room in level.rooms where room.polygon.count >= 3 {
            let c = grid.floorCoverage(of: room.polygon)
            report.floorCoverage[room.id] = c
        }
        return report
    }
}
