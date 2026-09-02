import Foundation

// MARK: - Which story a capture belongs to (brief §14)
//
// With one continuous ARSession the floors of every room share a frame, so
// the height of a captured floor says which story it is on. The owner picks
// a level before scanning; if the floor he just captured is a story away from
// that level, the geometry goes where it belongs instead of onto the wrong
// plan.

public enum LevelAssignment {

    public struct Result: Hashable, Sendable {
        /// The level the capture belongs on (an existing one, or `createdLevel`).
        public var levelID: UUID
        /// A level to add to the snapshot first, when none matched.
        public var createdLevel: LevelGeometry?
        /// Floor height of the capture in the scan frame.
        public var elevation: Double
        /// Something the owner should hear about, or nil.
        public var message: String?
    }

    /// Floor height of a set of captured rooms: the median of their floor
    /// surfaces, falling back to the bottoms of their walls.
    public static func floorElevation(of rooms: [ScannedRoomDTO]) -> Double? {
        var values: [Double] = []
        for room in rooms {
            let floors = room.surfaces.filter { $0.kind == .floor }
            if let floor = floors.first {
                values.append(floor.center.y)
                continue
            }
            let bottoms = room.surfaces.filter { $0.kind == .wall }.map { $0.center.y - $0.height / 2 }
            if let low = bottoms.min() { values.append(low) }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// One group per story found among captured rooms: rooms whose floors
    /// lie within `tolerance` of the next share a group. Lowest first; each
    /// group carries the median floor height of its rooms. Rooms with no
    /// floor at all join the first group.
    public static func groupByFloor(
        _ rooms: [ScannedRoomDTO], tolerance: Double = 1.2
    ) -> [(elevation: Double, rooms: [ScannedRoomDTO])] {
        var measured: [(elevation: Double, room: ScannedRoomDTO)] = []
        var unknown: [ScannedRoomDTO] = []
        for room in rooms {
            if let elevation = floorElevation(of: [room]) {
                measured.append((elevation, room))
            } else {
                unknown.append(room)
            }
        }
        measured.sort { $0.elevation < $1.elevation }

        var groups: [(elevation: Double, rooms: [ScannedRoomDTO])] = []
        var cluster: [(elevation: Double, room: ScannedRoomDTO)] = []
        func flush() {
            guard !cluster.isEmpty else { return }
            let values = cluster.map(\.elevation)
            groups.append((values[values.count / 2], cluster.map(\.room)))
            cluster.removeAll()
        }
        for entry in measured {
            if let last = cluster.last, entry.elevation - last.elevation > tolerance { flush() }
            cluster.append(entry)
        }
        flush()

        if !unknown.isEmpty {
            if groups.isEmpty {
                groups.append((0, unknown))
            } else {
                groups[0].rooms.append(contentsOf: unknown)
            }
        }
        return groups
    }

    /// Decides the level for a capture at `elevation`.
    ///
    /// - The selected level takes it when it has no elevation yet, or when the
    ///   capture is within `tolerance` of its floor.
    /// - Another level within tolerance takes it otherwise.
    /// - Failing both, a new level is created a story above or below,
    ///   named by its story index.
    public static func assign(
        elevation: Double,
        selectedLevelID: UUID,
        levels: [LevelGeometry],
        tolerance: Double = 1.2,
        typicalStoryHeight: Double = 3.0
    ) -> Result? {
        guard let selected = levels.first(where: { $0.id == selectedLevelID }) else { return nil }
        guard let current = selected.elevation else {
            return Result(levelID: selected.id, createdLevel: nil, elevation: elevation, message: nil)
        }
        if abs(current - elevation) <= tolerance {
            return Result(levelID: selected.id, createdLevel: nil, elevation: elevation, message: nil)
        }
        let formatter = UnitFormatter()
        let difference = elevation - current
        let relation = "\(formatter.length(abs(difference))) \(difference > 0 ? "above" : "below") \(selected.name)"

        if let match = levels.first(where: { level in
            level.id != selected.id && level.elevation.map { abs($0 - elevation) <= tolerance } == true
        }) {
            return Result(
                levelID: match.id, createdLevel: nil, elevation: elevation,
                message: "This scan's floor is \(relation), so it was added to \(match.name).")
        }

        var stories = Int((difference / typicalStoryHeight).rounded())
        if stories == 0 { stories = difference > 0 ? 1 : -1 }
        var storyIndex = selected.storyIndex + stories
        let taken = Set(levels.map(\.storyIndex))
        while taken.contains(storyIndex) { storyIndex += stories > 0 ? 1 : -1 }
        let level = LevelGeometry(name: storyName(storyIndex), storyIndex: storyIndex, elevation: elevation)
        return Result(
            levelID: level.id, createdLevel: level, elevation: elevation,
            message: "This scan's floor is \(relation), so a new level “\(level.name)” was created for it.")
    }

    public static func storyName(_ index: Int) -> String {
        switch index {
        case ..<(-1): return "Sub-Basement"
        case -1: return "Basement"
        case 0: return "First Floor"
        case 1: return "Second Floor"
        case 2: return "Third Floor"
        case 3: return "Fourth Floor"
        default: return "Level \(index + 1)"
        }
    }
}
