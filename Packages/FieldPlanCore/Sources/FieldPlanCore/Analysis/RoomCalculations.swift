import Foundation

/// Automatic per-room quantities (spec §26). Values are meters / square
/// meters at full precision; formatting is the caller's job. Every figure is
/// derived from the canonical geometry and can be overridden at the takeoff
/// stage without altering geometry.
public struct RoomCalculations: Codable, Hashable, Sendable {
    public var roomID: UUID
    public var floorArea: Double          // m²
    public var ceilingArea: Double        // m² (equals floor area for flat ceilings)
    public var perimeter: Double          // m
    public var ceilingHeight: Double?     // m
    public var wallLengths: [Double]      // m, per bounding wall
    public var grossWallArea: Double      // m²
    public var windowArea: Double         // m²
    public var doorAndOpeningArea: Double // m²
    public var netWallArea: Double        // m²
    public var baseMoldingLength: Double  // m, perimeter minus floor-level openings
    public var crownMoldingLength: Double // m
    public var doorCount: Int
    public var windowCount: Int
    public var openingCount: Int
    public var closetCount: Int

    public init(
        roomID: UUID,
        floorArea: Double = 0,
        ceilingArea: Double = 0,
        perimeter: Double = 0,
        ceilingHeight: Double? = nil,
        wallLengths: [Double] = [],
        grossWallArea: Double = 0,
        windowArea: Double = 0,
        doorAndOpeningArea: Double = 0,
        netWallArea: Double = 0,
        baseMoldingLength: Double = 0,
        crownMoldingLength: Double = 0,
        doorCount: Int = 0,
        windowCount: Int = 0,
        openingCount: Int = 0,
        closetCount: Int = 0
    ) {
        self.roomID = roomID
        self.floorArea = floorArea
        self.ceilingArea = ceilingArea
        self.perimeter = perimeter
        self.ceilingHeight = ceilingHeight
        self.wallLengths = wallLengths
        self.grossWallArea = grossWallArea
        self.windowArea = windowArea
        self.doorAndOpeningArea = doorAndOpeningArea
        self.netWallArea = netWallArea
        self.baseMoldingLength = baseMoldingLength
        self.crownMoldingLength = crownMoldingLength
        self.doorCount = doorCount
        self.windowCount = windowCount
        self.openingCount = openingCount
        self.closetCount = closetCount
    }

    /// Computes all quantities for one room from the level geometry.
    ///
    /// Wall areas: when the room has bounding walls, wall quantities use those
    /// walls' true lengths/heights and openings. When it has none (polygon
    /// only), wall quantities fall back to perimeter × ceiling height.
    public static func compute(room: RoomShape, in level: LevelGeometry) -> RoomCalculations {
        var calc = RoomCalculations(roomID: room.id)
        calc.floorArea = room.floorArea
        calc.ceilingArea = room.floorArea
        calc.perimeter = room.perimeter

        let walls = level.walls(for: room)

        // Ceiling height: explicit value wins, then tallest bounding wall.
        if let h = room.ceilingHeight {
            calc.ceilingHeight = h
        } else if let tallest = walls.map(\.height).max() {
            calc.ceilingHeight = tallest
        }

        if !walls.isEmpty {
            calc.wallLengths = walls.map(\.length)
            calc.grossWallArea = walls.reduce(0) { $0 + $1.grossArea }
            var windowArea = 0.0
            var doorArea = 0.0
            var doors = 0
            var windows = 0
            var openings = 0
            var floorOpeningWidth = 0.0
            for wall in walls {
                for o in wall.openings {
                    let area = max(0, min(o.width, wall.length)) * max(0, min(o.height, wall.height))
                    switch o.kind {
                    case .window:
                        windowArea += area
                        windows += 1
                    case .door:
                        doorArea += area
                        doors += 1
                    case .opening:
                        doorArea += area
                        openings += 1
                    }
                }
                floorOpeningWidth += wall.floorOpeningWidth
            }
            calc.windowArea = windowArea
            calc.doorAndOpeningArea = doorArea
            calc.netWallArea = max(0, calc.grossWallArea - windowArea - doorArea)
            calc.baseMoldingLength = max(0, calc.perimeter - floorOpeningWidth)
            calc.doorCount = doors
            calc.windowCount = windows
            calc.openingCount = openings
        } else if let h = calc.ceilingHeight {
            calc.grossWallArea = calc.perimeter * h
            calc.netWallArea = calc.grossWallArea
            calc.baseMoldingLength = calc.perimeter
        } else {
            calc.baseMoldingLength = calc.perimeter
        }

        calc.crownMoldingLength = calc.perimeter

        // Closets adjacent to this room (closet-type rooms sharing an edge).
        calc.closetCount = level.rooms.filter { other in
            guard other.id != room.id else { return false }
            guard other.type == .closet || other.type == .walkInCloset else { return false }
            return other.polygon.contains { GeometryOps.distanceToPolygonBoundary(room.polygon, $0) < 0.3 }
        }.count

        return calc
    }

    /// Computes quantities for every room on a level.
    public static func computeAll(level: LevelGeometry) -> [RoomCalculations] {
        level.rooms.map { compute(room: $0, in: level) }
    }
}

/// Project-level rollup for the summary screen and reports (spec §34).
public struct ProjectSummaryStats: Codable, Hashable, Sendable {
    public var totalLevels: Int = 0
    public var totalRooms: Int = 0
    public var totalFloorArea: Double = 0
    public var totalWallArea: Double = 0
    public var totalNetWallArea: Double = 0
    public var totalCeilingArea: Double = 0
    public var totalBaseboardLength: Double = 0
    public var totalCrownLength: Double = 0
    public var totalDoors: Int = 0
    public var totalWindows: Int = 0

    public init() {}

    public static func compute(levels: [LevelGeometry]) -> ProjectSummaryStats {
        var stats = ProjectSummaryStats()
        stats.totalLevels = levels.count
        for level in levels {
            stats.totalRooms += level.rooms.count
            for calc in RoomCalculations.computeAll(level: level) {
                stats.totalFloorArea += calc.floorArea
                stats.totalWallArea += calc.grossWallArea
                stats.totalNetWallArea += calc.netWallArea
                stats.totalCeilingArea += calc.ceilingArea
                stats.totalBaseboardLength += calc.baseMoldingLength
                stats.totalCrownLength += calc.crownMoldingLength
                stats.totalDoors += calc.doorCount
                stats.totalWindows += calc.windowCount
            }
        }
        return stats
    }
}
