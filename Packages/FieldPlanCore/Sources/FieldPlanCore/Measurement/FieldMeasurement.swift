import Foundation

// MARK: - Field measurements
//
// Manual/AR/laser measurements captured outside the floor-plan geometry:
// door slabs, rough openings, tubs, cabinet runs, clearances, etc.
// Every measurement is auditable: the original value survives edits.

public enum MeasurementCategory: String, Codable, CaseIterable, Sendable {
    case doorSlab, doorRoughOpening, windowOpening, windowTrim
    case tub, shower, vanity, medicineCabinet, radiator
    case kitchenCabinet, countertop, backsplash, applianceOpening
    case ceilingSoffit, beam, niche, closetOpening
    case stairTread, stairRiser, hallwayWidth
    case plumbingLocation, electricalLocation
    case room, ceiling, floor, wall, custom

    public var displayName: String {
        switch self {
        case .doorSlab: return "Door Slab"
        case .doorRoughOpening: return "Door Rough Opening"
        case .windowOpening: return "Window Opening"
        case .windowTrim: return "Window Trim"
        case .tub: return "Tub"
        case .shower: return "Shower"
        case .vanity: return "Vanity"
        case .medicineCabinet: return "Medicine Cabinet"
        case .radiator: return "Radiator"
        case .kitchenCabinet: return "Kitchen Cabinet"
        case .countertop: return "Countertop"
        case .backsplash: return "Backsplash"
        case .applianceOpening: return "Appliance Opening"
        case .ceilingSoffit: return "Ceiling Soffit"
        case .beam: return "Beam"
        case .niche: return "Niche"
        case .closetOpening: return "Closet Opening"
        case .stairTread: return "Stair Tread"
        case .stairRiser: return "Stair Riser"
        case .hallwayWidth: return "Hallway Width"
        case .plumbingLocation: return "Plumbing Location"
        case .electricalLocation: return "Electrical Location"
        case .room: return "Room"
        case .ceiling: return "Ceiling"
        case .floor: return "Floor"
        case .wall: return "Wall"
        case .custom: return "Custom"
        }
    }

    /// Categories a contractor typically treats as critical dimensions.
    public var isTypicallyCritical: Bool {
        switch self {
        case .doorRoughOpening, .applianceOpening, .kitchenCabinet,
             .countertop, .tub, .shower, .doorSlab, .closetOpening:
            return true
        default:
            return false
        }
    }
}

public enum MeasurementKind: String, Codable, CaseIterable, Sendable {
    case length, width, height, depth, diameter
    case area
    case pointToPoint
    case elevationFromFloor
    case distanceFromWall

    public var displayName: String {
        switch self {
        case .length: return "Length"
        case .width: return "Width"
        case .height: return "Height"
        case .depth: return "Depth"
        case .diameter: return "Diameter"
        case .area: return "Area"
        case .pointToPoint: return "Point to Point"
        case .elevationFromFloor: return "Elevation From Floor"
        case .distanceFromWall: return "Distance From Wall"
        }
    }

    public var isArea: Bool { self == .area }
}

/// One captured value with full provenance.
public struct FieldMeasurementModel: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: MeasurementCategory
    public var kind: MeasurementKind
    /// Meters (or square meters when kind == .area). Full precision.
    public var value: Double
    /// The first value ever recorded, preserved across edits. Nil until the
    /// value is edited the first time; then it holds the pre-edit original.
    public var originalValue: Double?
    public var source: MeasurementSource
    public var verification: VerificationStatus
    public var isCritical: Bool
    public var confidence: CaptureConfidence
    public var notes: String
    public var roomID: UUID?
    public var levelID: UUID?
    public var elementID: UUID?   // associated wall/opening/fixture if any
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        category: MeasurementCategory = .custom,
        kind: MeasurementKind = .length,
        value: Double,
        originalValue: Double? = nil,
        source: MeasurementSource = .manualEntry,
        verification: VerificationStatus = .unverified,
        isCritical: Bool = false,
        confidence: CaptureConfidence = .medium,
        notes: String = "",
        roomID: UUID? = nil,
        levelID: UUID? = nil,
        elementID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.kind = kind
        self.value = value
        self.originalValue = originalValue
        self.source = source
        self.verification = verification
        self.isCritical = isCritical
        self.confidence = confidence
        self.notes = notes
        self.roomID = roomID
        self.levelID = levelID
        self.elementID = elementID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Returns a copy with an edited value; the original is preserved
    /// automatically the first time an edit happens.
    public func editingValue(to newValue: Double, source newSource: MeasurementSource = .edited) -> FieldMeasurementModel {
        var copy = self
        if copy.originalValue == nil, newValue != value {
            copy.originalValue = value
        }
        copy.value = newValue
        copy.source = newSource
        copy.updatedAt = Date()
        if copy.verification == .unverified {
            copy.verification = .manuallyCorrected
        }
        return copy
    }

    public func formattedValue(_ formatter: UnitFormatter) -> String {
        kind.isArea ? formatter.area(value) : formatter.length(value)
    }
}

// MARK: - Templates (spec §60)

/// A prompt inside a measurement template. Optional — the user skips freely.
public struct MeasurementPrompt: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: MeasurementCategory
    public var kind: MeasurementKind
    public var isCritical: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        category: MeasurementCategory,
        kind: MeasurementKind = .length,
        isCritical: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.kind = kind
        self.isCritical = isCritical
    }
}

public struct MeasurementTemplate: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var prompts: [MeasurementPrompt]

    public init(id: UUID = UUID(), name: String, prompts: [MeasurementPrompt]) {
        self.id = id
        self.name = name
        self.prompts = prompts
    }
}

public enum MeasurementTemplates {
    public static let bathroom = MeasurementTemplate(name: "Bathroom", prompts: [
        MeasurementPrompt(name: "Room Length", category: .room, kind: .length),
        MeasurementPrompt(name: "Room Width", category: .room, kind: .width),
        MeasurementPrompt(name: "Ceiling Height", category: .ceiling, kind: .height),
        MeasurementPrompt(name: "Tub Length", category: .tub, kind: .length, isCritical: true),
        MeasurementPrompt(name: "Tub Width", category: .tub, kind: .width, isCritical: true),
        MeasurementPrompt(name: "Shower Width", category: .shower, kind: .width, isCritical: true),
        MeasurementPrompt(name: "Shower Depth", category: .shower, kind: .depth, isCritical: true),
        MeasurementPrompt(name: "Vanity Width", category: .vanity, kind: .width),
        MeasurementPrompt(name: "Toilet Rough-In", category: .plumbingLocation, kind: .distanceFromWall, isCritical: true),
        MeasurementPrompt(name: "Door Width", category: .doorSlab, kind: .width, isCritical: true),
        MeasurementPrompt(name: "Window Width", category: .windowOpening, kind: .width),
        MeasurementPrompt(name: "Window Height", category: .windowOpening, kind: .height),
        MeasurementPrompt(name: "Medicine Cabinet Width", category: .medicineCabinet, kind: .width),
        MeasurementPrompt(name: "Tile Wall Height", category: .wall, kind: .height),
        MeasurementPrompt(name: "Floor Area", category: .floor, kind: .area),
    ])

    public static let kitchen = MeasurementTemplate(name: "Kitchen", prompts: [
        MeasurementPrompt(name: "Room Length", category: .room, kind: .length),
        MeasurementPrompt(name: "Room Width", category: .room, kind: .width),
        MeasurementPrompt(name: "Ceiling Height", category: .ceiling, kind: .height),
        MeasurementPrompt(name: "Cabinet Wall A", category: .kitchenCabinet, kind: .length, isCritical: true),
        MeasurementPrompt(name: "Cabinet Wall B", category: .kitchenCabinet, kind: .length, isCritical: true),
        MeasurementPrompt(name: "Base Cabinet Run", category: .kitchenCabinet, kind: .length, isCritical: true),
        MeasurementPrompt(name: "Upper Cabinet Run", category: .kitchenCabinet, kind: .length, isCritical: true),
        MeasurementPrompt(name: "Island Length", category: .kitchenCabinet, kind: .length),
        MeasurementPrompt(name: "Island Width", category: .kitchenCabinet, kind: .width),
        MeasurementPrompt(name: "Countertop Depth", category: .countertop, kind: .depth, isCritical: true),
        MeasurementPrompt(name: "Backsplash Height", category: .backsplash, kind: .height),
        MeasurementPrompt(name: "Sink Base Width", category: .kitchenCabinet, kind: .width, isCritical: true),
        MeasurementPrompt(name: "Range Opening", category: .applianceOpening, kind: .width, isCritical: true),
        MeasurementPrompt(name: "Refrigerator Opening Width", category: .applianceOpening, kind: .width, isCritical: true),
        MeasurementPrompt(name: "Refrigerator Opening Height", category: .applianceOpening, kind: .height, isCritical: true),
        MeasurementPrompt(name: "Dishwasher Opening", category: .applianceOpening, kind: .width, isCritical: true),
        MeasurementPrompt(name: "Window Width", category: .windowOpening, kind: .width),
        MeasurementPrompt(name: "Door Width", category: .doorSlab, kind: .width),
        MeasurementPrompt(name: "Floor Area", category: .floor, kind: .area),
    ])

    public static let flooring = MeasurementTemplate(name: "Flooring", prompts: [
        MeasurementPrompt(name: "Floor Area", category: .floor, kind: .area),
        MeasurementPrompt(name: "Room Perimeter", category: .room, kind: .length),
        MeasurementPrompt(name: "Transition Width", category: .floor, kind: .width),
        MeasurementPrompt(name: "Door Opening Width", category: .doorSlab, kind: .width),
        MeasurementPrompt(name: "Floor Height Transition", category: .floor, kind: .height),
        MeasurementPrompt(name: "Hallway Width", category: .hallwayWidth, kind: .width),
    ])

    public static let painting = MeasurementTemplate(name: "Painting", prompts: [
        MeasurementPrompt(name: "Wall Area", category: .wall, kind: .area),
        MeasurementPrompt(name: "Ceiling Area", category: .ceiling, kind: .area),
        MeasurementPrompt(name: "Ceiling Height", category: .ceiling, kind: .height),
        MeasurementPrompt(name: "Door Count Width Check", category: .doorSlab, kind: .width),
        MeasurementPrompt(name: "Window Trim Width", category: .windowTrim, kind: .width),
        MeasurementPrompt(name: "Base Molding Length", category: .room, kind: .length),
        MeasurementPrompt(name: "Crown Molding Length", category: .room, kind: .length),
        MeasurementPrompt(name: "Closet Depth", category: .closetOpening, kind: .depth),
    ])

    public static let all: [MeasurementTemplate] = [bathroom, kitchen, flooring, painting]
}

// MARK: - Measurement providers (spec §19)

/// Abstraction over how a raw value arrives (manual entry now; AR capture in
/// the app layer; a Bluetooth laser meter later). Implementations produce a
/// value in meters plus its provenance; they never round.
public protocol MeasurementProvider {
    var sourceType: MeasurementSource { get }
    var isAvailable: Bool { get }
}

/// Manual keyboard entry backed by the DimensionParser.
public struct ManualMeasurementProvider: MeasurementProvider {
    public let sourceType: MeasurementSource = .manualEntry
    public let isAvailable = true

    public init() {}

    public func parse(_ input: String) -> Double? {
        DimensionParser.parseLength(input)
    }
}
