import Foundation

// MARK: - Contractor quantities (brief §20)
//
// What a bid is written from, per room and for the whole job: paintable
// wall and ceiling area, floor area, tile area up to a height, room volume,
// trim lengths, and a count of every fixture. Everything derives from the
// same room polygons and walls the drawing uses — the painted faces, never
// the centerlines — so a number here can be pointed at on the plan.

public struct ContractorQuantities: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { roomID }
    public var roomID: UUID
    public var roomName: String
    public var levelName: String
    public var roomType: RoomType
    public var floorArea: Double            // m²
    public var ceilingArea: Double          // m²
    public var ceilingHeight: Double?       // m
    /// Net wall area, openings removed.
    public var paintableWallArea: Double    // m²
    public var perimeter: Double            // m
    public var baseboardLength: Double      // m
    public var crownLength: Double          // m
    /// Net wall area from the floor up to `tileHeight` (wet walls).
    public var wallTileArea: Double         // m²
    public var tileHeight: Double           // m
    /// Net wall area from the floor up to `wainscotHeight`.
    public var wainscotArea: Double         // m²
    public var wainscotHeight: Double       // m
    /// Floor area × ceiling height.
    public var volume: Double               // m³
    public var doorCount: Int
    public var windowCount: Int
    public var openingCount: Int
    /// Fixtures staying or new, by `FixtureCategory` raw value.
    public var fixtureCounts: [String: Int]
    /// Fixtures marked for demolition, by `FixtureCategory` raw value.
    public var demolishedFixtureCounts: [String: Int]
    public var isWetRoom: Bool

    public static let defaultTileHeight = 2.1336     // 7'-0"
    public static let defaultWainscotHeight = 1.2192 // 4'-0"

    public var fixtureTotal: Int { fixtureCounts.values.reduce(0, +) }

    /// "2 toilet, 1 sink" — counts in a fixed, readable order.
    public var fixtureSummary: String {
        FixtureCategory.allCases.compactMap { category in
            guard let n = fixtureCounts[category.rawValue], n > 0 else { return nil }
            return "\(n) \(category.displayName.lowercased())"
        }.joined(separator: ", ")
    }

    public static func compute(
        room: RoomShape,
        in level: LevelGeometry,
        tileHeight: Double = defaultTileHeight,
        wainscotHeight: Double = defaultWainscotHeight
    ) -> ContractorQuantities {
        let calc = RoomCalculations.compute(room: room, in: level)
        let walls = level.walls(for: room)
        let height = calc.ceilingHeight ?? walls.map(\.height).max() ?? 2.4384
        let inRoom = level.fixtures.filter { fixture in
            fixture.roomID == room.id
                || (fixture.roomID == nil && room.polygon.count >= 3
                    && GeometryOps.polygonContains(room.polygon, fixture.center))
        }
        var counts: [String: Int] = [:]
        var demolished: [String: Int] = [:]
        for fixture in inRoom {
            if fixture.changeStatus == .demolish {
                demolished[fixture.category.rawValue, default: 0] += 1
            } else {
                counts[fixture.category.rawValue, default: 0] += 1
            }
        }
        let wet: [RoomType] = [.bathroom, .powderRoom, .kitchen, .laundry]
        return ContractorQuantities(
            roomID: room.id,
            roomName: room.name,
            levelName: level.name,
            roomType: room.type,
            floorArea: calc.floorArea,
            ceilingArea: calc.ceilingArea,
            ceilingHeight: calc.ceilingHeight,
            paintableWallArea: calc.netWallArea,
            perimeter: calc.perimeter,
            baseboardLength: calc.baseMoldingLength,
            crownLength: calc.crownMoldingLength,
            wallTileArea: wallArea(room: room, calc: calc, walls: walls, upTo: tileHeight),
            tileHeight: tileHeight,
            wainscotArea: wallArea(room: room, calc: calc, walls: walls, upTo: wainscotHeight),
            wainscotHeight: wainscotHeight,
            volume: calc.floorArea * height,
            doorCount: calc.doorCount,
            windowCount: calc.windowCount,
            openingCount: calc.openingCount,
            fixtureCounts: counts,
            demolishedFixtureCounts: demolished,
            isWetRoom: wet.contains(room.type))
    }

    /// Net wall area between the floor and `limit`: each painted face's
    /// length × min(limit, wall height), less the part of every opening that
    /// lies below the limit.
    static func wallArea(room: RoomShape, calc: RoomCalculations, walls: [Wall], upTo limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        var gross = 0.0
        let fallback = calc.ceilingHeight ?? walls.map(\.height).max() ?? limit
        if room.polygon.count >= 3, !walls.isEmpty {
            let polygon = room.polygon
            let n = polygon.count
            for i in 0..<n {
                let a = polygon[i]
                let b = polygon[(i + 1) % n]
                let mid = a.midpoint(b)
                let along = walls.min {
                    GeometryOps.distanceToSegment(mid, $0.start, $0.end) < GeometryOps.distanceToSegment(mid, $1.start, $1.end)
                }
                let wallHeight = along.flatMap {
                    GeometryOps.distanceToSegment(mid, $0.start, $0.end) <= 0.4 ? $0.height : nil
                } ?? fallback
                gross += a.distance(to: b) * min(limit, wallHeight)
            }
        } else {
            gross = calc.perimeter * min(limit, fallback)
        }
        var openings = 0.0
        for wall in walls {
            for opening in wall.openings {
                let bottom = opening.kind == .window ? opening.sillHeight : 0
                let top = min(bottom + opening.height, wall.height)
                let covered = max(0, min(top, limit) - bottom)
                openings += min(opening.width, wall.length) * covered
            }
        }
        return max(0, gross - openings)
    }
}

/// Whole-job rollup of `ContractorQuantities`.
public struct ContractorSummary: Codable, Hashable, Sendable {
    public var rooms: [ContractorQuantities] = []
    public var floorArea = 0.0
    public var ceilingArea = 0.0
    public var paintableWallArea = 0.0
    /// Wet-room wall tile area only (bathrooms, powder rooms, kitchens, laundry).
    public var wetWallTileArea = 0.0
    public var wainscotArea = 0.0
    public var volume = 0.0
    public var baseboardLength = 0.0
    public var crownLength = 0.0
    public var doorCount = 0
    public var windowCount = 0
    public var fixtureCounts: [String: Int] = [:]
    public var demolishedFixtureCounts: [String: Int] = [:]

    public init() {}

    public static func compute(levels: [LevelGeometry]) -> ContractorSummary {
        var summary = ContractorSummary()
        for level in levels {
            for room in level.rooms {
                let q = ContractorQuantities.compute(room: room, in: level)
                summary.rooms.append(q)
                summary.floorArea += q.floorArea
                summary.ceilingArea += q.ceilingArea
                summary.paintableWallArea += q.paintableWallArea
                if q.isWetRoom { summary.wetWallTileArea += q.wallTileArea }
                summary.wainscotArea += q.wainscotArea
                summary.volume += q.volume
                summary.baseboardLength += q.baseboardLength
                summary.crownLength += q.crownLength
                summary.doorCount += q.doorCount
                summary.windowCount += q.windowCount
                for (key, n) in q.fixtureCounts { summary.fixtureCounts[key, default: 0] += n }
                for (key, n) in q.demolishedFixtureCounts { summary.demolishedFixtureCounts[key, default: 0] += n }
            }
        }
        return summary
    }

    public var fixtureSummary: String {
        FixtureCategory.allCases.compactMap { category in
            guard let n = fixtureCounts[category.rawValue], n > 0 else { return nil }
            return "\(n) \(category.displayName.lowercased())"
        }.joined(separator: ", ")
    }
}

// MARK: - Door and window schedule (brief §19)

public struct OpeningScheduleRow: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// "D1", "W3", "O2" — doors, windows and cased openings numbered apart.
    public var mark: String
    public var levelName: String
    public var kind: OpeningKind
    public var style: DoorStyle?
    public var width: Double
    public var height: Double
    public var sillHeight: Double
    public var wallThickness: Double
    /// Rooms either side of the opening; the one a door swings into first.
    public var rooms: [String]
    /// "LH" / "RH" for swinging doors, viewed from the side the leaf swings
    /// away from (the push side): hinges on the viewer's left is left-hand.
    public var hand: String?
    public var swingsInto: String?
    public var changeStatus: ChangeStatus
    public var source: MeasurementSource
    public var evidencePercent: Int?
    public var notes: String

    public var sizeText: (UnitFormatter) -> String {
        { formatter in "\(formatter.length(width)) × \(formatter.length(height))" }
    }
}

public enum OpeningSchedule {

    /// Every opening on the levels, doors first then windows then cased
    /// openings, in level order, then along each wall.
    public static func rows(levels: [LevelGeometry], includeDemolished: Bool = true) -> [OpeningScheduleRow] {
        var rows: [OpeningScheduleRow] = []
        var counters: [OpeningKind: Int] = [:]
        let ordered = levels.sorted { $0.storyIndex < $1.storyIndex }
        for kind in [OpeningKind.door, .window, .opening] {
            for level in ordered {
                for wall in level.walls {
                    for opening in wall.openings.sorted(by: { $0.centerOffset < $1.centerOffset })
                    where opening.kind == kind {
                        if !includeDemolished, opening.changeStatus == .demolish { continue }
                        counters[kind, default: 0] += 1
                        rows.append(row(for: opening, on: wall, in: level, number: counters[kind]!))
                    }
                }
            }
        }
        return rows
    }

    static func prefix(for kind: OpeningKind) -> String {
        switch kind {
        case .door: return "D"
        case .window: return "W"
        case .opening: return "O"
        }
    }

    static func row(for opening: WallOpening, on wall: Wall, in level: LevelGeometry, number: Int) -> OpeningScheduleRow {
        let direction = wall.direction
        let perpendicular = direction.perpendicular
        let center = wall.point(atOffset: opening.centerOffset)
        let reach = wall.thickness / 2 + 0.30
        let positiveRoom = level.rooms.first { GeometryOps.polygonContains($0.polygon, center + perpendicular * reach) }
        let negativeRoom = level.rooms.first { GeometryOps.polygonContains($0.polygon, center - perpendicular * reach) }

        var rooms: [String] = []
        var hand: String? = nil
        var swingsInto: String? = nil
        var style: DoorStyle? = nil
        if opening.kind == .door {
            style = opening.resolvedStyle
            let swing = opening.swing ?? DoorSwingInference.swing(for: opening, on: wall, in: level)
            let served = swing.opensPositiveSide ? positiveRoom : negativeRoom
            let other = swing.opensPositiveSide ? negativeRoom : positiveRoom
            rooms = [served?.name, other?.name].compactMap { $0 }
            if style?.hasSwing == true {
                swingsInto = served?.name ?? "outside"
                // Viewer on the push side looks along the swing; their right
                // is the swing direction turned clockwise.
                let toward = swing.opensPositiveSide ? perpendicular : perpendicular * -1
                let right = Vec2(toward.y, -toward.x)
                let hinge = swing.hingeAtStart
                    ? wall.point(atOffset: opening.startOffset)
                    : wall.point(atOffset: opening.endOffset)
                hand = (hinge - center).dot(right) > 0 ? "RH" : "LH"
            }
        } else {
            rooms = [positiveRoom?.name, negativeRoom?.name].compactMap { $0 }
        }
        if rooms.isEmpty { rooms = ["—"] }

        var notes: [String] = []
        if opening.isOpenAtCapture == true { notes.append("open at scan") }
        if opening.kind == .door, let style, !style.hasSwing { notes.append(style.displayName.lowercased()) }

        return OpeningScheduleRow(
            id: opening.id,
            mark: "\(prefix(for: opening.kind))\(number)",
            levelName: level.name,
            kind: opening.kind,
            style: style,
            width: opening.width,
            height: opening.height,
            sillHeight: opening.kind == .window ? opening.sillHeight : 0,
            wallThickness: wall.thickness,
            rooms: rooms,
            hand: hand,
            swingsInto: swingsInto,
            changeStatus: opening.changeStatus,
            source: opening.source,
            evidencePercent: opening.evidence.map { ConfidenceModel.percent($0.confidence) },
            notes: notes.joined(separator: "; "))
    }
}
