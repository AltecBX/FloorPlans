import Foundation

// MARK: - Moving a whole level (brief §14, §18)
//
// Levels scanned in one continuous session share a frame and stack on their
// own. Levels scanned in separate sessions do not, and a second floor that
// lands rotated or shifted against the first is a plan nobody can use. These
// are the rigid moves that fix that: a translation, a rotation, and an
// automatic alignment on the one thing every stacked floor shares — the
// staircase.

public enum LevelRegistration {

    /// Every element moved by `delta`. Wall openings keep their offsets.
    public static func translated(_ level: LevelGeometry, by delta: Vec2) -> LevelGeometry {
        var result = level
        for i in result.walls.indices {
            result.walls[i].start += delta
            result.walls[i].end += delta
        }
        for i in result.rooms.indices {
            result.rooms[i].polygon = result.rooms[i].polygon.map { $0 + delta }
        }
        for i in result.fixtures.indices {
            result.fixtures[i].center += delta
        }
        for i in result.annotations.indices {
            result.annotations[i].position += delta
            result.annotations[i].pointA = result.annotations[i].pointA.map { $0 + delta }
            result.annotations[i].pointB = result.annotations[i].pointB.map { $0 + delta }
        }
        return result
    }

    /// Every element rotated by `angle` (radians, counter-clockwise) about
    /// `pivot`. North turns with the plan so the arrow stays true.
    public static func rotated(_ level: LevelGeometry, by angle: Double, about pivot: Vec2) -> LevelGeometry {
        func turn(_ p: Vec2) -> Vec2 { p.rotated(by: angle, around: pivot) }
        var result = level
        for i in result.walls.indices {
            result.walls[i].start = turn(result.walls[i].start)
            result.walls[i].end = turn(result.walls[i].end)
        }
        for i in result.rooms.indices {
            result.rooms[i].polygon = result.rooms[i].polygon.map(turn)
        }
        for i in result.fixtures.indices {
            result.fixtures[i].center = turn(result.fixtures[i].center)
            result.fixtures[i].rotation += angle
        }
        for i in result.annotations.indices {
            result.annotations[i].position = turn(result.annotations[i].position)
            result.annotations[i].pointA = result.annotations[i].pointA.map(turn)
            result.annotations[i].pointB = result.annotations[i].pointB.map(turn)
        }
        if let north = result.northAngle {
            result.northAngle = GeometryAngle.normalize(north + angle)
        }
        return result
    }

    /// Shifts `level` so its staircase sits over `reference`'s. Uses the
    /// closest pair when either level has several. Nil when either has none.
    public static func alignByStairs(_ level: LevelGeometry, to reference: LevelGeometry) -> (level: LevelGeometry, shift: Vec2)? {
        let mine = level.fixtures.filter { $0.category == .stairs }
        let theirs = reference.fixtures.filter { $0.category == .stairs }
        guard !mine.isEmpty, !theirs.isEmpty else { return nil }
        var best: (shift: Vec2, distance: Double)? = nil
        for a in mine {
            for b in theirs {
                let shift = b.center - a.center
                if best == nil || shift.length < best!.distance { best = (shift, shift.length) }
            }
        }
        guard let best else { return nil }
        return (translated(level, by: best.shift), best.shift)
    }

    /// Fallback alignment: puts the centre of `level`'s footprint over the
    /// centre of `reference`'s. Right for a house whose floors share an
    /// outline; only a starting point otherwise.
    public static func alignByFootprint(_ level: LevelGeometry, to reference: LevelGeometry) -> (level: LevelGeometry, shift: Vec2)? {
        let mine = level.bounds
        let theirs = reference.bounds
        guard !mine.isNull, !theirs.isNull else { return nil }
        let shift = theirs.center - mine.center
        return (translated(level, by: shift), shift)
    }
}
