import Foundation

// MARK: - Wall assembly (brief §7, §10: wall thickness measured, not assumed)
//
// A scan reports wall *surfaces*: the face of a wall as seen from inside a
// room. A partition walked from both sides therefore arrives twice, a few
// inches apart. Those two faces are the one real measurement of a wall's
// thickness a LiDAR scan ever makes, and the drafting convention is a
// centerline with that thickness. Faces seen from one side only (exterior
// walls, partitions never walked round) get an assumed thickness, marked
// as assumed, and are offset outward so the room keeps its measured size.

public enum WallAssembly {

    public struct Options: Sendable {
        /// Two parallel faces this far apart are the two sides of one wall.
        public var pairGapMinimum = 0.04
        public var pairGapMaximum = 0.45
        public var angleTolerance = GeometryAngle.radians(6)
        /// Overlap along the wall required to pair two faces (or 60 % of the
        /// shorter face when that is less).
        public var minimumOverlap = 0.40
        /// Faces closer than this on the same side are the same face twice.
        public var duplicateLateral = 0.04
        /// Assumed thickness for single-face walls, by kind.
        public var interiorThickness = 0.1143
        public var exteriorThickness = 0.1524
        /// How far past a face to probe for the room it belongs to.
        public var probeDistance = 0.30
        /// The first, close probe: a face sits on its room's floor edge, so a
        /// point this far in is inside the room and this far out is not.
        public var nearProbe = 0.03
        /// A neighbouring room's floor edge within this distance behind a
        /// face makes the wall a partition rather than an exterior wall.
        public var neighbourReach = 0.75
        /// Wall ends this close after offsetting met at a corner before it.
        public var cornerReach = 0.30
        /// A loose end this close to another wall's centerline ends on it.
        public var junctionReach = 0.20

        public init() {}
    }

    public struct Result: Sendable {
        public var walls: [Wall]
        /// Faces folded into another wall: dropped id → surviving id.
        public var replaced: [UUID: UUID]
    }

    public static func assemble(walls: [Wall], rooms: [RoomShape], options: Options = Options()) -> Result {
        var used = Set<Int>()
        var output: [Wall] = []
        var replaced: [UUID: UUID] = [:]

        // 1. Facing pairs → centerlines with measured thickness.
        for i in walls.indices where !used.contains(i) {
            let a = walls[i]
            guard a.length > 0.05 else { continue }
            var best: (index: Int, overlap: Double, gap: Double)? = nil
            for j in walls.indices where j > i && !used.contains(j) {
                let b = walls[j]
                guard b.length > 0.05, let match = facing(a, b, options: options) else { continue }
                if let current = best {
                    let better = match.overlap > current.overlap + 0.05
                        || (abs(match.overlap - current.overlap) <= 0.05 && match.gap < current.gap)
                    if better { best = (j, match.overlap, match.gap) }
                } else {
                    best = (j, match.overlap, match.gap)
                }
            }
            if let best {
                used.insert(i)
                used.insert(best.index)
                let merged = centerline(a, walls[best.index])
                output.append(merged)
                replaced[a.id == merged.id ? walls[best.index].id : a.id] = merged.id
            }
        }

        // 2. The same face captured twice from the same side.
        var singles = walls.indices.filter { !used.contains($0) }.map { walls[$0] }
        var k = 0
        while k < singles.count {
            var m = k + 1
            while m < singles.count {
                if isDuplicate(singles[k], singles[m], options: options) {
                    let keepFirst = rank(singles[k]) >= rank(singles[m])
                    let survivor = keepFirst ? singles[k] : singles[m]
                    let dropped = keepFirst ? singles[m] : singles[k]
                    singles[k] = mergingOpenings(of: dropped, into: survivor)
                    replaced[dropped.id] = survivor.id
                    singles.remove(at: m)
                    continue
                }
                m += 1
            }
            k += 1
        }

        // 3. Single faces → offset outward with an assumed thickness.
        for wall in singles {
            output.append(offsetOutward(wall, rooms: rooms, options: options))
        }

        // 4. Offsetting pulled the corners apart; put them back.
        return Result(walls: closeCorners(output, options: options), replaced: replaced)
    }

    // MARK: Pairing

    /// Overlap and gap when `b` is the far face of the wall `a` belongs to.
    static func facing(_ a: Wall, _ b: Wall, options: Options) -> (overlap: Double, gap: Double)? {
        let direction = a.direction
        let angle = GeometryAngle.difference(direction.angle, b.direction.angle)
        guard min(angle, abs(.pi - angle)) <= options.angleTolerance else { return nil }
        let normal = direction.perpendicular
        let lateralStart = (b.start - a.start).dot(normal)
        let lateralEnd = (b.end - a.start).dot(normal)
        let gap = abs((lateralStart + lateralEnd) / 2)
        guard gap >= options.pairGapMinimum, gap <= options.pairGapMaximum else { return nil }
        let t1 = (b.start - a.start).dot(direction)
        let t2 = (b.end - a.start).dot(direction)
        let overlap = min(max(t1, t2), a.length) - max(min(t1, t2), 0)
        let required = min(options.minimumOverlap, 0.6 * min(a.length, b.length))
        guard overlap >= required else { return nil }
        return (overlap, gap)
    }

    static func isDuplicate(_ a: Wall, _ b: Wall, options: Options) -> Bool {
        let direction = a.direction
        let angle = GeometryAngle.difference(direction.angle, b.direction.angle)
        guard min(angle, abs(.pi - angle)) <= options.angleTolerance else { return false }
        let normal = direction.perpendicular
        let lateral = abs(((b.start - a.start).dot(normal) + (b.end - a.start).dot(normal)) / 2)
        guard lateral <= options.duplicateLateral else { return false }
        let t1 = (b.start - a.start).dot(direction)
        let t2 = (b.end - a.start).dot(direction)
        let overlap = min(max(t1, t2), a.length) - max(min(t1, t2), 0)
        return overlap >= 0.5 * min(a.length, b.length)
    }

    static func rank(_ wall: Wall) -> Int {
        switch wall.confidence {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    /// The wall between two faces: midway, spanning both, as thick as their gap.
    static func centerline(_ a: Wall, _ b: Wall) -> Wall {
        let direction = a.direction
        let normal = direction.perpendicular
        let lateral = ((b.start - a.start).dot(normal) + (b.end - a.start).dot(normal)) / 2
        let base = a.start + normal * (lateral / 2)
        let t1 = (b.start - a.start).dot(direction)
        let t2 = (b.end - a.start).dot(direction)
        let s0 = min(0, min(t1, t2))
        let s1 = max(a.length, max(t1, t2))

        var wall = rank(a) >= rank(b) ? a : b
        wall.start = base + direction * s0
        wall.end = base + direction * s1
        wall.thickness = abs(lateral)
        wall.thicknessSource = .measured
        wall.height = max(a.height, b.height)
        wall.confidence = rank(a) >= rank(b) ? a.confidence : b.confidence
        wall.openings = []
        wall = mergingOpenings(of: a, into: wall)
        wall = mergingOpenings(of: b, into: wall)
        return wall
    }

    /// Re-places `source`'s openings on `target` by their world position,
    /// skipping any that land on an opening `target` already has.
    static func mergingOpenings(of source: Wall, into target: Wall) -> Wall {
        var result = target
        let length = result.length
        guard length > 1e-9 else { return result }
        for opening in source.openings {
            let world = source.point(atOffset: opening.centerOffset)
            let along = (world - result.start).dot(result.direction)
            let overlaps = result.openings.contains { existing in
                abs(existing.centerOffset - along) < max(existing.width, opening.width) / 2
            }
            guard !overlaps else { continue }
            var moved = opening
            let half = min(opening.width, length) / 2
            moved.width = min(opening.width, length)
            moved.centerOffset = min(max(along, half), length - half)
            result.openings.append(moved)
        }
        result.openings.sort { $0.centerOffset < $1.centerOffset }
        return result
    }

    // MARK: Single faces

    /// Moves a lone face to where the wall's centerline must be, given that
    /// the room it bounds is on one side. What lies behind the face decides
    /// the thickness: a neighbouring room's floor edge within pairing range
    /// is the wall's far face (measured); a neighbour further back makes it
    /// a partition (interior default); nothing behind makes it an exterior
    /// wall. When the room side cannot be told — a face inside one floor
    /// polygon that spans both rooms — the face stays put and is marked as
    /// not known to be a centerline.
    static func offsetOutward(_ wall: Wall, rooms: [RoomShape], options: Options) -> Wall {
        var result = wall
        guard let inward = roomSide(of: wall, rooms: rooms, options: options) else {
            result.thicknessSource = nil
            return result
        }
        let outward = inward * -1
        let mid = wall.midpoint
        // The face's own room lies inward; anything the outward ray reaches
        // belongs to a neighbour.
        let own = Set(rooms.filter { room in
            GeometryOps.polygonContains(room.polygon, mid + inward * options.nearProbe)
                || GeometryOps.polygonContains(room.polygon, mid + inward * options.probeDistance)
        }.map(\.id))
        let behind = rooms
            .filter { !own.contains($0.id) }
            .compactMap { GeometryOps.rayDistance(from: mid, direction: outward, polygon: $0.polygon) }
            .min()

        let thickness: Double
        if let behind, behind >= options.pairGapMinimum, behind <= options.pairGapMaximum {
            thickness = behind
            result.thicknessSource = .measured
        } else if let behind, behind <= options.neighbourReach {
            thickness = options.interiorThickness
            result.thicknessSource = .assumed
        } else {
            thickness = options.exteriorThickness
            result.thicknessSource = .assumed
        }
        result.start = wall.start + outward * (thickness / 2)
        result.end = wall.end + outward * (thickness / 2)
        result.thickness = thickness
        return result
    }

    /// Unit normal pointing from a face into the room it bounds, or nil when
    /// no side can be told. Sampled at three points along the face so a door
    /// cut-out or a notch in one polygon cannot mislead, close in first (the
    /// face sits on the room's floor edge) and further out when the floor
    /// polygon stops short of the face.
    static func roomSide(of wall: Wall, rooms: [RoomShape], options: Options) -> Vec2? {
        let normal = wall.direction.perpendicular
        var plus = 0
        var minus = 0
        for fraction in [0.25, 0.5, 0.75] {
            let p = wall.point(atOffset: wall.length * fraction)
            for reach in [options.nearProbe, options.probeDistance] {
                let inPlus = rooms.contains { GeometryOps.polygonContains($0.polygon, p + normal * reach) }
                let inMinus = rooms.contains { GeometryOps.polygonContains($0.polygon, p - normal * reach) }
                if inPlus != inMinus {
                    if inPlus { plus += 1 } else { minus += 1 }
                    break
                }
                // Inside on both sides: this point cannot tell.
                if inPlus { break }
            }
        }
        guard plus != minus else { return nil }
        return plus > minus ? normal : normal * -1
    }

    // MARK: Corners

    /// Offsetting each face by half its thickness leaves neighbours that met
    /// at a corner a few inches apart. This puts every corner back: two
    /// walls meeting at an angle extend to their intersection, collinear
    /// neighbours join end to end, and a wall ending against another (a
    /// partition on an exterior wall) runs on to that wall's centerline.
    /// Openings stay where they were in the world.
    public static func closeCorners(_ walls: [Wall], options: Options = Options()) -> [Wall] {
        guard walls.count >= 2 else { return walls }
        struct End: Hashable {
            var wall: Int
            var isStart: Bool
        }
        func position(_ e: End) -> Vec2 { e.isStart ? walls[e.wall].start : walls[e.wall].end }
        let usable = walls.indices.filter { walls[$0].length > 0.05 }
        let ends = usable.flatMap { [End(wall: $0, isStart: true), End(wall: $0, isStart: false)] }
        let parallelLimit = sin(GeometryAngle.radians(8))

        // Candidate corner pairs, nearest first, each end used once.
        var pairs: [(a: End, b: End, distance: Double)] = []
        for i in ends.indices {
            for j in ends.indices where j > i && ends[i].wall != ends[j].wall {
                let d = position(ends[i]).distance(to: position(ends[j]))
                if d <= options.cornerReach { pairs.append((ends[i], ends[j], d)) }
            }
        }
        pairs.sort { $0.distance < $1.distance }

        var moved: [End: Vec2] = [:]
        for pair in pairs where moved[pair.a] == nil && moved[pair.b] == nil {
            let wa = walls[pair.a.wall]
            let wb = walls[pair.b.wall]
            let pa = position(pair.a)
            let pb = position(pair.b)
            if abs(wa.direction.cross(wb.direction)) < parallelLimit {
                // Collinear neighbours join end to end; a parallel jog stays.
                guard abs((pb - pa).cross(wa.direction)) <= 0.06 else { continue }
                let joint = pa.midpoint(pb)
                moved[pair.a] = joint
                moved[pair.b] = joint
            } else {
                guard let x = GeometryOps.lineIntersection(wa.start, wa.end, wb.start, wb.end),
                      x.distance(to: pa) <= options.cornerReach,
                      x.distance(to: pb) <= options.cornerReach else { continue }
                moved[pair.a] = x
                moved[pair.b] = x
            }
        }

        // Loose ends against another wall run on to its centerline.
        for end in ends where moved[end] == nil {
            let wall = walls[end.wall]
            let p = position(end)
            var best: (point: Vec2, gap: Double)? = nil
            for j in usable where j != end.wall {
                let other = walls[j]
                guard abs(wall.direction.cross(other.direction)) >= parallelLimit else { continue }
                let gap = GeometryOps.distanceToSegment(p, other.start, other.end)
                guard gap <= options.junctionReach,
                      let x = GeometryOps.lineIntersection(wall.start, wall.end, other.start, other.end),
                      x.distance(to: p) <= options.cornerReach else { continue }
                // On the other wall, or just past an end that is itself
                // being extended to this corner.
                let along = (x - other.start).dot(other.direction)
                guard along >= -options.cornerReach, along <= other.length + options.cornerReach else { continue }
                if best == nil || gap < best!.gap { best = (x, gap) }
            }
            if let best { moved[end] = best.point }
        }

        guard !moved.isEmpty else { return walls }
        var result = walls
        for i in result.indices {
            let start = moved[End(wall: i, isStart: true)] ?? walls[i].start
            let end = moved[End(wall: i, isStart: false)] ?? walls[i].end
            result[i] = relocated(walls[i], start: start, end: end)
        }
        return result
    }

    /// The wall with new ends; its openings keep their world positions.
    static func relocated(_ wall: Wall, start: Vec2, end: Vec2) -> Wall {
        var result = wall
        result.start = start
        result.end = end
        let length = result.length
        guard length > 1e-9 else { return result }
        let shift = (wall.start - start).dot(wall.direction)
        result.openings = wall.openings.map { opening in
            var moved = opening
            let width = min(opening.width, length)
            moved.width = width
            moved.centerOffset = min(max(opening.centerOffset + shift, width / 2), length - width / 2)
            return moved
        }
        return result
    }
}
