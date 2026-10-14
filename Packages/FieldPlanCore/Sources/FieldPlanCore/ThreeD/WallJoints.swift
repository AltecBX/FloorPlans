import Foundation

// MARK: - Wall joints
//
// Walls are centrelines with a thickness. Drawn as one box each, they leave a
// square notch on the outside of every corner and overlap on the inside — the
// overlap's two coplanar tops flicker against each other, which is exactly
// where a dollhouse is looked at. This resolves every wall end into the
// corner points its two faces should stop at, so the solids meet cleanly:
//
// - two walls at a node: a mitre, both walls ending on the same line;
// - three or more: each wall takes the wedge between its neighbours and the
//   node, so the junction is filled with no gap and no overlap;
// - a wall ending against the side of another (a T that was never split):
//   trimmed back to that wall's face;
// - nothing there: a square end, whose end face is drawn.

/// Where one end of a wall stops, in plan coordinates.
struct WallEnd: Equatable {
    /// On the wall's left face line (left of start→end).
    var left: Vec2
    /// On the wall's right face line.
    var right: Vec2
    /// The node point, included in the footprint at a junction of three or
    /// more so neighbouring wedges tile it.
    var center: Vec2?
    /// The faces across this end, each with the height up to which a
    /// neighbour hides it. A free end is one face hidden by nothing.
    var faces: [EndFace]

    struct EndFace: Equatable {
        var from: Vec2
        var to: Vec2
        /// Wall index of the neighbour behind this face, nil when open.
        var neighbour: Int?
    }

    var isFree: Bool { faces.count == 1 && faces[0].neighbour == nil }
}

struct WallJointSet: Equatable {
    var start: WallEnd
    var end: WallEnd
}

enum WallJoints {

    /// Resolves both ends of every wall. `halfWidth` is how far each face sits
    /// from the centreline — the wall's own half thickness for the solid, a
    /// little more for the baseboard that runs along it.
    static func resolve(
        _ walls: [Wall],
        tolerance: Double = 0.08,
        halfWidth: (Wall) -> Double = { max($0.thickness, 0.02) / 2 }
    ) -> [WallJointSet] {
        let half = walls.map(halfWidth)

        // Cluster endpoints into nodes.
        struct Attachment {
            var wall: Int
            var isStart: Bool
        }
        var nodePoints: [Vec2] = []
        var nodeAttachments: [[Attachment]] = []
        func node(for p: Vec2) -> Int {
            for (i, q) in nodePoints.enumerated() where q.distance(to: p) <= tolerance {
                return i
            }
            nodePoints.append(p)
            nodeAttachments.append([])
            return nodePoints.count - 1
        }
        for (i, wall) in walls.enumerated() where wall.length > 1e-6 {
            nodeAttachments[node(for: wall.start)].append(Attachment(wall: i, isStart: true))
            nodeAttachments[node(for: wall.end)].append(Attachment(wall: i, isStart: false))
        }

        // Default every end to square and free; nodes overwrite.
        var result: [WallJointSet] = walls.indices.map { i in
            WallJointSet(start: squareEnd(walls[i], isStart: true, half: half[i]),
                         end: squareEnd(walls[i], isStart: false, half: half[i]))
        }

        for attachments in nodeAttachments {
            if attachments.count == 1 {
                let a = attachments[0]
                if let tee = teeEnd(wallIndex: a.wall, isStart: a.isStart, walls: walls,
                                    half: half, tolerance: tolerance) {
                    set(&result, a.wall, a.isStart, tee)
                }
                continue
            }

            // The node point: the attached endpoints' average.
            var sum = Vec2.zero
            for a in attachments {
                sum += a.isStart ? walls[a.wall].start : walls[a.wall].end
            }
            let center = sum / Double(attachments.count)

            // Each end's direction pointing away from the node along its wall.
            let ends = attachments.map { a -> (attachment: Attachment, away: Vec2) in
                let d = walls[a.wall].direction
                return (a, a.isStart ? d : -d)
            }.sorted { $0.away.angle < $1.away.angle }

            let count = ends.count
            // corner[i] lies between end i (on its left, looking away from the
            // node) and end i+1 (on its right).
            var corners: [Vec2] = []
            for i in 0..<count {
                let j = (i + 1) % count
                let di = ends[i].away
                let dj = ends[j].away
                let hi = half[ends[i].attachment.wall]
                let hj = half[ends[j].attachment.wall]
                let p = center + di.perpendicular * hi
                let q = center - dj.perpendicular * hj
                corners.append(intersect(p, di, q, dj, limit: 4 * max(hi, hj) + 0.05) ?? (p + q) * 0.5)
            }

            for i in 0..<count {
                let previous = (i + count - 1) % count
                let next = (i + 1) % count
                let awayLeft = corners[i]
                let awayRight = corners[previous]
                let a = ends[i].attachment
                let leftNeighbour = ends[next].attachment.wall
                let rightNeighbour = ends[previous].attachment.wall

                var end: WallEnd
                if count == 2 {
                    // A mitre: one face across the end, shared with the other wall.
                    end = WallEnd(left: awayLeft, right: awayRight, center: nil,
                                  faces: [WallEnd.EndFace(from: awayLeft, to: awayRight,
                                                          neighbour: leftNeighbour)])
                } else {
                    end = WallEnd(left: awayLeft, right: awayRight, center: center,
                                  faces: [WallEnd.EndFace(from: awayLeft, to: center, neighbour: leftNeighbour),
                                          WallEnd.EndFace(from: center, to: awayRight, neighbour: rightNeighbour)])
                }
                // "Left looking away from the node" is the wall's own left at
                // its start and its right at its end.
                if !a.isStart {
                    swap(&end.left, &end.right)
                }
                set(&result, a.wall, a.isStart, end)
            }
        }
        return result
    }

    private static func set(_ result: inout [WallJointSet], _ wall: Int, _ isStart: Bool, _ end: WallEnd) {
        if isStart { result[wall].start = end } else { result[wall].end = end }
    }

    /// A square end with its end face open.
    static func squareEnd(_ wall: Wall, isStart: Bool, half: Double) -> WallEnd {
        let p = isStart ? wall.start : wall.end
        let n = wall.direction.perpendicular
        let left = p + n * half
        let right = p - n * half
        // Faces run the way the footprint does (counter-clockwise): across the
        // start from left to right, across the end from right to left.
        let face = isStart
            ? WallEnd.EndFace(from: left, to: right, neighbour: nil)
            : WallEnd.EndFace(from: right, to: left, neighbour: nil)
        return WallEnd(left: left, right: right, center: nil, faces: [face])
    }

    /// An end that stops against the side of another wall: trimmed to that
    /// wall's near face, with the end face hidden behind it.
    static func teeEnd(
        wallIndex: Int, isStart: Bool, walls: [Wall], half: [Double], tolerance: Double
    ) -> WallEnd? {
        let wall = walls[wallIndex]
        let p = isStart ? wall.start : wall.end
        let away = isStart ? wall.direction : -wall.direction
        for (k, other) in walls.enumerated() where k != wallIndex && other.length > 1e-6 {
            let u = other.direction
            guard abs(away.cross(u)) > 0.3 else { continue }            // not alongside
            let t = GeometryOps.projectedParameter(p, other.start, other.end) * other.length
            guard t > tolerance, t < other.length - tolerance else { continue }
            let closest = other.start + u * t
            let offset = (p - closest).length
            guard offset <= half[k] + tolerance else { continue }
            // The face on the side this wall runs away into.
            let n = u.perpendicular
            let side: Double = n.dot(away) >= 0 ? 1 : -1
            let facePoint = other.start + n * (side * half[k])
            let h = half[wallIndex]
            let leftLine = p + away.perpendicular * h
            let rightLine = p - away.perpendicular * h
            let limit = 4 * (h + half[k]) + 0.1
            guard let awayLeft = intersect(leftLine, away, facePoint, u, limit: limit),
                  let awayRight = intersect(rightLine, away, facePoint, u, limit: limit) else { continue }
            var end = WallEnd(left: awayLeft, right: awayRight, center: nil,
                              faces: [WallEnd.EndFace(from: awayLeft, to: awayRight, neighbour: k)])
            if !isStart { swap(&end.left, &end.right) }
            // Keep faces in footprint order.
            end.faces = [isStart
                ? WallEnd.EndFace(from: end.left, to: end.right, neighbour: k)
                : WallEnd.EndFace(from: end.right, to: end.left, neighbour: k)]
            return end
        }
        return nil
    }

    /// Intersection of two lines given by a point and a direction. Parallel
    /// lines give nil, and so does a meeting point farther than `limit` from
    /// the first point — a near-parallel pair would otherwise throw a corner
    /// metres away.
    static func intersect(_ p: Vec2, _ d: Vec2, _ q: Vec2, _ e: Vec2, limit: Double) -> Vec2? {
        let cross = d.cross(e)
        guard abs(cross) > 1e-6 else {
            // Parallel: collinear continuation meets halfway; anything else has
            // no corner.
            return d.dot(e) < 0 ? (p + q) * 0.5 : nil
        }
        let t = (q - p).cross(e) / cross
        guard abs(t) <= limit else { return nil }
        return p + d * t
    }
}
