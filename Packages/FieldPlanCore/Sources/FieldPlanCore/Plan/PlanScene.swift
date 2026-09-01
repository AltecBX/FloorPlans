import Foundation

// MARK: - Vector plan scene (spec §14)
//
// The 2D floor plan is generated as structured vector primitives in plan
// coordinates (meters). Every renderer — SwiftUI canvas, PDF, PNG, SVG, DXF —
// consumes the SAME scene, so what you see on screen is exactly what exports.
// Never a screenshot.

/// Semantic pen: renderers map pens to stroke widths, dash patterns and
/// colors appropriate for their medium; DXF maps pens to layers.
public enum PlanPen: String, Codable, CaseIterable, Sendable {
    case wallOutline      // cut wall edges — heavy
    case wallDemolished   // demolition — dashed
    case wallNew          // new construction — heavy, distinct
    case openingJamb      // jambs at door/window edges
    case windowGlazing    // window lines
    case doorLeaf         // door leaf
    case doorSwing        // swing arc — thin
    case openingHead      // cased opening dashed head line
    case fixture          // plumbing fixtures, cabinets, appliances
    case furniture        // furniture — light
    case dimension        // dimension + extension lines — thin
    case text             // dimension text
    case roomLabel        // room name
    case areaLabel        // area under room name
    case annotation       // field notes
    case boundary         // room boundary (polygon-only rooms) — light dashed
    case symbol           // scale bar, north arrow
    case wallUncertain    // wall with low evidence — heavy, dashed, warning colour
    case finding          // missing-space finding — hatch and outline
    case photoMarker      // positioned photo marker
}

/// A photo taken during the scan, placed where it was taken from.
public struct PlanPhotoMarker: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var position: Vec2
    /// Plan angle (radians) the camera faced, when known.
    public var heading: Double?
    /// Short label drawn in the marker, e.g. "3".
    public var label: String

    public init(id: UUID = UUID(), position: Vec2, heading: Double? = nil, label: String) {
        self.id = id
        self.position = position
        self.heading = heading
        self.label = label
    }
}

/// A colour the engine decides, in the few places where the choice belongs to
/// the drawing rather than to the medium (room coding). Components are 0…1.
public struct PlanColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#RRGGBB`.
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

public extension RoomType {
    /// Room colour coding, in the muted register a client-facing plan uses:
    /// enough to tell the sleeping, wet and living areas apart at a glance,
    /// never enough to fight the walls or the labels for attention.
    var planTint: PlanColor {
        switch self {
        case .bedroom:
            return PlanColor(0.914, 0.780, 0.667)   // warm peach
        case .bathroom, .powderRoom:
            return PlanColor(0.788, 0.855, 0.878)   // pale blue
        case .kitchen:
            return PlanColor(0.867, 0.902, 0.851)   // pale sage
        case .diningRoom:
            return PlanColor(0.941, 0.906, 0.847)   // sand
        case .livingRoom, .familyRoom:
            return PlanColor(0.961, 0.945, 0.925)   // warm off-white
        case .office:
            return PlanColor(0.882, 0.906, 0.937)   // blue-grey
        case .laundry, .utilityRoom, .mechanicalRoom:
            return PlanColor(0.898, 0.890, 0.925)   // lilac-grey
        case .closet, .walkInCloset, .storage:
            return PlanColor(0.933, 0.929, 0.918)   // light grey
        case .garage, .basement:
            return PlanColor(0.925, 0.925, 0.925)
        case .hallway, .foyer, .stairHall, .balcony, .terrace, .other:
            return PlanColor(0.976, 0.973, 0.965)
        }
    }
}

/// Fill styles for closed shapes.
public enum PlanFill: Codable, Hashable, Sendable {
    case wallPoche        // solid cut-wall fill
    case wallNewPoche     // new wall fill (rendered lighter / hatched)
    case fixtureFill      // very light fill
    case roomTint(RoomType)   // room colour coding
    case none
}

public enum TextAnchor: String, Codable, Sendable {
    case center
    case bottomCenter
    case topCenter
    case leftCenter
}

/// One drawable primitive in plan coordinates (meters, +Y up).
public enum PlanPrimitive: Codable, Hashable, Sendable {
    case line(a: Vec2, b: Vec2, pen: PlanPen)
    case polyline(points: [Vec2], closed: Bool, pen: PlanPen)
    case polygon(points: [Vec2], fill: PlanFill, outline: PlanPen?)
    case circle(center: Vec2, radius: Double, pen: PlanPen, filled: Bool)
    /// Arc around `center`, radians, counter-clockwise from startAngle to endAngle.
    case arc(center: Vec2, radius: Double, startAngle: Double, endAngle: Double, pen: PlanPen)
    /// Text height is in plan meters so it scales with the drawing.
    case text(string: String, position: Vec2, height: Double, rotation: Double, anchor: TextAnchor, pen: PlanPen)
}

public enum PlanLayerKind: String, Codable, CaseIterable, Sendable {
    case roomFills      // colour coding, drawn under everything
    case findings       // missing-space hatches, over fills and under walls
    case walls
    case demolition
    case newConstruction
    case openings
    case fixtures
    case furniture
    case dimensions
    case labels
    case annotations
    case photos         // positioned photo markers
    case decor          // scale bar, north arrow

    public var displayName: String {
        switch self {
        case .roomFills: return "Room Colors"
        case .findings: return "Unscanned Space"
        case .walls: return "Walls"
        case .demolition: return "Demolition"
        case .newConstruction: return "New Construction"
        case .openings: return "Doors & Windows"
        case .fixtures: return "Fixtures"
        case .furniture: return "Furniture"
        case .dimensions: return "Dimensions"
        case .labels: return "Room Labels"
        case .annotations: return "Notes"
        case .photos: return "Photos"
        case .decor: return "Scale & North"
        }
    }
}

public struct PlanLayer: Codable, Hashable, Sendable {
    public var kind: PlanLayerKind
    public var primitives: [PlanPrimitive]

    public init(kind: PlanLayerKind, primitives: [PlanPrimitive] = []) {
        self.kind = kind
        self.primitives = primitives
    }
}

/// Sheet title block drawn under the plan on shared exports (spec §14, §43).
///
/// Every field is pre-formatted text: the engine never decides how a date, an
/// area or a phone number should read — the app does, using the owner's unit
/// and branding settings — so the same block renders identically to PNG, SVG,
/// PDF and DXF. Empty fields are skipped.
public struct PlanTitleBlock: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// Centered under the plan with no border: company, then area totals.
        /// The look of a client-facing marketing sheet.
        case centered
        /// Bordered two-column sheet block: identity left, facts right.
        /// The look of a drawing issued for construction.
        case sheet

        public var displayName: String {
            switch self {
            case .centered: return "Centered"
            case .sheet: return "Drawing Sheet"
            }
        }
    }

    /// How the block is laid out under the plan.
    public var style: Style
    /// Area totals under the company name in `.centered` style, e.g.
    /// "Total GLA: 547 sq ft" then "1st floor: 547 sq ft".
    public var summaryLines: [String]
    /// Property / project name — the largest line.
    public var projectName: String
    /// Street address, including any unit number.
    public var address: String
    /// What this sheet shows, e.g. "Existing Conditions — Level 1".
    public var planTitle: String
    /// Pre-formatted total floor area, e.g. "812 sq ft".
    public var totalArea: String
    /// Pre-formatted date, e.g. "Aug 30, 2026".
    public var dateText: String
    /// Company or contractor name.
    public var preparedBy: String
    /// Phone / email / license line.
    public var contact: String
    /// Optional flag line, e.g. "SAMPLE DATA — not a field measurement".
    public var note: String

    public init(
        style: Style = .centered,
        summaryLines: [String] = [],
        projectName: String = "",
        address: String = "",
        planTitle: String = "",
        totalArea: String = "",
        dateText: String = "",
        preparedBy: String = "",
        contact: String = "",
        note: String = ""
    ) {
        self.style = style
        self.summaryLines = summaryLines
        self.projectName = projectName
        self.address = address
        self.planTitle = planTitle
        self.totalArea = totalArea
        self.dateText = dateText
        self.preparedBy = preparedBy
        self.contact = contact
        self.note = note
    }

    /// True when there is nothing at all to draw.
    public var isEmpty: Bool {
        ([projectName, address, planTitle, totalArea, dateText, preparedBy, contact, note]
            + summaryLines)
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// The complete generated 2D plan for one level.
public struct PlanScene: Codable, Hashable, Sendable {
    public var layers: [PlanLayer]
    public var bounds: Rect2
    public var levelName: String

    public init(layers: [PlanLayer], bounds: Rect2, levelName: String) {
        self.layers = layers
        self.bounds = bounds
        self.levelName = levelName
    }

    public func layer(_ kind: PlanLayerKind) -> PlanLayer? {
        layers.first { $0.kind == kind }
    }

    /// All primitives from visible layers, in draw order.
    public func primitives(visibleLayers: Set<PlanLayerKind>? = nil) -> [PlanPrimitive] {
        layers
            .filter { visibleLayers?.contains($0.kind) ?? true }
            .flatMap(\.primitives)
    }
}

/// Which renovation state the plan depicts (spec §23–§25).
public enum PlanRenderMode: String, Codable, CaseIterable, Sendable {
    case existing     // existing elements only (new hidden)
    case proposed     // demolished hidden, new shown
    case demolition   // existing + demolished (dashed), new hidden
    case overlay      // everything, distinguished by pen

    public var displayName: String {
        switch self {
        case .existing: return "Existing"
        case .proposed: return "Proposed"
        case .demolition: return "Demolition"
        case .overlay: return "Overlay"
        }
    }
}
