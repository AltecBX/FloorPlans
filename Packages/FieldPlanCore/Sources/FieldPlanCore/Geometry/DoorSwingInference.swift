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

    /// Which jamb carries the hinges.
    ///
    /// The rule a drafter uses is about the corner, not the room: hinge on the
    /// jamb nearer the wall's end, so the open leaf lies back along the
    /// adjacent wall instead of standing out into the middle of the space. A
    /// bathroom door tight to a corner hinges on the corner side — that is the
    /// case a "swings into the smaller room" rule alone gets wrong.
    ///
    /// Only when the opening sits genuinely mid-wall (both jambs a similar
    /// distance from a corner) does the leaf's clearance inside the room it
    /// serves decide it.
    ///
    /// Nothing in a LiDAR scan records the hinge side — RoomPlan reports the
    /// hole in the wall, and reports it the same way whether the door was open
    /// or shut — so this is inference, and the editor's flip is the last word.
    private static func hingesAtWallStart(
        opening: WallOpening,
        wall: Wall,
        level: LevelGeometry,
        swingSide: Vec2,
        servedRoom: RoomShape?
    ) -> Bool {
        let direction = wall.direction
        let width = opening.width

        // Distance from each jamb to its nearer end of the host wall.
        let startGap = opening.startOffset
        let endGap = wall.length - opening.endOffset
        let decisive = max(width * 0.5, 0.15)
        if abs(startGap - endGap) > decisive {
            return startGap < endGap
        }

        // Centred in the wall: park the leaf where it clears the room best.
        guard let room = servedRoom, room.polygon.count >= 3 else {
            return startGap <= endGap
        }
        let startJamb = wall.start + direction * opening.startOffset
        let endJamb = wall.start + direction * opening.endOffset
        let fromStart = GeometryOps.distanceToPolygonBoundary(room.polygon, startJamb + swingSide * width)
        let fromEnd = GeometryOps.distanceToPolygonBoundary(room.polygon, endJamb + swingSide * width)
        if abs(fromStart - fromEnd) < 0.05 { return startGap <= endGap }
        return fromStart < fromEnd
    }
}
