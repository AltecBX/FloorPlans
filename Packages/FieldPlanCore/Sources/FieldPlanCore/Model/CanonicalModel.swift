import Foundation

// MARK: - Canonical geometry model
//
// FieldPlan's own geometry layer. RoomPlan output is CONVERTED into these
// types (see ScanConversion.swift); everything downstream — plan generation,
// editing, QA, takeoff, exports — operates only on this model.
//
// All coordinates are meters in plan space (Vec2 docs). All values are stored
// at full precision; rounding is display-only.

/// Whether an element belongs to existing conditions, is marked for
/// demolition, or is proposed new construction.
public enum ChangeStatus: String, Codable, CaseIterable, Sendable {
    case existing
    case demolish
    case new

    public var displayName: String {
        switch self {
        case .existing: return "Existing"
        case .demolish: return "Demolish"
        case .new: return "New"
        }
    }
}

/// Where a value came from. Every important dimension carries one.
public enum MeasurementSource: String, Codable, CaseIterable, Sendable {
    case lidarScanned
    case arMeasured
    case manualEntry
    case laserVerified
    case calculated
    case edited
    case sampleData

    public var displayName: String {
        switch self {
        case .lidarScanned: return "LiDAR Scanned"
        case .arMeasured: return "AR Measured"
        case .manualEntry: return "Manual Entry"
        case .laserVerified: return "Laser Verified"
        case .calculated: return "Calculated"
        case .edited: return "Edited"
        case .sampleData: return "SAMPLE DATA"
        }
    }
}

public enum VerificationStatus: String, Codable, CaseIterable, Sendable {
    case unverified
    case fieldChecked
    case laserVerified
    case manuallyCorrected

    public var displayName: String {
        switch self {
        case .unverified: return "Unverified"
        case .fieldChecked: return "Field Checked"
        case .laserVerified: return "Laser Verified"
        case .manuallyCorrected: return "Manually Corrected"
        }
    }
}

/// Scan confidence bucket carried over from RoomPlan (or set by manual entry).
public enum CaptureConfidence: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public var displayName: String { rawValue.capitalized }
}

// MARK: - Openings

public enum OpeningKind: String, Codable, CaseIterable, Sendable {
    case door
    case window
    case opening // cased/uncased opening without a door

    public var displayName: String {
        switch self {
        case .door: return "Door"
        case .window: return "Window"
        case .opening: return "Opening"
        }
    }
}

/// Door swing rendering info. `hingeAtStart` is relative to the wall's
/// start→end direction; `opensPositiveSide` means the leaf swings toward the
/// wall's left side (positive perpendicular).
public struct DoorSwing: Codable, Hashable, Sendable {
    public var hingeAtStart: Bool
    public var opensPositiveSide: Bool

    public init(hingeAtStart: Bool = true, opensPositiveSide: Bool = true) {
        self.hingeAtStart = hingeAtStart
        self.opensPositiveSide = opensPositiveSide
    }

    /// Flips which jamb carries the hinges.
    public var mirrored: DoorSwing {
        DoorSwing(hingeAtStart: !hingeAtStart, opensPositiveSide: opensPositiveSide)
    }

    /// Flips which side of the wall the door opens into.
    public var reversed: DoorSwing {
        DoorSwing(hingeAtStart: hingeAtStart, opensPositiveSide: !opensPositiveSide)
    }
}

/// A door, window or plain opening hosted on a wall.
/// Positioned by the distance from the wall start to the opening center,
/// measured along the wall.
public struct WallOpening: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: OpeningKind
    public var centerOffset: Double   // meters from wall start to opening center
    public var width: Double          // meters
    public var height: Double         // meters
    public var sillHeight: Double     // meters above floor (0 for doors)
    public var swing: DoorSwing?
    public var changeStatus: ChangeStatus
    public var source: MeasurementSource
    public var confidence: CaptureConfidence
    public var label: String?

    public init(
        id: UUID = UUID(),
        kind: OpeningKind,
        centerOffset: Double,
        width: Double,
        height: Double,
        sillHeight: Double = 0,
        swing: DoorSwing? = nil,
        changeStatus: ChangeStatus = .existing,
        source: MeasurementSource = .manualEntry,
        confidence: CaptureConfidence = .medium,
        label: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.centerOffset = centerOffset
        self.width = width
        self.height = height
        self.sillHeight = sillHeight
        self.swing = swing
        self.changeStatus = changeStatus
        self.source = source
        self.confidence = confidence
        self.label = label
    }

    public var startOffset: Double { centerOffset - width / 2 }
    public var endOffset: Double { centerOffset + width / 2 }
}

// MARK: - Walls

public struct Wall: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Vec2
    public var end: Vec2
    public var height: Double      // meters floor-to-ceiling at this wall
    public var thickness: Double   // meters
    public var openings: [WallOpening]
    public var changeStatus: ChangeStatus
    public var source: MeasurementSource
    public var confidence: CaptureConfidence
    /// Length as originally captured, preserved when the wall is edited.
    public var originalLength: Double?
    public var sourceScanID: UUID?

    public init(
        id: UUID = UUID(),
        start: Vec2,
        end: Vec2,
        height: Double = 2.4384, // 8'-0" default until measured
        thickness: Double = 0.1143, // 4 1/2" typical interior partition
        openings: [WallOpening] = [],
        changeStatus: ChangeStatus = .existing,
        source: MeasurementSource = .manualEntry,
        confidence: CaptureConfidence = .medium,
        originalLength: Double? = nil,
        sourceScanID: UUID? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.height = height
        self.thickness = thickness
        self.openings = openings
        self.changeStatus = changeStatus
        self.source = source
        self.confidence = confidence
        self.originalLength = originalLength
        self.sourceScanID = sourceScanID
    }

    public var length: Double { start.distance(to: end) }
    public var direction: Vec2 { (end - start).normalized }
    public var midpoint: Vec2 { start.midpoint(end) }
    public var angle: Double { (end - start).angle }

    public func point(atOffset offset: Double) -> Vec2 {
        start + direction * offset
    }

    /// Total width of door + plain openings that reach the floor
    /// (used for baseboard subtraction).
    public var floorOpeningWidth: Double {
        openings
            .filter { ($0.kind == .door || $0.kind == .opening) && $0.sillHeight < 0.05 }
            .reduce(0) { $0 + $1.width }
    }

    /// Combined area of all openings, clamped to the wall face.
    public var openingArea: Double {
        openings.reduce(0) { total, o in
            let w = max(0, min(o.width, length))
            let h = max(0, min(o.height, height))
            return total + w * h
        }
    }

    public var grossArea: Double { length * height }
    public var netArea: Double { max(0, grossArea - openingArea) }
}

// MARK: - Rooms

public enum RoomType: String, Codable, CaseIterable, Sendable {
    case livingRoom, diningRoom, kitchen, bedroom, bathroom, powderRoom
    case hallway, foyer, closet, walkInCloset, laundry, office, familyRoom
    case basement, mechanicalRoom, utilityRoom, garage, storage, stairHall
    case balcony, terrace, other

    public var displayName: String {
        switch self {
        case .livingRoom: return "Living Room"
        case .diningRoom: return "Dining Room"
        case .kitchen: return "Kitchen"
        case .bedroom: return "Bedroom"
        case .bathroom: return "Bathroom"
        case .powderRoom: return "Powder Room"
        case .hallway: return "Hallway"
        case .foyer: return "Foyer"
        case .closet: return "Closet"
        case .walkInCloset: return "Walk-In Closet"
        case .laundry: return "Laundry"
        case .office: return "Office"
        case .familyRoom: return "Family Room"
        case .basement: return "Basement"
        case .mechanicalRoom: return "Mechanical Room"
        case .utilityRoom: return "Utility Room"
        case .garage: return "Garage"
        case .storage: return "Storage"
        case .stairHall: return "Stair Hall"
        case .balcony: return "Balcony"
        case .terrace: return "Terrace"
        case .other: return "Other"
        }
    }
}

public struct RoomShape: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Display name, e.g. "Primary Bedroom", "Bedroom 2".
    public var name: String
    public var type: RoomType
    /// Boundary polygon, counter-clockwise, vertices not repeating the first.
    public var polygon: [Vec2]
    public var ceilingHeight: Double?
    public var ceilingHeightSource: MeasurementSource
    /// Walls bounding this room (ordered when derived from a loop).
    public var wallIDs: [UUID]
    public var sourceScanID: UUID?
    public var changeStatus: ChangeStatus

    public init(
        id: UUID = UUID(),
        name: String,
        type: RoomType = .other,
        polygon: [Vec2],
        ceilingHeight: Double? = nil,
        ceilingHeightSource: MeasurementSource = .calculated,
        wallIDs: [UUID] = [],
        sourceScanID: UUID? = nil,
        changeStatus: ChangeStatus = .existing
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.polygon = polygon
        self.ceilingHeight = ceilingHeight
        self.ceilingHeightSource = ceilingHeightSource
        self.wallIDs = wallIDs
        self.sourceScanID = sourceScanID
        self.changeStatus = changeStatus
    }

    public var floorArea: Double { GeometryOps.area(polygon) }
    public var perimeter: Double { GeometryOps.perimeter(polygon) }
    public var labelPoint: Vec2 { GeometryOps.interiorLabelPoint(polygon) }
    public var bounds: Rect2 { Rect2(containing: polygon) }
}

// MARK: - Fixtures / objects

public enum FixtureCategory: String, Codable, CaseIterable, Sendable {
    // Plumbing
    case bathtub, shower, toilet, sink, vanity
    // Kitchen
    case cabinetBase, cabinetUpper, island, countertop, refrigerator, stove
    case oven, dishwasher, rangeHood
    // General
    case washerDryer, radiator, fireplace, stairs, column, bed, sofa, chair
    case table, storage, television, medicineCabinet, soffit, custom

    public var displayName: String {
        switch self {
        case .bathtub: return "Bathtub"
        case .shower: return "Shower"
        case .toilet: return "Toilet"
        case .sink: return "Sink"
        case .vanity: return "Vanity"
        case .cabinetBase: return "Base Cabinet"
        case .cabinetUpper: return "Upper Cabinet"
        case .island: return "Island"
        case .countertop: return "Countertop"
        case .refrigerator: return "Refrigerator"
        case .stove: return "Range"
        case .oven: return "Oven"
        case .dishwasher: return "Dishwasher"
        case .rangeHood: return "Range Hood"
        case .washerDryer: return "Washer/Dryer"
        case .radiator: return "Radiator"
        case .fireplace: return "Fireplace"
        case .stairs: return "Stairs"
        case .column: return "Column"
        case .bed: return "Bed"
        case .sofa: return "Sofa"
        case .chair: return "Chair"
        case .table: return "Table"
        case .storage: return "Storage"
        case .television: return "Television"
        case .medicineCabinet: return "Medicine Cabinet"
        case .soffit: return "Soffit"
        case .custom: return "Custom"
        }
    }

    /// Fixtures stay visible on construction plans; furniture is decorative.
    public var isFurniture: Bool {
        switch self {
        case .bed, .sofa, .chair, .table, .television, .storage:
            return true
        default:
            return false
        }
    }
}

/// A placed object: furniture, appliance, plumbing fixture, column, stairs.
/// Footprint is an oriented rectangle (center, size, rotation).
public struct FixtureItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var category: FixtureCategory
    public var label: String?
    public var center: Vec2
    public var size: Vec2       // width (along local X), depth (along local Y)
    public var rotation: Double // radians
    public var height: Double?
    public var roomID: UUID?
    public var changeStatus: ChangeStatus
    public var source: MeasurementSource
    public var confidence: CaptureConfidence

    public init(
        id: UUID = UUID(),
        category: FixtureCategory,
        label: String? = nil,
        center: Vec2,
        size: Vec2,
        rotation: Double = 0,
        height: Double? = nil,
        roomID: UUID? = nil,
        changeStatus: ChangeStatus = .existing,
        source: MeasurementSource = .manualEntry,
        confidence: CaptureConfidence = .medium
    ) {
        self.id = id
        self.category = category
        self.label = label
        self.center = center
        self.size = size
        self.rotation = rotation
        self.height = height
        self.roomID = roomID
        self.changeStatus = changeStatus
        self.source = source
        self.confidence = confidence
    }

    public var displayName: String { label ?? category.displayName }

    /// Footprint corners in plan coordinates (counter-clockwise).
    public var corners: [Vec2] {
        let hw = size.x / 2
        let hd = size.y / 2
        let local = [Vec2(-hw, -hd), Vec2(hw, -hd), Vec2(hw, hd), Vec2(-hw, hd)]
        return local.map { $0.rotated(by: rotation) + center }
    }
}

// MARK: - Annotations

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case note        // text pinned at a point
    case dimension   // manual dimension between two points
}

public struct PlanAnnotation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    public var text: String
    public var position: Vec2       // note anchor, or dimension label override point
    public var pointA: Vec2?        // dimension endpoints
    public var pointB: Vec2?
    public var offset: Double       // dimension line offset from A-B (meters)
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        text: String = "",
        position: Vec2,
        pointA: Vec2? = nil,
        pointB: Vec2? = nil,
        offset: Double = 0.4,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.position = position
        self.pointA = pointA
        self.pointB = pointB
        self.offset = offset
        self.createdAt = createdAt
    }
}

// MARK: - Level

public struct LevelGeometry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Story index for sorting: basement -1, first floor 0, etc.
    public var storyIndex: Int
    public var walls: [Wall]
    public var rooms: [RoomShape]
    public var fixtures: [FixtureItem]
    public var annotations: [PlanAnnotation]
    /// Angle of true north relative to +Y, radians, when established.
    public var northAngle: Double?

    public init(
        id: UUID = UUID(),
        name: String,
        storyIndex: Int = 0,
        walls: [Wall] = [],
        rooms: [RoomShape] = [],
        fixtures: [FixtureItem] = [],
        annotations: [PlanAnnotation] = [],
        northAngle: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.storyIndex = storyIndex
        self.walls = walls
        self.rooms = rooms
        self.fixtures = fixtures
        self.annotations = annotations
        self.northAngle = northAngle
    }

    public func wall(withID id: UUID) -> Wall? {
        walls.first { $0.id == id }
    }

    public func room(withID id: UUID) -> RoomShape? {
        rooms.first { $0.id == id }
    }

    /// Walls bounding a room: prefers explicit wallIDs, falls back to
    /// geometric matching against the room polygon edges.
    public func walls(for room: RoomShape, tolerance: Double = 0.25) -> [Wall] {
        if !room.wallIDs.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: walls.map { ($0.id, $0) })
            let resolved = room.wallIDs.compactMap { byID[$0] }
            if !resolved.isEmpty { return resolved }
        }
        // Geometric fallback: wall midpoint close to the polygon boundary and
        // wall roughly parallel to the nearest edge.
        return walls.filter { wall in
            GeometryOps.distanceToPolygonBoundary(room.polygon, wall.midpoint) <= tolerance
        }
    }

    public var bounds: Rect2 {
        var r = Rect2.null
        for w in walls {
            r.include(w.start)
            r.include(w.end)
        }
        for room in rooms {
            r.include(Rect2(containing: room.polygon))
        }
        for f in fixtures {
            r.include(Rect2(containing: f.corners))
        }
        return r
    }
}

// MARK: - Plan versions

public enum PlanKind: String, Codable, CaseIterable, Sendable {
    case existingConditions
    case proposed

    public var displayName: String {
        switch self {
        case .existingConditions: return "Existing Conditions"
        case .proposed: return "Proposed"
        }
    }
}

/// One immutable-or-editable snapshot of the whole property's geometry.
/// "Existing Conditions" snapshots are locked; proposed plans are editable
/// duplicates. The demolition plan is a rendering of a proposed snapshot's
/// change statuses, not a separate copy.
public struct PlanSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: PlanKind
    public var isLocked: Bool
    public var createdAt: Date
    public var levels: [LevelGeometry]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: PlanKind,
        isLocked: Bool = false,
        createdAt: Date = Date(),
        levels: [LevelGeometry]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isLocked = isLocked
        self.createdAt = createdAt
        self.levels = levels
    }

    /// Duplicates this snapshot into an editable proposed plan with fresh
    /// identity but identical geometry (element IDs are preserved so change
    /// tracking can reference the same walls).
    public func duplicatedAsProposed(named name: String) -> PlanSnapshot {
        PlanSnapshot(
            id: UUID(),
            name: name,
            kind: .proposed,
            isLocked: false,
            createdAt: Date(),
            levels: levels
        )
    }
}

// MARK: - Project metadata

public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case lead, measured, proposalPending, proposalSent, won, lost
    case construction, completed

    public var displayName: String {
        switch self {
        case .lead: return "Lead"
        case .measured: return "Measured"
        case .proposalPending: return "Proposal Pending"
        case .proposalSent: return "Proposal Sent"
        case .won: return "Won"
        case .lost: return "Lost"
        case .construction: return "Construction"
        case .completed: return "Completed"
        }
    }
}

public enum JobType: String, Codable, CaseIterable, Sendable {
    case fullApartment, fullHouse, kitchen, bathroom, basement, flooring
    case painting, interior, commercialInterior, lobby, exterior, other

    public var displayName: String {
        switch self {
        case .fullApartment: return "Full Apartment Renovation"
        case .fullHouse: return "Full House Renovation"
        case .kitchen: return "Kitchen"
        case .bathroom: return "Bathroom"
        case .basement: return "Basement"
        case .flooring: return "Flooring"
        case .painting: return "Painting"
        case .interior: return "Interior Renovation"
        case .commercialInterior: return "Commercial Interior"
        case .lobby: return "Lobby"
        case .exterior: return "Exterior"
        case .other: return "Other"
        }
    }
}

/// Project metadata carried through archives and reports.
public struct ProjectMeta: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var clientName: String
    public var address: String
    public var unit: String
    public var jobType: JobType
    public var status: ProjectStatus
    public var inspectionDate: Date?
    public var clientPhone: String
    public var clientEmail: String
    public var notes: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        clientName: String = "",
        address: String = "",
        unit: String = "",
        jobType: JobType = .other,
        status: ProjectStatus = .lead,
        inspectionDate: Date? = nil,
        clientPhone: String = "",
        clientEmail: String = "",
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.clientName = clientName
        self.address = address
        self.unit = unit
        self.jobType = jobType
        self.status = status
        self.inspectionDate = inspectionDate
        self.clientPhone = clientPhone
        self.clientEmail = clientEmail
        self.notes = notes
        self.createdAt = createdAt
    }
}
