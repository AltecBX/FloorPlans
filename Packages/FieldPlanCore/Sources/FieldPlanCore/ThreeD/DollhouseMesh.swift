import Foundation

// MARK: - Dollhouse mesh
//
// The 3D model is built here, in the Foundation-only core, as plain
// triangles — positions, normals, texture coordinates and a material per
// group — so the same geometry feeds the SceneKit viewer, the report
// snapshot and the OBJ export, and so its correctness can be tested on any
// machine. The renderer only decides what each material looks like.
//
// Space: metres, Y up, plan +y becomes scene −z (the convention the viewer and
// the OBJ export already used). Texture coordinates are in metres too, so a
// repeating floor texture keeps its real scale in a closet and a ballroom.

/// What a surface is made of. The renderer maps each to a look; the core only
/// says which surface is which.
public enum DollhouseMaterial: Hashable, Sendable {
    /// Painted wall faces, reveals and the underside of headers.
    case wall
    /// The cut top of a wall — the section a dollhouse is read by.
    case wallCap
    case floor(FloorFinish)
    /// The saddle under a door.
    case threshold
    case baseboard
    case ceiling
    case doorLeaf
    /// Casings and jamb liners around doors, windows and cased openings.
    case trim
    /// Levers and roses.
    case hardware
    case windowFrame
    case glass
    /// The stone or painted top under a window, inside and out.
    case windowSill
    /// Plain boxes standing in for fixtures and furniture where no model is
    /// drawn (the OBJ export).
    case fixture
    case furniture

    /// A stable name for exporters and logs.
    public var name: String {
        switch self {
        case .wall: return "wall"
        case .wallCap: return "wall_cap"
        case .floor(let finish): return "floor_\(finish.rawValue)"
        case .threshold: return "threshold"
        case .baseboard: return "baseboard"
        case .ceiling: return "ceiling"
        case .doorLeaf: return "door"
        case .trim: return "trim"
        case .hardware: return "hardware"
        case .windowFrame: return "window_frame"
        case .glass: return "glass"
        case .windowSill: return "window_sill"
        case .fixture: return "fixture"
        case .furniture: return "furniture"
        }
    }

    public static let all: [DollhouseMaterial] =
        [.wall, .wallCap] + FloorFinish.allCases.map { .floor($0) } +
        [.threshold, .baseboard, .ceiling, .doorLeaf, .trim, .hardware, .windowFrame, .glass, .windowSill,
         .fixture, .furniture]
}

/// The floor drawn in a room. Chosen from the room type the way a listing
/// render stages it; nothing here claims to know what is really on the floor.
public enum FloorFinish: String, CaseIterable, Sendable {
    case wood, tile, carpet, concrete, stone

    public static func `for`(_ type: RoomType) -> FloorFinish {
        switch type {
        case .bathroom, .powderRoom, .laundry, .utilityRoom, .mechanicalRoom:
            return .tile
        case .bedroom:
            return .carpet
        case .garage, .basement:
            return .concrete
        case .balcony, .terrace:
            return .stone
        default:
            return .wood
        }
    }
}

/// How a renovation state is shown. Decided once, in the core, so the viewer,
/// the snapshot and the OBJ agree with the 2D plan about what is highlighted.
public enum DollhouseTint: String, Sendable {
    case none
    /// Proposed new construction.
    case new
    /// Marked for demolition.
    case demolish

    public static func `for`(_ status: ChangeStatus, mode: PlanRenderMode) -> DollhouseTint {
        switch status {
        case .existing:
            return .none
        case .new:
            return mode == .proposed || mode == .overlay ? .new : .none
        case .demolish:
            return mode == .demolition || mode == .overlay ? .demolish : .none
        }
    }
}

/// Triangles for one element. Faces never share vertices, so every crease
/// stays sharp — right for walls, trim and boxes, which is all this draws.
public struct DollhouseMesh: Sendable {

    public struct Submesh: Sendable {
        public var material: DollhouseMaterial
        /// Triangle list, three indices per triangle, counter-clockwise seen
        /// from the side the normal points to.
        public var indices: [Int32]
    }

    public private(set) var positions: [Vec3] = []
    public private(set) var normals: [Vec3] = []
    public private(set) var uvs: [Vec2] = []
    public private(set) var submeshes: [Submesh] = []

    public init() {}

    public var isEmpty: Bool { positions.isEmpty }

    public var triangleCount: Int {
        submeshes.reduce(0) { $0 + $1.indices.count / 3 }
    }

    /// Axis-aligned bounds, or nil for an empty mesh.
    public var bounds: (min: Vec3, max: Vec3)? {
        guard var lo = positions.first else { return nil }
        var hi = lo
        for p in positions {
            lo = Vec3(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y), Swift.min(lo.z, p.z))
            hi = Vec3(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y), Swift.max(hi.z, p.z))
        }
        return (lo, hi)
    }

    /// Total area of the faces drawn in `material` — used by tests to check
    /// that a surface is all there, and only once.
    public func area(of material: DollhouseMaterial) -> Double {
        var total = 0.0
        for sub in submeshes where sub.material == material {
            var i = 0
            while i + 2 < sub.indices.count {
                let a = positions[Int(sub.indices[i])]
                let b = positions[Int(sub.indices[i + 1])]
                let c = positions[Int(sub.indices[i + 2])]
                total += (b - a).cross(c - a).length / 2
                i += 3
            }
        }
        return total
    }

    // MARK: Building

    mutating func append(_ other: DollhouseMesh) {
        let offset = Int32(positions.count)
        positions += other.positions
        normals += other.normals
        uvs += other.uvs
        for sub in other.submeshes {
            let shifted = sub.indices.map { $0 + offset }
            appendIndices(shifted, material: sub.material)
        }
    }

    private mutating func appendIndices(_ indices: [Int32], material: DollhouseMaterial) {
        if let index = submeshes.firstIndex(where: { $0.material == material }) {
            submeshes[index].indices += indices
        } else {
            submeshes.append(Submesh(material: material, indices: indices))
        }
    }

    /// A flat face: `points` lie in one plane and go round its edge in either
    /// direction (concave is fine). Winding is fixed here to face `normal`, so
    /// no caller can draw a face inside out. Texture coordinates are the
    /// position measured along `uAxis` and `vAxis`.
    mutating func addFace(
        _ points: [Vec3],
        normal: Vec3,
        uAxis: Vec3,
        vAxis: Vec3,
        material: DollhouseMaterial
    ) {
        guard points.count >= 3 else { return }
        let n = normal.normalized
        guard n.length > 0.5 else { return }

        // Triangulate in the face's own 2D frame.
        let flat = points.map { Vec2($0.dot(uAxis), $0.dot(vAxis)) }
        guard GeometryOps.area(flat) > 1e-9 else { return }
        let triangles = points.count == 3
            ? [(0, 1, 2)]
            : GeometryOps.triangulate(flat)

        // Wind every triangle to face `normal`, dropping slivers.
        var local: [Int] = []
        local.reserveCapacity(triangles.count * 3)
        for (i, j, k) in triangles {
            let a = points[i], b = points[j], c = points[k]
            let cross = (b - a).cross(c - a)
            guard cross.length > 1e-10 else { continue }
            local += cross.dot(n) >= 0 ? [i, j, k] : [i, k, j]
        }
        guard !local.isEmpty else { return }

        // Only the corners a triangle uses become vertices, so an exported
        // file never carries a point no face refers to.
        var remap = [Int32](repeating: -1, count: points.count)
        var indices: [Int32] = []
        indices.reserveCapacity(local.count)
        for i in local {
            if remap[i] < 0 {
                remap[i] = Int32(positions.count)
                let p = points[i]
                positions.append(p)
                normals.append(n)
                uvs.append(Vec2(p.dot(uAxis), p.dot(vAxis)))
            }
            indices.append(remap[i])
        }
        appendIndices(indices, material: material)
    }

    /// A horizontal face from a plan polygon at height `y`, facing up or down.
    mutating func addHorizontal(
        _ polygon: [Vec2],
        y: Double,
        facingUp: Bool,
        material: DollhouseMaterial,
        uvAngle: Double = 0
    ) {
        let points = polygon.map { Scene3D.point($0, y) }
        // UVs follow the plan rotated by `uvAngle`, so planks can run along a
        // room's length whatever way the room is turned.
        let along = Vec2(cos(uvAngle), sin(uvAngle))
        let across = along.perpendicular
        addFace(points,
                normal: Vec3(0, facingUp ? 1 : -1, 0),
                uAxis: Scene3D.direction(along),
                vAxis: Scene3D.direction(across),
                material: material)
    }

    /// A vertical rectangle standing on the plan segment `a`→`b` between two
    /// heights, facing the plan direction `outward`.
    mutating func addVertical(
        from a: Vec2, to b: Vec2,
        bottom: Double, top: Double,
        outward: Vec2,
        material: DollhouseMaterial
    ) {
        guard top - bottom > 1e-6, a.distance(to: b) > 1e-6 else { return }
        let along = (b - a).normalized
        addFace([Scene3D.point(a, bottom), Scene3D.point(b, bottom),
                 Scene3D.point(b, top), Scene3D.point(a, top)],
                normal: Scene3D.direction(outward.normalized),
                uAxis: Scene3D.direction(along),
                vAxis: Vec3(0, 1, 0),
                material: material)
    }

    /// A solid with a plan footprint between two heights: top, bottom and one
    /// side per footprint edge. `skipBottom` leaves out the face against the
    /// floor, which nobody sees.
    mutating func addPrism(
        _ footprint: [Vec2],
        bottom: Double,
        top: Double,
        material: DollhouseMaterial,
        topMaterial: DollhouseMaterial? = nil,
        skipBottom: Bool = false
    ) {
        guard footprint.count >= 3, top - bottom > 1e-6 else { return }
        let polygon = GeometryOps.counterClockwise(footprint)
        guard GeometryOps.area(polygon) > 1e-9 else { return }
        addHorizontal(polygon, y: top, facingUp: true, material: topMaterial ?? material)
        if !skipBottom {
            addHorizontal(polygon, y: bottom, facingUp: false, material: material)
        }
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            let edge = b - a
            guard edge.length > 1e-7 else { continue }
            // Counter-clockwise: the outside is to the right of every edge.
            addVertical(from: a, to: b, bottom: bottom, top: top,
                        outward: Vec2(edge.y, -edge.x), material: material)
        }
    }

    /// An upright box on an oriented plan rectangle: `center`, the unit
    /// direction of its width `axis`, and its full width and depth.
    mutating func addBox(
        center: Vec2,
        axis: Vec2,
        width: Double,
        depth: Double,
        bottom: Double,
        top: Double,
        material: DollhouseMaterial,
        skipBottom: Bool = false
    ) {
        guard width > 1e-6, depth > 1e-6 else { return }
        let u = axis.normalized
        let v = u.perpendicular
        let hu = u * (width / 2)
        let hv = v * (depth / 2)
        addPrism([center - hu - hv, center + hu - hv, center + hu + hv, center - hu + hv],
                 bottom: bottom, top: top, material: material, skipBottom: skipBottom)
    }
}

/// The plan-to-scene mapping, in one place.
public enum Scene3D {
    /// Plan point at a height: (x, y) → (x, height, −y).
    public static func point(_ p: Vec2, _ height: Double) -> Vec3 {
        Vec3(p.x, height, -p.y)
    }

    /// Horizontal plan direction as a scene vector.
    public static func direction(_ d: Vec2) -> Vec3 {
        Vec3(d.x, 0, -d.y)
    }
}
