import Foundation

/// How high a fixture sits and how tall it is, for anything drawn in 3D.
///
/// The scan measures each object's box, including where its underside is, so
/// an upper cabinet, a mirror or a wall-mounted TV is drawn at the height it
/// was found. Older scans and hand-placed items carry no elevation; they use
/// the category's usual mounting height instead. One table, so the viewer,
/// the report image and the OBJ export put things at the same height.
public enum FixtureMounting {

    public struct Extent: Hashable, Sendable {
        /// Underside above the finished floor, metres.
        public var bottom: Double
        public var height: Double
        public var top: Double { bottom + height }
    }

    /// A scanned underside within this of the floor is the floor: RoomPlan's
    /// boxes wobble by a few centimetres and a sofa should not hover.
    public static let floorSnap = 0.06

    public static func extent(of fixture: FixtureItem) -> Extent {
        let typical = self.typical(for: fixture.category)
        let height = max(fixture.height ?? typical.height, 0.02)
        let bottom: Double
        if let elevation = fixture.elevation, elevation.isFinite {
            bottom = elevation < floorSnap ? 0 : elevation
        } else {
            bottom = typical.bottom
        }
        return Extent(bottom: bottom, height: height)
    }

    /// Typical height and underside height (metres) by category.
    public static func typical(for category: FixtureCategory) -> (height: Double, bottom: Double) {
        switch category {
        case .bathtub: return (0.55, 0)
        case .shower: return (2.0, 0)
        case .toilet: return (0.75, 0)
        case .sink, .vanity: return (0.85, 0)
        case .cabinetBase, .countertop, .island, .stove, .oven, .dishwasher, .washerDryer: return (0.9, 0)
        case .cabinetUpper: return (0.75, 1.4)
        case .refrigerator: return (1.8, 0)
        case .rangeHood: return (0.5, 1.5)
        case .radiator: return (0.6, 0.1)
        case .fireplace: return (1.0, 0)
        case .stairs: return (2.6, 0)
        case .column: return (2.4, 0)
        case .bed: return (0.55, 0)
        case .sofa: return (0.8, 0)
        case .chair: return (0.9, 0)
        case .table: return (0.75, 0)
        case .storage: return (1.8, 0)
        case .television: return (0.7, 0.9)
        case .medicineCabinet: return (0.7, 1.3)
        case .mirror: return (0.9, 1.0)
        case .soffit: return (0.3, 2.1)
        case .custom: return (0.9, 0)
        }
    }
}
