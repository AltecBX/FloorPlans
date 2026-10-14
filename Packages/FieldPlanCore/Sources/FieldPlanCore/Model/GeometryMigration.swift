import Foundation

// MARK: - Geometry schema migration
//
// Version 1 files put scanned walls on the wall *surface* RoomPlan reported.
// Version 2 puts them on the centerline with a thickness that is either
// measured (two faces) or assumed (one face), so the drawing, the 3D model
// and the room polygon finally agree. Old files are migrated on load using
// the rooms beside each wall — the same evidence the scan had — and any wall
// the rooms cannot place is left exactly where it was and marked as such.

public enum GeometryMigration {
    public static let currentSchemaVersion = 2

    public static func migrate(_ snapshot: PlanSnapshot) -> PlanSnapshot {
        let version = snapshot.schemaVersion ?? 1
        guard version < currentSchemaVersion else { return snapshot }
        var result = snapshot
        if version < 2 {
            result.levels = result.levels.map(surfaceLinesToCenterlines)
        }
        result.schemaVersion = currentSchemaVersion
        return result
    }

    /// Moves version-1 scanned walls from the face they were captured on to
    /// the centerline the rooms around them imply. Sample, manual and
    /// already-placed walls are untouched.
    public static func surfaceLinesToCenterlines(_ level: LevelGeometry) -> LevelGeometry {
        var result = level
        var movedIndices: [Int] = []
        for i in result.walls.indices {
            let wall = result.walls[i]
            guard wall.source == .lidarScanned, wall.thicknessSource == nil, wall.length > 0.05 else { continue }
            let placed = centerline(for: wall, rooms: level.rooms)
            if placed.thicknessSource != nil {
                result.walls[i] = placed
                movedIndices.append(i)
            }
        }
        // The shifted walls no longer meet at their corners; close them among
        // themselves, leaving every wall that did not move alone.
        guard movedIndices.count >= 2 else { return result }
        let closed = WallAssembly.closeCorners(movedIndices.map { result.walls[$0] })
        for (k, i) in movedIndices.enumerated() { result.walls[i] = closed[k] }
        return result
    }

    static func centerline(for wall: Wall, rooms: [RoomShape], probe: Double = 0.30) -> Wall {
        let normal = wall.direction.perpendicular
        let mid = wall.midpoint
        let plusRoom = rooms.first { GeometryOps.polygonContains($0.polygon, mid + normal * probe) }
        let minusRoom = rooms.first { GeometryOps.polygonContains($0.polygon, mid - normal * probe) }
        var result = wall
        let shift: Vec2
        switch (plusRoom, minusRoom) {
        case (.some, .none):
            // The room is on the plus side: the wall body lies on the minus side.
            shift = normal * (-wall.thickness / 2)
            result.thicknessSource = .assumed
        case (.none, .some):
            shift = normal * (wall.thickness / 2)
            result.thicknessSource = .assumed
        case let (.some(plus), .some(minus)):
            // Rooms both sides: the line sat on one room's face; the other
            // room's face is a wall's thickness away. Put the line midway.
            let toPlus = GeometryOps.distanceToPolygonBoundary(plus.polygon, mid)
            let toMinus = GeometryOps.distanceToPolygonBoundary(minus.polygon, mid)
            let total = toPlus + toMinus
            guard total >= 0.03 else { return wall }
            let towardMinus = toMinus > toPlus
            shift = normal * ((abs(toMinus - toPlus) / 2) * (towardMinus ? -1 : 1))
            if total <= 0.45 {
                result.thickness = total
                result.thicknessSource = .measured
            } else {
                result.thicknessSource = .assumed
            }
        case (.none, .none):
            return wall
        }
        result.start = wall.start + shift
        result.end = wall.end + shift
        return result
    }
}
