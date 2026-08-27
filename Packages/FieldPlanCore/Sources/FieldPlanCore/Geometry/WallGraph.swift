import Foundation

/// Planar graph built from wall segments. Powers endpoint joining, room-loop
/// detection, connectivity checks and duplicate/overlap detection.
///
/// The graph never mutates the input walls silently; cleaning operations
/// return new wall arrays so callers decide what to persist.
public struct WallGraph {

    public struct Node {
        public let index: Int
        public var position: Vec2
        /// (wall array index, true when the wall's START is at this node)
        public var attachments: [(wallIndex: Int, isStart: Bool)] = []
        public var degree: Int { attachments.count }
    }

    public let walls: [Wall]
    public let tolerance: Double
    public private(set) var nodes: [Node] = []
    /// wallIndex -> (startNode, endNode)
    public private(set) var wallNodes: [(start: Int, end: Int)] = []

    public init(walls: [Wall], tolerance: Double = 0.08) {
        self.walls = walls
        self.tolerance = tolerance
        buildNodes()
    }

    private mutating func buildNodes() {
        nodes = []
        wallNodes = Array(repeating: (0, 0), count: walls.count)

        func findOrCreateNode(_ p: Vec2) -> Int {
            // Linear scan is fine at floor-plan scale (tens of walls).
            for node in nodes where node.position.distance(to: p) <= tolerance {
                return node.index
            }
            let node = Node(index: nodes.count, position: p)
            nodes.append(node)
            return node.index
        }

        for (i, wall) in walls.enumerated() {
            let s = findOrCreateNode(wall.start)
            let e = findOrCreateNode(wall.end)
            nodes[s].attachments.append((i, true))
            if e == s {
                // Degenerate wall collapses to a point at this tolerance.
                wallNodes[i] = (s, e)
                continue
            }
            nodes[e].attachments.append((i, false))
            wallNodes[i] = (s, e)
        }

        // Refine node positions to the average of attached endpoints so a
        // cluster of near-miss corners lands on a single point.
        for n in nodes.indices {
            var sum = Vec2.zero
            var count = 0
            for (wi, isStart) in nodes[n].attachments {
                sum += isStart ? walls[wi].start : walls[wi].end
                count += 1
            }
            if count > 0 { nodes[n].position = sum / Double(count) }
        }
    }

    // MARK: - Cleaning

    /// Walls with endpoints moved onto their cluster's shared corner point.
    /// Opening offsets are rescaled so openings stay at the same fraction of
    /// the wall (endpoint moves at snap tolerance are small).
    public func snappedWalls() -> [Wall] {
        var out = walls
        for (i, mapping) in wallNodes.enumerated() {
            guard mapping.start != mapping.end || walls[i].length > tolerance else { continue }
            let oldLength = out[i].length
            out[i].start = nodes[mapping.start].position
            out[i].end = nodes[mapping.end].position
            let newLength = out[i].length
            if oldLength > 1e-9, abs(newLength - oldLength) > 1e-9 {
                let scale = newLength / oldLength
                for j in out[i].openings.indices {
                    out[i].openings[j].centerOffset *= scale
                }
            }
        }
        return out
    }

    /// Groups wall indices into connected components.
    public func connectedComponents() -> [[Int]] {
        guard !walls.isEmpty else { return [] }
        var visited = Array(repeating: false, count: walls.count)
        var components: [[Int]] = []
        for start in walls.indices where !visited[start] {
            var stack = [start]
            var comp: [Int] = []
            visited[start] = true
            while let w = stack.popLast() {
                comp.append(w)
                let (s, e) = wallNodes[w]
                for node in [s, e] {
                    for (other, _) in nodes[node].attachments where !visited[other] {
                        visited[other] = true
                        stack.append(other)
                    }
                }
            }
            components.append(comp)
        }
        return components
    }

    /// Pairs of wall indices that overlap collinearly (duplicate scans of the
    /// same wall, or accidental double tracing).
    public func overlappingPairs(lateralTolerance: Double = 0.06, minOverlap: Double = 0.15) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        for i in walls.indices {
            for j in (i + 1)..<walls.count {
                let a = walls[i]
                let b = walls[j]
                if GeometryOps.collinearOverlap(
                    a.start, a.end, b.start, b.end,
                    lateralTolerance: lateralTolerance,
                    minOverlap: minOverlap
                ) {
                    result.append((i, j))
                }
            }
        }
        return result
    }

    /// Wall indices whose free end connects to nothing (degree-1 node).
    public func danglingWalls() -> [Int] {
        var result: [Int] = []
        for (i, mapping) in wallNodes.enumerated() {
            if nodes[mapping.start].degree <= 1 || nodes[mapping.end].degree <= 1 {
                result.append(i)
            }
        }
        return result
    }

    // MARK: - Faces (room loops)

    /// Detects closed interior faces (candidate room polygons), returned as
    /// counter-clockwise polygons. Dead-end stubs are pruned before the walk;
    /// the outer boundary face is excluded.
    public func interiorFaces(minArea: Double = 0.5) -> [[Vec2]] {
        allFaces().filter { GeometryOps.signedArea($0) > minArea }
    }

    /// The outer boundary of the whole floor as a polygon, when derivable:
    /// the clockwise face with the largest magnitude, returned CCW.
    public func exteriorBoundary() -> [Vec2]? {
        let faces = allFaces()
        let outer = faces.min { GeometryOps.signedArea($0) < GeometryOps.signedArea($1) }
        guard let outer, GeometryOps.signedArea(outer) < 0 else { return nil }
        return outer.reversed()
    }

    /// All faces including the outer one (signed polygons, unfiltered).
    /// Interior faces come out counter-clockwise, the outer face clockwise.
    private func allFaces() -> [[Vec2]] {
        var edges: [(u: Int, v: Int)] = []
        for (i, m) in wallNodes.enumerated() {
            guard m.start != m.end, walls[i].length > tolerance else { continue }
            edges.append((m.start, m.end))
        }
        guard !edges.isEmpty else { return [] }

        var alive = Array(repeating: true, count: edges.count)
        var changed = true
        while changed {
            changed = false
            var degree = [Int: Int]()
            for (i, e) in edges.enumerated() where alive[i] {
                degree[e.u, default: 0] += 1
                degree[e.v, default: 0] += 1
            }
            for (i, e) in edges.enumerated() where alive[i] {
                if degree[e.u, default: 0] <= 1 || degree[e.v, default: 0] <= 1 {
                    alive[i] = false
                    changed = true
                }
            }
        }

        struct HalfEdge {
            let from: Int
            let to: Int
            let twin: Int
            var next: Int = -1
        }
        var halfEdges: [HalfEdge] = []
        var outgoing = [Int: [Int]]()
        for (i, e) in edges.enumerated() where alive[i] {
            let a = halfEdges.count
            halfEdges.append(HalfEdge(from: e.u, to: e.v, twin: a + 1))
            halfEdges.append(HalfEdge(from: e.v, to: e.u, twin: a))
            outgoing[e.u, default: []].append(a)
            outgoing[e.v, default: []].append(a + 1)
        }
        guard !halfEdges.isEmpty else { return [] }

        func angleOf(_ he: Int) -> Double {
            let a = nodes[halfEdges[he].from].position
            let b = nodes[halfEdges[he].to].position
            return (b - a).angle
        }
        for key in outgoing.keys {
            outgoing[key]?.sort { angleOf($0) < angleOf($1) }
        }
        for i in halfEdges.indices {
            let twin = halfEdges[i].twin
            let node = halfEdges[i].to
            guard let list = outgoing[node], let pos = list.firstIndex(of: twin) else { continue }
            halfEdges[i].next = list[(pos - 1 + list.count) % list.count]
        }

        var visited = Array(repeating: false, count: halfEdges.count)
        var faces: [[Vec2]] = []
        for start in halfEdges.indices where !visited[start] {
            var polygon: [Vec2] = []
            var current = start
            var guardCounter = 0
            var valid = true
            while !visited[current] {
                visited[current] = true
                polygon.append(nodes[halfEdges[current].from].position)
                let next = halfEdges[current].next
                if next < 0 { valid = false; break }
                current = next
                guardCounter += 1
                if guardCounter > halfEdges.count + 4 { valid = false; break }
            }
            guard valid, polygon.count >= 3 else { continue }
            faces.append(GeometryOps.simplified(polygon))
        }
        return faces
    }
}

// MARK: - Cleaning helpers

public enum GeometryCleaner {

    /// Snaps wall endpoints that nearly meet onto shared corner points.
    public static func snapEndpoints(_ walls: [Wall], tolerance: Double = 0.08) -> [Wall] {
        WallGraph(walls: walls, tolerance: tolerance).snappedWalls()
    }

    /// Removes walls shorter than `minLength` that are almost certainly scan
    /// noise. Never removes walls that carry openings.
    public static func removeTinyWalls(_ walls: [Wall], minLength: Double = 0.05) -> [Wall] {
        walls.filter { $0.length >= minLength || !$0.openings.isEmpty }
    }

    /// Merges chains of collinear walls that meet end-to-end at a node where
    /// nothing else connects. Openings are carried over with recomputed
    /// offsets. Walls with different change status are never merged.
    public static func mergeCollinear(
        _ walls: [Wall],
        angleTolerance: Double = GeometryAngle.radians(2),
        snapTolerance: Double = 0.08
    ) -> [Wall] {
        var current = walls
        var didMerge = true
        var iterations = 0
        while didMerge && iterations < 100 {
            didMerge = false
            iterations += 1
            let graph = WallGraph(walls: current, tolerance: snapTolerance)
            outer: for node in graph.nodes where node.degree == 2 {
                let (i1, s1) = node.attachments[0]
                let (i2, s2) = node.attachments[1]
                guard i1 != i2 else { continue }
                let a = current[i1]
                let b = current[i2]
                guard a.changeStatus == b.changeStatus else { continue }
                // Directions pointing away from the shared node.
                let dirA = (s1 ? a.end - a.start : a.start - a.end).normalized
                let dirB = (s2 ? b.end - b.start : b.start - b.end).normalized
                // Collinear when the away-directions are opposite.
                let angle = GeometryAngle.difference(dirA.angle, GeometryAngle.normalize(dirB.angle + .pi))
                guard angle <= angleTolerance else { continue }

                // Build merged wall from a's far end to b's far end.
                let farA = s1 ? a.end : a.start
                let farB = s2 ? b.end : b.start
                var merged = a
                merged.id = a.id // keep the older identity
                merged.start = farA
                merged.end = farB
                merged.height = max(a.height, b.height)
                merged.thickness = max(a.thickness, b.thickness)
                merged.originalLength = nil
                merged.source = a.source == b.source ? a.source : .calculated

                // Re-place openings along the merged axis by projecting their
                // world-space centers.
                var openings: [WallOpening] = []
                let axis = (farB - farA)
                let axisLen = axis.length
                guard axisLen > 1e-9 else { continue outer }
                let axisDir = axis / axisLen
                for (wall, list) in [(a, a.openings), (b, b.openings)] {
                    for opening in list {
                        let world = wall.point(atOffset: opening.centerOffset)
                        var moved = opening
                        moved.centerOffset = max(0, min(axisLen, (world - farA).dot(axisDir)))
                        openings.append(moved)
                    }
                }
                merged.openings = openings.sorted { $0.centerOffset < $1.centerOffset }

                var next = current
                next.remove(at: max(i1, i2))
                next.remove(at: min(i1, i2))
                next.append(merged)
                current = next
                didMerge = true
                break outer
            }
        }
        return current
    }

    /// Orders a set of walls into a closed loop and returns the loop polygon
    /// (wall midlines), or nil when the walls do not chain into one loop.
    /// Used to derive a room polygon from a scanned room's wall set.
    public static func loopPolygon(from walls: [Wall], tolerance: Double = 0.15) -> [Vec2]? {
        guard walls.count >= 3 else { return nil }
        var remaining = walls
        let first = remaining.removeFirst()
        var polygon: [Vec2] = [first.start, first.end]

        while !remaining.isEmpty {
            let tail = polygon[polygon.count - 1]
            var foundIndex: Int? = nil
            var reversed = false
            var bestDist = tolerance
            for (i, w) in remaining.enumerated() {
                let ds = w.start.distance(to: tail)
                let de = w.end.distance(to: tail)
                if ds < bestDist { bestDist = ds; foundIndex = i; reversed = false }
                if de < bestDist { bestDist = de; foundIndex = i; reversed = true }
            }
            guard let idx = foundIndex else { return nil }
            let w = remaining.remove(at: idx)
            polygon.append(reversed ? w.start : w.end)
        }

        // Closed when the last point returns to the first.
        guard let first = polygon.first, let last = polygon.last else { return nil }
        guard first.distance(to: last) <= tolerance * 2 else { return nil }
        polygon.removeLast()
        let simplified = GeometryOps.simplified(polygon, tolerance: 1e-6)
        guard simplified.count >= 3 else { return nil }
        return GeometryOps.counterClockwise(simplified)
    }
}
