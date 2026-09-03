import Foundation

// MARK: - Polygon offsetting
//
// A scanned wall is a centerline with thickness; a room is the space between
// wall faces. Going from one to the other is a per-edge offset: each edge of
// the centerline loop moves inward by half its wall's thickness and the
// corners are rebuilt where the offset edges meet.

public extension GeometryOps {

    /// Offsets every edge of a simple polygon inward by its own distance (a
    /// negative distance moves the edge outward) and rebuilds each corner from
    /// the two offset edges that meet there. The input may wind either way;
    /// the result is counter-clockwise. Returns nil when the result collapses
    /// or crosses itself.
    static func insetPolygon(_ polygon: [Vec2], distances: [Double]) -> [Vec2]? {
        let n = polygon.count
        guard n >= 3, distances.count == n else { return nil }
        var points = polygon
        var d = distances
        if signedArea(points) < 0 {
            points.reverse()
            // Edge j of the reversed polygon is edge (n - 2 - j) mod n of the original.
            d = (0..<n).map { distances[((n - 2 - $0) % n + n) % n] }
        }

        struct Line {
            var point: Vec2
            var direction: Vec2
        }
        var lines: [Line] = []
        for i in 0..<n {
            let a = points[i]
            let b = points[(i + 1) % n]
            let direction = (b - a).normalized
            guard direction.length > 0.5 else { return nil }
            // Counter-clockwise: the interior is to the left of every edge.
            let inward = direction.perpendicular
            lines.append(Line(point: a + inward * d[i], direction: direction))
        }

        var result: [Vec2] = []
        for i in 0..<n {
            let previous = lines[(i + n - 1) % n]
            let current = lines[i]
            let cross = previous.direction.cross(current.direction)
            if abs(cross) < 1e-9 {
                result.append(current.point)
            } else {
                let t = (current.point - previous.point).cross(current.direction) / cross
                result.append(previous.point + previous.direction * t)
            }
        }
        let cleaned = simplified(result, tolerance: 1e-6)
        guard cleaned.count >= 3, signedArea(cleaned) > 1e-6, !polygonSelfIntersects(cleaned) else { return nil }
        return cleaned
    }

    /// Uniform inset (negative = outward).
    static func insetPolygon(_ polygon: [Vec2], by distance: Double) -> [Vec2]? {
        insetPolygon(polygon, distances: Array(repeating: distance, count: polygon.count))
    }
}

public extension GeometryCleaner {

    /// The room inside a loop of wall centerlines: each edge moves inward by
    /// half the thickness of the wall along it. Walls whose placement is not
    /// known to be a centerline (`thicknessSource == nil` — legacy, sample or
    /// hand-drawn data) contribute no inset, so old plans keep their meaning.
    static func interiorPolygon(
        fromCenterlineLoop loop: [Vec2],
        walls: [Wall],
        tolerance: Double = 0.06
    ) -> [Vec2] {
        let ccw = GeometryOps.counterClockwise(loop)
        let n = ccw.count
        guard n >= 3 else { return ccw }
        var distances: [Double] = []
        var any = false
        for i in 0..<n {
            let mid = ccw[i].midpoint(ccw[(i + 1) % n])
            var best: (wall: Wall, distance: Double)? = nil
            for wall in walls {
                let d = GeometryOps.distanceToSegment(mid, wall.start, wall.end)
                if best == nil || d < best!.distance { best = (wall, d) }
            }
            if let best, best.distance <= tolerance, best.wall.thicknessSource != nil {
                distances.append(best.wall.thickness / 2)
                any = true
            } else {
                distances.append(0)
            }
        }
        guard any else { return ccw }
        return GeometryOps.insetPolygon(ccw, distances: distances) ?? ccw
    }

    /// The outside faces of a footprint loop of centerlines: the mirror of
    /// `interiorPolygon`, each edge moved outward by half its wall's thickness.
    static func outsidePolygon(
        fromCenterlineLoop loop: [Vec2],
        walls: [Wall],
        tolerance: Double = 0.06
    ) -> [Vec2] {
        let ccw = GeometryOps.counterClockwise(loop)
        let n = ccw.count
        guard n >= 3 else { return ccw }
        var distances: [Double] = []
        var any = false
        for i in 0..<n {
            let mid = ccw[i].midpoint(ccw[(i + 1) % n])
            var best: (wall: Wall, distance: Double)? = nil
            for wall in walls {
                let d = GeometryOps.distanceToSegment(mid, wall.start, wall.end)
                if best == nil || d < best!.distance { best = (wall, d) }
            }
            if let best, best.distance <= tolerance, best.wall.thicknessSource != nil {
                distances.append(-best.wall.thickness / 2)
                any = true
            } else {
                distances.append(0)
            }
        }
        guard any else { return ccw }
        return GeometryOps.insetPolygon(ccw, distances: distances) ?? ccw
    }
}
