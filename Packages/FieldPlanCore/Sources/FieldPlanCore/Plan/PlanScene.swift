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
}

/// Fill styles for closed shapes.
public enum PlanFill: String, Codable, CaseIterable, Sendable {
    case wallPoche        // solid cut-wall fill
    case wallNewPoche     // new wall fill (rendered lighter / hatched)
    case fixtureFill      // very light fill
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
    case walls
    case demolition
    case newConstruction
    case openings
    case fixtures
    case furniture
    case dimensions
    case labels
    case annotations
    case decor          // scale bar, north arrow

    public var displayName: String {
        switch self {
        case .walls: return "Walls"
        case .demolition: return "Demolition"
        case .newConstruction: return "New Construction"
        case .openings: return "Doors & Windows"
        case .fixtures: return "Fixtures"
        case .furniture: return "Furniture"
        case .dimensions: return "Dimensions"
        case .labels: return "Room Labels"
        case .annotations: return "Notes"
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
