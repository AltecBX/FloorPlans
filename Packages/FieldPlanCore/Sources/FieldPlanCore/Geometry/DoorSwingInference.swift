import Foundation

// A LiDAR scan sees a hole in a wall. It does not see which jamb carries the
// hinges or which way the leaf travels — and a plan that guesses wrong is worse
// than one that says nothing, because a client reads a door swinging into the
// space where the vanity goes. So the swing is *derived* from the geometry
// around the opening, using the rules a drafter applies, and every derived
// swing stays overridable by hand in the editor (`WallOpening.swing`).

public enum DoorSwingInference {

    /// How far past the wall face to probe when deciding which rooms an opening
    /// connects. Far enough to clear the wall, close enough to stay inside a
    /// narrow hallway.
    static let probeDistance = 0.30

    /// Reads the hinge side and swing direction for `opening` from the rooms and
    /// walls around it.
    ///
    /// Swing side, in the order a drafter decides it:
    ///  1. A door between a room and the outside swings **in**.
    ///  2. A door out of a closet or pantry swings **out** — there is no room
    ///     inside for a leaf.
    ///  3. A door off a hallway, foyer or stair swings **into the room** it
    ///     serves, never back into the circulation space.
    ///  4. Otherwise it swings into the **smaller** of the two rooms.
    ///
    /// Hinge side: whichever jamb is nearer a wall the leaf can lie back
    /// against, so an open door does not stand in the middle of the room.
    public static func swing(
        for opening: WallOpening,
        on wall: Wall,
        in level: LevelGeometry
    ) -> DoorSwing {
        let direction = wall.direction
        let perpendicular = direction.perpendicular
        let center = wall.start + direction * opening.centerOffset
        let reach = wall.thickness / 2 + probeDistance

        let positiveRoom = level.rooms.first {
            GeometryOps.polygonContains($0.polygon, center + perpendicular * reach)
        }
        let negativeRoom = level.rooms.first {
            GeometryOps.polygonContains($0.polygon, center - perpendicular * reach)
        }

        let opensPositive = opensTowardPositiveSide(positiveRoom, negativeRoom)
        let served = opensPositive ? positiveRoom : negativeRoom
        let hingeAtStart = hingesAtWallStart(
            opening: opening, wall: wall, level: level,
            swingSide: opensPositive ? perpendicular : -perpendicular,
            servedRoom: served)

        return DoorSwing(hingeAtStart: hingeAtStart, opensPositiveSide: opensPositive)
    }

    /// Applies inference to every door on the level that has no hand-set swing.
    public static func resolvingSwings(in level: LevelGeometry) -> LevelGeometry {
        var result = level
        for wallIndex in result.walls.indices {
            let wall = result.walls[wallIndex]
            for openingIndex in wall.openings.indices where wall.openings[openingIndex].kind == .door {
                guard wall.openings[openingIndex].swing == nil else { continue }
                result.walls[wallIndex].openings[openingIndex].swing =
                    swing(for: wall.openings[openingIndex], on: wall, in: level)
            }
        }
        return result
    }

    // MARK: - Rules

    private static func opensTowardPositiveSide(
        _ positiveRoom: RoomShape?,
        _ negativeRoom: RoomShape?
    ) -> Bool {
        switch (positiveRoom, negativeRoom) {
        case (.some, .none):
            return true      // exterior on the far side: swing in
        case (.none, .some):
            return false
        case (.none, .none):
            return true      // no rooms resolved; the default is as good as any
        case let (.some(positive), .some(negative)):
            // Out of a closet, into everything else.
            if isTight(positive.type) && !isTight(negative.type) { return false }
            if isTight(negative.type) && !isTight(positive.type) { return true }
            // Off circulation, into the room being served.
            if isCirculation(positive.type) && !isCirculation(negative.type) { return false }
            if isCirculation(negative.type) && !isCirculation(positive.type) { return true }
            // Two ordinary rooms: into the smaller one.
            return positive.floorArea <= negative.floorArea
        }
    }

    /// Rooms with no floor space to receive a door leaf.
    private static func isTight(_ type: RoomType) -> Bool {
        switch type {
        case .closet, .walkInCloset, .storage: return true
        default: return false
        }
    }

    /// Spaces a door must not block when it opens.
    private static func isCirculation(_ type: RoomType) -> Bool {
        switch type {
        case .hallway, .foyer, .stairHall: return true
        default: return false
        }
    }

    /// The leaf should end up against a wall, not across the room. For each
    /// jamb, look at where the leaf tip would land when open and measure how
    /// far that is from the served room's edge; hinge on the side that parks
    /// the leaf closest to a boundary.
    private static func hingesAtWallStart(
        opening: WallOpening,
        wall: Wall,
        level: LevelGeometry,
        swingSide: Vec2,
        servedRoom: RoomShape?
    ) -> Bool {
        let direction = wall.direction
        let width = opening.width
        let startJamb = wall.start + direction * opening.startOffset
        let endJamb = wall.start + direction * opening.endOffset

        // Leaf tip when hinged at each jamb, opened 90° into the swing side.
        let tipFromStart = startJamb + swingSide * width
        let tipFromEnd = endJamb + swingSide * width

        guard let room = servedRoom, room.polygon.count >= 3 else {
            // No room to reason about: hinge on the jamb nearer the wall's end,
            // which is usually where a perpendicular wall meets it.
            return opening.centerOffset > wall.length / 2
        }

        let fromStart = GeometryOps.distanceToPolygonBoundary(room.polygon, tipFromStart)
        let fromEnd = GeometryOps.distanceToPolygonBoundary(room.polygon, tipFromEnd)
        if abs(fromStart - fromEnd) < 0.05 {
            // Symmetric: fall back to the nearer wall end.
            return opening.centerOffset > wall.length / 2
        }
        return fromStart < fromEnd
    }
}
