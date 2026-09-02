import Foundation

// MARK: - Plan editing engine (spec §16, §17)
//
// Pure functions over LevelGeometry. The SwiftUI editor calls these and keeps
// its own undo stack of LevelGeometry snapshots; nothing here mutates in
// place or performs I/O, which keeps every edit unit-testable.

/// How an exact length edit is applied to a wall.
public enum LengthEditStrategy: String, Codable, CaseIterable, Sendable {
    /// Move the END point along the wall axis; walls connected at that corner
    /// stretch to follow (right angles of perpendicular neighbors are kept).
    case moveEnd
    /// Move the START point along the wall axis; connected walls follow.
    case moveStart
    /// Grow/shrink symmetrically about the wall midpoint; both corners'
    /// neighbors follow.
    case symmetric
    /// Rigidly translate everything connected beyond the END point (pushes
    /// the adjacent room/walls without distorting them). Falls back to
    /// `.moveEnd` when the far side loops back to the start (closed room).
    case pushBeyondEnd

    public var displayName: String {
        switch self {
        case .moveEnd: return "Move End Point"
        case .moveStart: return "Move Start Point"
        case .symmetric: return "Adjust Both Ends"
        case .pushBeyondEnd: return "Push Connected Walls"
        }
    }
}

public enum EditorEngine {

    // MARK: - Vertex + wall movement

    /// Free-form vertex drag: every wall endpoint within `tolerance` of
    /// `from` moves to `to`; neighbors stretch/slant to stay attached.
    /// Used for direct corner dragging in the editor.
    public static func moveCornerFree(
        in level: LevelGeometry,
        from: Vec2,
        to: Vec2,
        tolerance: Double = 0.08
    ) -> LevelGeometry {
        var result = level
        var touched: Set<UUID> = []
        for i in result.walls.indices {
            if result.walls[i].start.distance(to: from) <= tolerance {
                result.walls[i] = adjustingEndpoint(result.walls[i], newStart: to, newEnd: nil)
                touched.insert(result.walls[i].id)
            }
            if result.walls[i].end.distance(to: from) <= tolerance {
                result.walls[i] = adjustingEndpoint(result.walls[i], newStart: nil, newEnd: to)
                touched.insert(result.walls[i].id)
            }
        }
        return rebuildRooms(in: result, touchedWallIDs: touched)
    }

    /// Angle-preserving corner move (spec §17 "preserve adjacent wall
    /// angles"). The moved corner's delta is decomposed against each attached
    /// wall: the component along the wall stretches it (direction preserved);
    /// the perpendicular component translates the wall rigidly, propagating
    /// the move to its far corner. In a 10×10 room, setting one wall to 12'
    /// therefore yields a clean 12×10 rectangle instead of slanted walls.
    public static func moveCorner(
        in level: LevelGeometry,
        from: Vec2,
        to: Vec2,
        tolerance: Double = 0.08
    ) -> LevelGeometry {
        propagateCornerMoves(in: level, seeds: [(from, to - from)], tolerance: tolerance)
    }

    /// Translates an entire wall by `delta` with angle-preserving
    /// propagation: perpendicular neighbors stretch along their own axes, so
    /// pushing a wall outward widens the room without slanting anything.
    public static func translateWall(
        in level: LevelGeometry,
        wallID: UUID,
        delta: Vec2,
        tolerance: Double = 0.08
    ) -> LevelGeometry {
        guard let wall = level.wall(withID: wallID) else { return level }
        return propagateCornerMoves(
            in: level,
            seeds: [(wall.start, delta), (wall.end, delta)],
            tolerance: tolerance
        )
    }

    /// Shared constraint propagation. Each seed is (corner position, delta).
    private static func propagateCornerMoves(
        in level: LevelGeometry,
        seeds: [(Vec2, Vec2)],
        tolerance: Double
    ) -> LevelGeometry {
        let activeSeeds = seeds.filter { $0.1.length > 1e-12 }
        guard !activeSeeds.isEmpty else { return level }

        func key(_ p: Vec2) -> String {
            // Quantize at half the tolerance so clustered corners share a key.
            let q = max(tolerance / 2, 1e-6)
            return "\(Int((p.x / q).rounded())):\(Int((p.y / q).rounded()))"
        }

        // Corner deltas discovered by propagation (original positions).
        var cornerDelta: [String: (position: Vec2, delta: Vec2)] = [:]
        var queue: [(Vec2, Vec2)] = []
        for (position, delta) in activeSeeds {
            cornerDelta[key(position)] = (position, delta)
            queue.append((position, delta))
        }
        var iterations = 0

        while !queue.isEmpty && iterations < 256 {
            iterations += 1
            let (corner, d) = queue.removeFirst()
            for wall in level.walls {
                let startHere = wall.start.distance(to: corner) <= tolerance
                let endHere = wall.end.distance(to: corner) <= tolerance
                guard startHere || endHere else { continue }
                guard wall.length > 1e-9 else { continue }
                let axis = wall.direction
                let along = d.dot(axis)
                let perp = d - axis * along
                guard perp.length > 1e-9 else { continue }
                let farCorner = startHere ? wall.end : wall.start
                let farKey = key(farCorner)
                if cornerDelta[farKey] == nil {
                    cornerDelta[farKey] = (farCorner, perp)
                    queue.append((farCorner, perp))
                }
            }
        }

        // Apply all corner moves against the ORIGINAL geometry.
        var result = level
        var touched: Set<UUID> = []
        for i in result.walls.indices {
            let original = level.walls[i]
            var newStart: Vec2? = nil
            var newEnd: Vec2? = nil
            for (_, move) in cornerDelta {
                if original.start.distance(to: move.position) <= tolerance {
                    newStart = original.start + move.delta
                }
                if original.end.distance(to: move.position) <= tolerance {
                    newEnd = original.end + move.delta
                }
            }
            if newStart != nil || newEnd != nil {
                result.walls[i] = adjustingEndpoint(original, newStart: newStart, newEnd: newEnd)
                touched.insert(original.id)
            }
        }
        return rebuildRooms(in: result, touchedWallIDs: touched)
    }

    // MARK: - Exact length editing (spec §17)

    /// Sets a wall's length to an exact value using the chosen strategy.
    /// The wall's original captured length is preserved in `originalLength`
    /// the first time it is edited; its source becomes `.edited`.
    public static func setWallLength(
        in level: LevelGeometry,
        wallID: UUID,
        newLength: Double,
        strategy: LengthEditStrategy,
        tolerance: Double = 0.08
    ) -> LevelGeometry {
        guard newLength > 0.01 else { return level }
        guard let wall = level.wall(withID: wallID) else { return level }
        let axis = wall.direction
        guard axis.length > 0.5 else { return level } // degenerate
        let delta = newLength - wall.length
        guard abs(delta) > 1e-9 else { return level }

        var result = level

        func markEdited(_ w: inout Wall) {
            if w.originalLength == nil { w.originalLength = wall.length }
            w.source = .edited
        }

        switch strategy {
        case .moveEnd:
            let newEnd = wall.start + axis * newLength
            result = moveCorner(in: result, from: wall.end, to: newEnd, tolerance: tolerance)
        case .moveStart:
            let newStart = wall.end - axis * newLength
            result = moveCorner(in: result, from: wall.start, to: newStart, tolerance: tolerance)
        case .symmetric:
            let mid = wall.midpoint
            let newStart = mid - axis * (newLength / 2)
            let newEnd = mid + axis * (newLength / 2)
            result = moveCorner(in: result, from: wall.start, to: newStart, tolerance: tolerance)
            // Re-fetch: the wall's end hasn't moved yet.
            if let updated = result.wall(withID: wallID) {
                result = moveCorner(in: result, from: updated.end, to: newEnd, tolerance: tolerance)
            }
        case .pushBeyondEnd:
            result = pushBeyondEnd(in: result, wall: wall, delta: delta, tolerance: tolerance)
        }

        if let i = result.walls.firstIndex(where: { $0.id == wallID }) {
            markEdited(&result.walls[i])
            // Keep openings within the resized wall.
            let len = result.walls[i].length
            for j in result.walls[i].openings.indices {
                let o = result.walls[i].openings[j]
                let clamped = min(max(o.centerOffset, o.width / 2), max(o.width / 2, len - o.width / 2))
                result.walls[i].openings[j].centerOffset = clamped
            }
        }
        return result
    }

    /// Rigid translation of the connected component beyond the wall's end.
    private static func pushBeyondEnd(
        in level: LevelGeometry,
        wall: Wall,
        delta: Double,
        tolerance: Double
    ) -> LevelGeometry {
        let graph = WallGraph(walls: level.walls, tolerance: tolerance)
        guard let wallIndex = level.walls.firstIndex(where: { $0.id == wall.id }) else { return level }
        let (startNode, endNode) = graph.wallNodes[wallIndex]

        // Breadth-first from the end node, excluding travel through this wall.
        var reachable: Set<Int> = [endNode]
        var queue = [endNode]
        while let node = queue.popLast() {
            for (wi, isStart) in graph.nodes[node].attachments where wi != wallIndex {
                let other = isStart ? graph.wallNodes[wi].end : graph.wallNodes[wi].start
                if !reachable.contains(other) {
                    reachable.insert(other)
                    queue.append(other)
                }
            }
        }

        if reachable.contains(startNode) {
            // Closed loop back to the start: rigid push impossible; stretch.
            let axis = wall.direction
            let newEnd = wall.start + axis * (wall.length + delta)
            return moveCorner(in: level, from: wall.end, to: newEnd, tolerance: tolerance)
        }

        let translation = wall.direction * delta
        var result = level
        var touched: Set<UUID> = []
        for (wi, mapping) in graph.wallNodes.enumerated() {
            var w = result.walls[wi]
            var changed = false
            if wi == wallIndex {
                w.end += translation
                changed = true
            } else {
                if reachable.contains(mapping.start) {
                    w.start += translation
                    changed = true
                }
                if reachable.contains(mapping.end) {
                    w.end += translation
                    changed = true
                }
            }
            if changed {
                result.walls[wi] = w
                touched.insert(w.id)
            }
        }
        // Move fixtures that sit in pushed rooms? Fixtures follow only when
        // fully on the far side — keep predictable: fixtures stay put.
        return rebuildRooms(in: result, touchedWallIDs: touched)
    }

    // MARK: - Wall add / delete / split

    public static func addWall(
        to level: LevelGeometry,
        from: Vec2,
        to end: Vec2,
        height: Double,
        thickness: Double = 0.1143,
        changeStatus: ChangeStatus = .existing,
        snapTolerance: Double = 0.15
    ) -> (LevelGeometry, Wall) {
        var result = level
        // Snap endpoints to existing corners when close.
        let snappedStart = nearestCorner(in: level, to: from, tolerance: snapTolerance) ?? from
        let snappedEnd = nearestCorner(in: level, to: end, tolerance: snapTolerance) ?? end
        let wall = Wall(
            start: snappedStart,
            end: snappedEnd,
            height: height,
            thickness: thickness,
            changeStatus: changeStatus,
            source: .manualEntry,
            confidence: .high
        )
        result.walls.append(wall)
        return (result, wall)
    }

    public static func deleteWall(in level: LevelGeometry, wallID: UUID) -> LevelGeometry {
        var result = level
        result.walls.removeAll { $0.id == wallID }
        for i in result.rooms.indices {
            result.rooms[i].wallIDs.removeAll { $0 == wallID }
        }
        return result
    }

    /// Splits a wall at a distance from its start. Openings stay with the
    /// piece they fall on; an opening spanning the split point blocks the
    /// split (returns nil) rather than silently destroying it.
    public static func splitWall(
        in level: LevelGeometry,
        wallID: UUID,
        atOffset offset: Double
    ) -> LevelGeometry? {
        guard let index = level.walls.firstIndex(where: { $0.id == wallID }) else { return nil }
        let wall = level.walls[index]
        guard offset > 0.05, offset < wall.length - 0.05 else { return nil }
        for o in wall.openings {
            if o.startOffset < offset && o.endOffset > offset { return nil }
        }
        let splitPoint = wall.point(atOffset: offset)

        var first = wall
        first.end = splitPoint
        first.openings = wall.openings.filter { $0.endOffset <= offset }

        var second = wall
        second.id = UUID()
        second.start = splitPoint
        second.openings = wall.openings
            .filter { $0.startOffset >= offset }
            .map { o in
                var moved = o
                moved.centerOffset = o.centerOffset - offset
                return moved
            }
        second.originalLength = nil

        var result = level
        result.walls[index] = first
        result.walls.insert(second, at: index + 1)
        for i in result.rooms.indices {
            if let pos = result.rooms[i].wallIDs.firstIndex(of: wallID) {
                result.rooms[i].wallIDs.insert(second.id, at: pos + 1)
            }
        }
        return result
    }

    // MARK: - Openings

    /// Adds an opening centered at `centerOffset`, clamped inside the wall.
    /// Returns nil when the opening cannot fit or overlaps an existing one.
    public static func addOpening(
        in level: LevelGeometry,
        wallID: UUID,
        kind: OpeningKind,
        centerOffset: Double,
        width: Double,
        height: Double,
        sillHeight: Double = 0,
        changeStatus: ChangeStatus = .existing
    ) -> (LevelGeometry, WallOpening)? {
        guard let index = level.walls.firstIndex(where: { $0.id == wallID }) else { return nil }
        let wall = level.walls[index]
        guard width > 0.05, width <= wall.length else { return nil }
        let clampedCenter = min(max(centerOffset, width / 2), wall.length - width / 2)
        let newStart = clampedCenter - width / 2
        let newEnd = clampedCenter + width / 2
        for o in wall.openings {
            if newStart < o.endOffset && newEnd > o.startOffset { return nil }
        }
        let opening = WallOpening(
            kind: kind,
            centerOffset: clampedCenter,
            width: width,
            height: height,
            sillHeight: kind == .window ? max(sillHeight, 0) : 0,
            // Derived from the surrounding rooms until set by hand.
            swing: nil,
            changeStatus: changeStatus,
            source: .manualEntry,
            confidence: .high
        )
        var result = level
        result.walls[index].openings.append(opening)
        result.walls[index].openings.sort { $0.centerOffset < $1.centerOffset }
        return (result, opening)
    }

    public static func updateOpening(
        in level: LevelGeometry,
        wallID: UUID,
        opening: WallOpening
    ) -> LevelGeometry {
        var result = level
        guard let wi = result.walls.firstIndex(where: { $0.id == wallID }),
              let oi = result.walls[wi].openings.firstIndex(where: { $0.id == opening.id })
        else { return level }
        var updated = opening
        let wall = result.walls[wi]
        updated.width = min(updated.width, wall.length)
        updated.centerOffset = min(max(updated.centerOffset, updated.width / 2), wall.length - updated.width / 2)
        result.walls[wi].openings[oi] = updated
        return result
    }

    public static func deleteOpening(in level: LevelGeometry, openingID: UUID) -> LevelGeometry {
        var result = level
        for i in result.walls.indices {
            result.walls[i].openings.removeAll { $0.id == openingID }
        }
        return result
    }

    // MARK: - Fixtures

    public static func addFixture(to level: LevelGeometry, _ fixture: FixtureItem) -> LevelGeometry {
        var result = level
        var placed = fixture
        placed.roomID = level.rooms.first { GeometryOps.polygonContains($0.polygon, fixture.center) }?.id
        result.fixtures.append(placed)
        return result
    }

    public static func updateFixture(in level: LevelGeometry, _ fixture: FixtureItem) -> LevelGeometry {
        var result = level
        guard let i = result.fixtures.firstIndex(where: { $0.id == fixture.id }) else { return level }
        var updated = fixture
        updated.roomID = level.rooms.first { GeometryOps.polygonContains($0.polygon, fixture.center) }?.id
        result.fixtures[i] = updated
        return result
    }

    public static func deleteFixture(in level: LevelGeometry, fixtureID: UUID) -> LevelGeometry {
        var result = level
        result.fixtures.removeAll { $0.id == fixtureID }
        return result
    }

    // MARK: - Rooms

    public static func renameRoom(
        in level: LevelGeometry, roomID: UUID, name: String, type: RoomType? = nil
    ) -> LevelGeometry {
        var result = level
        guard let i = result.rooms.firstIndex(where: { $0.id == roomID }) else { return level }
        result.rooms[i].name = name
        if let type { result.rooms[i].type = type }
        return result
    }

    public static func setCeilingHeight(
        in level: LevelGeometry, roomID: UUID, height: Double, source: MeasurementSource
    ) -> LevelGeometry {
        var result = level
        guard let i = result.rooms.firstIndex(where: { $0.id == roomID }) else { return level }
        result.rooms[i].ceilingHeight = height
        result.rooms[i].ceilingHeightSource = source
        return result
    }

    /// Merges two rooms that share boundary walls: the shared walls are
    /// removed from the combined loop and the polygon is rebuilt. Returns nil
    /// when the rooms don't share a wall or the merged loop doesn't close.
    public static func mergeRooms(
        in level: LevelGeometry, roomA: UUID, roomB: UUID
    ) -> LevelGeometry? {
        guard let a = level.room(withID: roomA), let b = level.room(withID: roomB) else { return nil }
        let setA = Set(a.wallIDs)
        let setB = Set(b.wallIDs)
        let shared = setA.intersection(setB)
        guard !shared.isEmpty else { return nil }
        let keepIDs = setA.union(setB).subtracting(shared)
        let keepWalls = level.walls.filter { keepIDs.contains($0.id) }
        guard let polygon = GeometryCleaner.loopPolygon(from: keepWalls, tolerance: 0.2) else { return nil }

        var result = level
        var merged = a
        merged.polygon = polygon
        merged.wallIDs = keepWalls.map(\.id)
        merged.ceilingHeight = a.ceilingHeight ?? b.ceilingHeight
        if let ai = result.rooms.firstIndex(where: { $0.id == roomA }) {
            result.rooms[ai] = merged
        }
        result.rooms.removeAll { $0.id == roomB }
        // Interior shared walls are usually demolished rather than deleted;
        // leave them in the wall list so the user decides. Rooms no longer
        // reference them.
        return result
    }

    /// Splits a room polygon with a cut segment that crosses exactly two
    /// edges. Returns nil when the cut doesn't produce two valid rooms.
    public static func splitRoom(
        in level: LevelGeometry, roomID: UUID, cutA: Vec2, cutB: Vec2
    ) -> LevelGeometry? {
        guard let room = level.room(withID: roomID) else { return nil }
        let polygon = room.polygon
        let n = polygon.count
        guard n >= 3 else { return nil }

        // Extend the cut segment generously so taps near walls work.
        let dir = (cutB - cutA).normalized
        guard dir.length > 0.5 else { return nil }
        let a = cutA - dir * 100
        let b = cutB + dir * 100

        var hits: [(edge: Int, t: Double, point: Vec2)] = []
        for i in 0..<n {
            let p1 = polygon[i]
            let p2 = polygon[(i + 1) % n]
            if let hit = GeometryOps.segmentIntersection(a, b, p1, p2) {
                hits.append((i, hit.u, hit.point))
            }
        }
        guard hits.count == 2 else { return nil }
        let h1 = hits[0]
        let h2 = hits[1]

        // Walk the polygon building both sides.
        var sideA: [Vec2] = [h1.point]
        var i = (h1.edge + 1) % n
        while true {
            sideA.append(polygon[i])
            if i == h2.edge { break }
            i = (i + 1) % n
            if sideA.count > n + 2 { return nil }
        }
        sideA.append(h2.point)

        var sideB: [Vec2] = [h2.point]
        i = (h2.edge + 1) % n
        while true {
            sideB.append(polygon[i])
            if i == h1.edge { break }
            i = (i + 1) % n
            if sideB.count > n + 2 { return nil }
        }
        sideB.append(h1.point)

        let polyA = GeometryOps.counterClockwise(GeometryOps.simplified(sideA))
        let polyB = GeometryOps.counterClockwise(GeometryOps.simplified(sideB))
        guard polyA.count >= 3, polyB.count >= 3 else { return nil }
        guard GeometryOps.area(polyA) > 0.3, GeometryOps.area(polyB) > 0.3 else { return nil }

        var result = level
        guard let index = result.rooms.firstIndex(where: { $0.id == roomID }) else { return nil }
        var first = room
        first.polygon = polyA
        first.wallIDs = []
        var second = room
        second.id = UUID()
        second.name = room.name + " 2"
        second.polygon = polyB
        second.wallIDs = []
        result.rooms[index] = first
        result.rooms.insert(second, at: index + 1)
        return result
    }

    // MARK: - Change status (renovation markup)

    public static func setWallChangeStatus(
        in level: LevelGeometry, wallID: UUID, status: ChangeStatus
    ) -> LevelGeometry {
        var result = level
        guard let i = result.walls.firstIndex(where: { $0.id == wallID }) else { return level }
        result.walls[i].changeStatus = status
        // Openings on a demolished wall are demolished with it.
        if status == .demolish {
            for j in result.walls[i].openings.indices {
                result.walls[i].openings[j].changeStatus = .demolish
            }
        }
        return result
    }

    public static func setOpeningChangeStatus(
        in level: LevelGeometry, openingID: UUID, status: ChangeStatus
    ) -> LevelGeometry {
        var result = level
        for i in result.walls.indices {
            for j in result.walls[i].openings.indices
            where result.walls[i].openings[j].id == openingID {
                result.walls[i].openings[j].changeStatus = status
            }
        }
        return result
    }

    public static func setFixtureChangeStatus(
        in level: LevelGeometry, fixtureID: UUID, status: ChangeStatus
    ) -> LevelGeometry {
        var result = level
        guard let i = result.fixtures.firstIndex(where: { $0.id == fixtureID }) else { return level }
        result.fixtures[i].changeStatus = status
        return result
    }

    // MARK: - Annotations

    public static func addAnnotation(to level: LevelGeometry, _ annotation: PlanAnnotation) -> LevelGeometry {
        var result = level
        result.annotations.append(annotation)
        return result
    }

    public static func deleteAnnotation(in level: LevelGeometry, annotationID: UUID) -> LevelGeometry {
        var result = level
        result.annotations.removeAll { $0.id == annotationID }
        return result
    }

    // MARK: - Endpoint adjustment

    /// Returns the wall with endpoints replaced, re-projecting openings so
    /// they keep their physical (world) location on the new wall axis, then
    /// clamping them inside the wall. Never drops an opening.
    static func adjustingEndpoint(_ wall: Wall, newStart: Vec2?, newEnd: Vec2?) -> Wall {
        var result = wall
        // World positions of openings before the move.
        let worldCenters = wall.openings.map { wall.point(atOffset: $0.centerOffset) }
        result.start = newStart ?? wall.start
        result.end = newEnd ?? wall.end
        let newLength = result.length
        guard newLength > 1e-9 else { return result }
        let axis = result.direction
        for i in result.openings.indices {
            let projected = (worldCenters[i] - result.start).dot(axis)
            let halfWidth = min(result.openings[i].width, newLength) / 2
            result.openings[i].width = min(result.openings[i].width, newLength)
            result.openings[i].centerOffset = min(max(projected, halfWidth), newLength - halfWidth)
        }
        return result
    }

    // MARK: - Snapping helpers

    /// Nearest existing wall corner within tolerance, for endpoint snapping.
    public static func nearestCorner(
        in level: LevelGeometry, to point: Vec2, tolerance: Double
    ) -> Vec2? {
        var best: Vec2? = nil
        var bestDist = tolerance
        for wall in level.walls {
            for candidate in [wall.start, wall.end] {
                let d = candidate.distance(to: point)
                if d < bestDist {
                    bestDist = d
                    best = candidate
                }
            }
        }
        return best
    }

    /// Snaps an angle to the nearest orthogonal/45° direction when within
    /// `snapDegrees`. Used by the optional ortho tool — never automatic.
    public static func orthoSnappedDirection(_ direction: Vec2, snapDegrees: Double = 7) -> Vec2 {
        let angle = direction.angle
        let step = Double.pi / 4
        let snapped = (angle / step).rounded() * step
        if GeometryAngle.difference(angle, snapped) <= GeometryAngle.radians(snapDegrees) {
            return Vec2(cos(snapped), sin(snapped))
        }
        return direction
    }

    // MARK: - Room polygon rebuild

    /// Recomputes polygons of rooms whose bounding walls changed, using the
    /// wall loop. Rooms whose loop no longer closes keep their old polygon —
    /// the QA engine reports the discrepancy instead of geometry silently
    /// changing shape.
    static func rebuildRooms(in level: LevelGeometry, touchedWallIDs: Set<UUID>) -> LevelGeometry {
        guard !touchedWallIDs.isEmpty else { return level }
        var result = level
        for i in result.rooms.indices {
            let room = result.rooms[i]
            guard !room.wallIDs.isEmpty else { continue }
            guard !Set(room.wallIDs).isDisjoint(with: touchedWallIDs) else { continue }
            let walls = room.wallIDs.compactMap { id in result.walls.first { $0.id == id } }
            guard walls.count >= 3 else { continue }
            if let polygon = GeometryCleaner.loopPolygon(from: walls, tolerance: 0.2) {
                // The loop follows the centerlines; the room is inside the faces.
                result.rooms[i].polygon = GeometryCleaner.interiorPolygon(fromCenterlineLoop: polygon, walls: walls)
            }
        }
        return result
    }
}
