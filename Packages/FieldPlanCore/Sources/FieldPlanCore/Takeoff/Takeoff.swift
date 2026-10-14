import Foundation

// MARK: - Quantity takeoff (spec §27, §28)
//
// Computes contractor quantities from selected surfaces. This is NOT a
// pricing engine. Waste factors are always explicit — nothing is assumed
// silently; a line's waste percentage is stored on the line and displayed.

public enum TakeoffCategory: String, Codable, CaseIterable, Sendable {
    case flooring, underlayment, floorLeveling, floorTile, wallTile
    case drywall, paint, primer
    case baseMolding, crownMolding, doorCasing, windowCasing
    case insulation, backerBoard, waterproofing
    case cabinets, countertops, backsplash
    case demolitionArea, wallConstruction, other

    public var displayName: String {
        switch self {
        case .flooring: return "Flooring"
        case .underlayment: return "Floor Underlayment"
        case .floorLeveling: return "Floor Leveling"
        case .floorTile: return "Floor Tile"
        case .wallTile: return "Wall Tile"
        case .drywall: return "Drywall"
        case .paint: return "Paint"
        case .primer: return "Primer"
        case .baseMolding: return "Base Molding"
        case .crownMolding: return "Crown Molding"
        case .doorCasing: return "Door Casing"
        case .windowCasing: return "Window Casing"
        case .insulation: return "Insulation"
        case .backerBoard: return "Backer Board"
        case .waterproofing: return "Waterproofing"
        case .cabinets: return "Cabinets"
        case .countertops: return "Countertops"
        case .backsplash: return "Backsplash"
        case .demolitionArea: return "Demolition Area"
        case .wallConstruction: return "Wall Construction"
        case .other: return "Other"
        }
    }

    /// Which surfaces this category measures by default.
    public var measures: TakeoffMeasure {
        switch self {
        case .flooring, .underlayment, .floorLeveling, .floorTile:
            return .floorArea
        case .wallTile, .insulation, .backerBoard, .waterproofing:
            return .wallArea
        case .drywall:
            return .wallAndCeilingArea
        case .paint, .primer:
            return .wallAndCeilingArea
        case .baseMolding:
            return .baseboardLength
        case .crownMolding:
            return .perimeterLength
        case .doorCasing:
            return .doorCount
        case .windowCasing:
            return .windowCount
        case .cabinets, .countertops:
            return .linearLength
        case .backsplash:
            return .wallArea
        case .demolitionArea:
            return .floorArea
        case .wallConstruction:
            return .wallArea
        case .other:
            return .custom
        }
    }
}

public enum TakeoffMeasure: String, Codable, Sendable {
    case floorArea            // selected floors, m²
    case ceilingArea          // selected ceilings, m²
    case wallArea             // selected walls net area, m²
    case wallAndCeilingArea   // both, m²
    case baseboardLength      // perimeter minus floor openings, m
    case perimeterLength      // full perimeter, m
    case linearLength         // manual linear entry, m
    case doorCount
    case windowCount
    case custom
}

public enum TakeoffUnit: String, Codable, Sendable {
    case squareFeet, linearFeet, count

    public var displayName: String {
        switch self {
        case .squareFeet: return "sq ft"
        case .linearFeet: return "LF"
        case .count: return "ea"
        }
    }
}

/// Standard waste factor choices; custom values allowed anywhere.
public enum WasteFactor {
    public static let standardChoices: [Double] = [0, 5, 10, 15]
}

/// Which surfaces of one room are in scope for a takeoff line.
public struct SurfaceSelection: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var roomID: UUID
    public var includeFloor: Bool
    public var includeCeiling: Bool
    /// Selected wall IDs. Empty + includeAllWalls=true means every bounding wall.
    public var wallIDs: Set<UUID>
    public var includeAllWalls: Bool

    public init(
        id: UUID = UUID(),
        roomID: UUID,
        includeFloor: Bool = false,
        includeCeiling: Bool = false,
        wallIDs: Set<UUID> = [],
        includeAllWalls: Bool = false
    ) {
        self.id = id
        self.roomID = roomID
        self.includeFloor = includeFloor
        self.includeCeiling = includeCeiling
        self.wallIDs = wallIDs
        self.includeAllWalls = includeAllWalls
    }

    public var selectsAnything: Bool {
        includeFloor || includeCeiling || includeAllWalls || !wallIDs.isEmpty
    }
}

/// One scoped takeoff item: category + selections + waste.
public struct TakeoffItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var category: TakeoffCategory
    public var name: String
    public var selections: [SurfaceSelection]
    public var wastePercent: Double
    /// Manual quantity override (in the category's natural unit, imperial).
    /// When set, computed geometry quantity is ignored but preserved.
    public var manualQuantity: Double?
    /// Manual linear length in meters for linear categories (cabinet runs).
    public var manualLinearMeters: Double?
    public var notes: String
    public var isExcluded: Bool

    public init(
        id: UUID = UUID(),
        category: TakeoffCategory,
        name: String? = nil,
        selections: [SurfaceSelection] = [],
        wastePercent: Double = 0,
        manualQuantity: Double? = nil,
        manualLinearMeters: Double? = nil,
        notes: String = "",
        isExcluded: Bool = false
    ) {
        self.id = id
        self.category = category
        self.name = name ?? category.displayName
        self.selections = selections
        self.wastePercent = wastePercent
        self.manualQuantity = manualQuantity
        self.manualLinearMeters = manualLinearMeters
        self.notes = notes
        self.isExcluded = isExcluded
    }
}

/// A computed takeoff result line, ready for display/CSV/PDF.
public struct TakeoffLine: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var itemID: UUID
    public var category: TakeoffCategory
    public var name: String
    public var unit: TakeoffUnit
    /// Base quantity in DISPLAY units (sq ft / LF / count), before waste.
    public var baseQuantity: Double
    public var wastePercent: Double
    /// Quantity with waste applied.
    public var totalQuantity: Double
    public var roomNames: [String]
    public var isManualOverride: Bool
    public var notes: String

    public init(
        id: UUID = UUID(),
        itemID: UUID,
        category: TakeoffCategory,
        name: String,
        unit: TakeoffUnit,
        baseQuantity: Double,
        wastePercent: Double,
        totalQuantity: Double,
        roomNames: [String],
        isManualOverride: Bool,
        notes: String
    ) {
        self.id = id
        self.itemID = itemID
        self.category = category
        self.name = name
        self.unit = unit
        self.baseQuantity = baseQuantity
        self.wastePercent = wastePercent
        self.totalQuantity = totalQuantity
        self.roomNames = roomNames
        self.isManualOverride = isManualOverride
        self.notes = notes
    }
}

public enum TakeoffCalculator {

    /// Computes the result line for one takeoff item against the geometry.
    public static func line(
        for item: TakeoffItem,
        levels: [LevelGeometry]
    ) -> TakeoffLine {
        let measure = item.category.measures
        var baseMetric = 0.0 // m², m, or count depending on measure
        var roomNames: [String] = []

        let roomsByID: [UUID: (RoomShape, LevelGeometry)] = {
            var map: [UUID: (RoomShape, LevelGeometry)] = [:]
            for level in levels {
                for room in level.rooms { map[room.id] = (room, level) }
            }
            return map
        }()

        for selection in item.selections {
            guard let (room, level) = roomsByID[selection.roomID] else { continue }
            let calc = RoomCalculations.compute(room: room, in: level)
            roomNames.append(room.name)

            let selectedWallArea: Double = {
                // Every wall: the room's own net wall area, measured along
                // its painted faces. A subset: those walls' own net areas.
                if selection.includeAllWalls { return calc.netWallArea }
                let walls = level.walls(for: room)
                return walls.filter { selection.wallIDs.contains($0.id) }.reduce(0) { $0 + $1.netArea }
            }()

            switch measure {
            case .floorArea:
                if selection.includeFloor { baseMetric += calc.floorArea }
            case .ceilingArea:
                if selection.includeCeiling { baseMetric += calc.ceilingArea }
            case .wallArea:
                baseMetric += selectedWallArea
            case .wallAndCeilingArea:
                baseMetric += selectedWallArea
                if selection.includeCeiling { baseMetric += calc.ceilingArea }
            case .baseboardLength:
                baseMetric += calc.baseMoldingLength
            case .perimeterLength:
                baseMetric += calc.perimeter
            case .linearLength:
                break // manual only
            case .doorCount:
                baseMetric += Double(calc.doorCount)
            case .windowCount:
                baseMetric += Double(calc.windowCount)
            case .custom:
                break
            }
        }

        if measure == .linearLength, let manual = item.manualLinearMeters {
            baseMetric += manual
        }

        // Convert metric quantity to display units.
        let unit: TakeoffUnit
        var baseQuantity: Double
        switch measure {
        case .floorArea, .ceilingArea, .wallArea, .wallAndCeilingArea:
            unit = .squareFeet
            baseQuantity = baseMetric / UnitConstants.squareMetersPerSquareFoot
        case .baseboardLength, .perimeterLength, .linearLength:
            unit = .linearFeet
            baseQuantity = baseMetric / UnitConstants.metersPerFoot
        case .doorCount, .windowCount:
            unit = .count
            baseQuantity = baseMetric
        case .custom:
            unit = .count
            baseQuantity = 0
        }

        var isManual = false
        if let manual = item.manualQuantity {
            baseQuantity = manual
            isManual = true
        }

        let total = baseQuantity * (1 + item.wastePercent / 100)
        return TakeoffLine(
            itemID: item.id,
            category: item.category,
            name: item.name,
            unit: unit,
            baseQuantity: baseQuantity,
            wastePercent: item.wastePercent,
            totalQuantity: total,
            roomNames: roomNames,
            isManualOverride: isManual,
            notes: item.notes
        )
    }

    /// Computes lines for all non-excluded items.
    public static func lines(
        for items: [TakeoffItem],
        levels: [LevelGeometry]
    ) -> [TakeoffLine] {
        items.filter { !$0.isExcluded }.map { line(for: $0, levels: levels) }
    }
}
