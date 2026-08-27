import Foundation

/// Segment / polygon primitives used across the wall graph, QA engine and
/// plan generator. All lengths in meters, plan coordinates (see Vec2 docs).
public enum GeometryOps {

    // MARK: - Segments

    /// Closest point on segment [a, b] to point p.
    public static func closestPointOnSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Vec2 {
        let ab = b - a
        let denom = ab.lengthSquared
        guard denom > 1e-18 else { return a }
        let t = max(0, min(1, (p - a).dot(ab) / denom))
        return a + ab * t
    }

    public static func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        p.distance(to: closestPointOnSegment(p, a, b))
    }

    /// Parameter t in [0,1] of the projection of p onto segment [a, b], clamped.
    public static func projectedParameter(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let denom = ab.lengthSquared
        guard denom > 1e-18 else { return 0 }
        return max(0, min(1, (p - a).dot(ab) / denom))
    }

    /// Intersection of segments [p1,p2] and [p3,p4].
    /// Returns the intersection point and both parameters when the segments
    /// properly intersect (including touching endpoints), nil otherwise.
    public static func segmentIntersection(
        _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ p4: Vec2
    ) -> (point: Vec2, t: Double, u: Double)? {
        let r = p2 - p1
        let s = p4 - p3
        let denom = r.cross(s)
        let qp = p3 - p1
        if abs(denom) < 1e-12 {
            return nil // parallel or collinear; overlap handled separately
        }
        let t = qp.cross(s) / denom
        let u = qp.cross(r) / denom
        let eps = 1e-9
        guard t >= -eps, t <= 1 + eps, u >= -eps, u <= 1 + eps else { return nil }
        return (p1 + r * t, max(0, min(1, t)), max(0, min(1, u)))
    }

    /// True when the two segments are collinear (within angular and lateral
    /// tolerance) and their spans overlap by more than `minOverlap`.
    public static func collinearOverlap(
        _ a1: Vec2, _ a2: Vec2, _ b1: Vec2, _ b2: Vec2,
        lateralTolerance: Double = 0.05,
        minOverlap: Double = 0.02
    ) -> Bool {
        let dirA = (a2 - a1)
        let lenA = dirA.length
        guard lenA > 1e-9 else { return false }
        let unitA = dirA / lenA
        // Lateral distance of b endpoints from line A
        let d1 = abs((b1 - a1).cross(unitA))
        let d2 = abs((b2 - a1).cross(unitA))
        guard d1 <= lateralTolerance, d2 <= lateralTolerance else { return false }
        // Overlap along A's axis
        let t1 = (b1 - a1).dot(unitA)
        let t2 = (b2 - a1).dot(unitA)
        let lo = min(t1, t2)
        let hi = max(t1, t2)
        let overlap = min(hi, lenA) - max(lo, 0)
        return overlap > minOverlap
    }

    // MARK: - Polygons

    /// Signed area via the shoelace formula. Positive for counter-clockwise
    /// polygons in plan coordinates. Vertices must not repeat the first point.
    public static func signedArea(_ polygon: [Vec2]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            sum += a.cross(b)
        }
        return sum / 2
    }

    public static func area(_ polygon: [Vec2]) -> Double {
        abs(signedArea(polygon))
    }

    public static func perimeter(_ polygon: [Vec2]) -> Double {
        guard polygon.count >= 2 else { return 0 }
        var sum = 0.0
        for i in 0..<polygon.count {
            sum += polygon[i].distance(to: polygon[(i + 1) % polygon.count])
        }
        return sum
    }

    public static func centroid(_ polygon: [Vec2]) -> Vec2 {
        guard polygon.count >= 3 else {
            guard !polygon.isEmpty else { return .zero }
            var sum = Vec2.zero
            for p in polygon { sum += p }
            return sum / Double(polygon.count)
        }
        let a = signedArea(polygon)
        guard abs(a) > 1e-12 else {
            var sum = Vec2.zero
            for p in polygon { sum += p }
            return sum / Double(polygon.count)
        }
        var cx = 0.0
        var cy = 0.0
        for i in 0..<polygon.count {
            let p = polygon[i]
            let q = polygon[(i + 1) % polygon.count]
            let f = p.cross(q)
            cx += (p.x + q.x) * f
            cy += (p.y + q.y) * f
        }
        return Vec2(cx / (6 * a), cy / (6 * a))
    }

    /// Ray-casting point-in-polygon test (boundary counts as inside).
    public static func polygonContains(_ polygon: [Vec2], _ p: Vec2) -> Bool {
        guard polygon.count >= 3 else { return false }
        // Boundary check first for robustness.
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            if distanceToSegment(p, a, b) < 1e-9 { return true }
        }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let xCross = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Distance from a point to the nearest polygon edge.
    public static func distanceToPolygonBoundary(_ polygon: [Vec2], _ p: Vec2) -> Double {
        guard polygon.count >= 2 else { return .greatestFiniteMagnitude }
        var best = Double.greatestFiniteMagnitude
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            best = min(best, distanceToSegment(p, a, b))
        }
        return best
    }

    /// A point inside the polygon suitable for placing a room label.
    /// Uses the centroid when it lies inside; otherwise samples a coarse grid
    /// and returns the interior point farthest from the boundary
    /// (an inexpensive pole-of-inaccessibility approximation for L-shapes).
    public static func interiorLabelPoint(_ polygon: [Vec2]) -> Vec2 {
        let c = centroid(polygon)
        guard polygon.count >= 3 else { return c }
        if polygonContains(polygon, c), distanceToPolygonBoundary(polygon, c) > 0.15 {
            return c
        }
        let bounds = Rect2(containing: polygon)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return c }
        let steps = 24
        var best = c
        var bestDist = -Double.greatestFiniteMagnitude
        for i in 1..<steps {
            for j in 1..<steps {
                let p = Vec2(
                    bounds.minX + bounds.width * Double(i) / Double(steps),
                    bounds.minY + bounds.height * Double(j) / Double(steps)
                )
                guard polygonContains(polygon, p) else { continue }
                let d = distanceToPolygonBoundary(polygon, p)
                if d > bestDist {
                    bestDist = d
                    best = p
                }
            }
        }
        return bestDist > 0 ? best : c
    }

    /// True when any two non-adjacent edges of the polygon intersect.
    public static func polygonSelfIntersects(_ polygon: [Vec2]) -> Bool {
        let n = polygon.count
        guard n >= 4 else { return false }
        for i in 0..<n {
            let a1 = polygon[i]
            let a2 = polygon[(i + 1) % n]
            for j in (i + 1)..<n {
                // Skip adjacent edges (shared vertex).
                if j == i { continue }
                let isAdjacent = (j == (i + 1) % n) || ((j + 1) % n == i) || (i == 0 && j == n - 1)
                if isAdjacent { continue }
                let b1 = polygon[j]
                let b2 = polygon[(j + 1) % n]
                if let hit = segmentIntersection(a1, a2, b1, b2) {
                    // Ignore touches exactly at shared endpoints.
                    let eps = 1e-9
                    let touchesEndpoint =
                        hit.point.approximatelyEquals(a1, tolerance: eps) ||
                        hit.point.approximatelyEquals(a2, tolerance: eps) ||
                        hit.point.approximatelyEquals(b1, tolerance: eps) ||
                        hit.point.approximatelyEquals(b2, tolerance: eps)
                    if !touchesEndpoint { return true }
                }
            }
        }
        return false
    }

    /// Ensures counter-clockwise winding (positive signed area).
    public static func counterClockwise(_ polygon: [Vec2]) -> [Vec2] {
        signedArea(polygon) < 0 ? polygon.reversed() : polygon
    }

    /// Removes consecutive duplicate points and collinear midpoints.
    public static func simplified(_ polygon: [Vec2], tolerance: Double = 1e-6) -> [Vec2] {
        guard polygon.count >= 3 else { return polygon }
        var pts: [Vec2] = []
        for p in polygon {
            if let last = pts.last, last.approximatelyEquals(p, tolerance: tolerance) { continue }
            pts.append(p)
        }
        if let first = pts.first, let last = pts.last,
           first.approximatelyEquals(last, tolerance: tolerance), pts.count > 1 {
            pts.removeLast()
        }
        guard pts.count >= 3 else { return pts }
        var out: [Vec2] = []
        let n = pts.count
        for i in 0..<n {
            let prev = pts[(i + n - 1) % n]
            let cur = pts[i]
            let next = pts[(i + 1) % n]
            let v1 = (cur - prev).normalized
            let v2 = (next - cur).normalized
            if abs(v1.cross(v2)) < 1e-9 && v1.dot(v2) > 0 {
                continue // collinear pass-through point
            }
            out.append(cur)
        }
        return out.count >= 3 ? out : pts
    }
}
