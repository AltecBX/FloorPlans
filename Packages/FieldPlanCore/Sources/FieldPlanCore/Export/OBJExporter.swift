import Foundation

// MARK: - OBJ export (brief §19)
//
// A Wavefront OBJ of the canonical model: the same walls, floor slabs and
// fixtures the 3D viewer builds, written straight from `LevelGeometry` so
// the file matches the plan to the millimetre and depends on no rendering
// framework. Metres, Y up; plan +y becomes −z, as in the viewer. Materials
// are flat colours in a companion MTL.

public enum OBJExporter {

    public struct Options: Sendable {
        public var mode: PlanRenderMode = .existing
        public var includeFixtures = true
        public var includeFurniture = true
        /// Story spacing when a level has no scanned floor height.
        public var levelSpacing = 3.4
        public var materialFileName = "fieldplan.mtl"
        /// Floor slab thickness below the finished floor.
        public var slabThickness = 0.08
        public init() {}
    }

    public struct Output: Sendable {
        public var obj: String
        public var mtl: String
    }

    public static func export(levels: [LevelGeometry], options: Options = Options()) -> Output {
        var writer = Writer()
        writer.line("# Jerry FieldPlans model — metres, Y up, plan north is -Z")
        writer.line("mtllib \(options.materialFileName)")
        let measured = levels.count > 1 && levels.allSatisfy { $0.elevation != nil }
        let lowest = levels.compactMap(\.elevation).min() ?? 0
        for level in levels.sorted(by: { $0.storyIndex < $1.storyIndex }) {
            let base = measured
                ? (level.elevation ?? 0) - lowest
                : Double(level.storyIndex) * options.levelSpacing
            writer.line("g \(safe(level.name))")
            for wall in level.walls where included(wall.changeStatus, options.mode) {
                writer.wall(wall, base: base, mode: options.mode)
            }
            for room in level.rooms where room.polygon.count >= 3 && included(room.changeStatus, options.mode) {
                writer.floor(room, base: base, slab: options.slabThickness)
            }
            for fixture in level.fixtures where included(fixture.changeStatus, options.mode) {
                if fixture.category.isFurniture {
                    guard options.includeFurniture else { continue }
                } else {
                    guard options.includeFixtures else { continue }
                }
                writer.fixture(fixture, base: base)
            }
        }
        return Output(obj: writer.text, mtl: materials)
    }

    /// Whether an element with `status` appears in a model of `mode` — the
    /// same rule the 2D plan applies.
    static func included(_ status: ChangeStatus, _ mode: PlanRenderMode) -> Bool {
        PlanGenerator.includeElement(status, mode: mode)
    }

    static func safe(_ name: String) -> String {
        let cleaned = name.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(cleaned).isEmpty ? "level" : String(cleaned)
    }

    static let materials = """
    # Jerry FieldPlans materials
    newmtl wall
    Kd 0.92 0.91 0.88
    Ka 0.92 0.91 0.88
    newmtl wall_demolished
    Kd 0.85 0.32 0.30
    Ka 0.85 0.32 0.30
    newmtl wall_new
    Kd 0.30 0.52 0.86
    Ka 0.30 0.52 0.86
    newmtl floor
    Kd 0.80 0.74 0.62
    Ka 0.80 0.74 0.62
    newmtl fixture
    Kd 0.85 0.87 0.90
    Ka 0.85 0.87 0.90
    newmtl furniture
    Kd 0.70 0.66 0.60
    Ka 0.70 0.66 0.60

    """

    /// Typical height and bottom offset (metres) when a fixture carries no
    /// scanned height; wall-hung items start above the floor.
    static func heightAndBottom(for category: FixtureCategory) -> (height: Double, bottom: Double) {
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

    // MARK: Writer

    struct Writer {
        var text = ""
        var vertexCount = 0
        var currentMaterial = ""

        mutating func line(_ s: String) {
            text += s
            text += "\n"
        }

        mutating func material(_ name: String) {
            guard name != currentMaterial else { return }
            line("usemtl \(name)")
            currentMaterial = name
        }

        mutating func vertex(_ p: Vec2, y: Double) -> Int {
            line(String(format: "v %.4f %.4f %.4f", p.x, y, -p.y))
            vertexCount += 1
            return vertexCount
        }

        mutating func face(_ ids: [Int]) {
            line("f " + ids.map(String.init).joined(separator: " "))
        }

        /// A solid with a plan footprint between two heights: top and bottom
        /// triangulated (so an L-shaped floor is fine), one quad per side,
        /// all faces wound outward.
        mutating func prism(_ footprint: [Vec2], bottom: Double, top: Double) {
            guard footprint.count >= 3, top - bottom > 1e-6 else { return }
            let polygon = GeometryOps.counterClockwise(footprint)
            let lower = polygon.map { vertex($0, y: bottom) }
            let upper = polygon.map { vertex($0, y: top) }
            for (a, b, c) in GeometryOps.triangulate(polygon) {
                face([upper[a], upper[b], upper[c]])
                face([lower[c], lower[b], lower[a]])
            }
            for i in 0..<polygon.count {
                let j = (i + 1) % polygon.count
                face([lower[i], lower[j], upper[j], upper[i]])
            }
        }

        mutating func wall(_ wall: Wall, base: Double, mode: PlanRenderMode) {
            let length = wall.length
            guard length > 0.02 else { return }
            let name: String
            switch wall.changeStatus {
            case .demolish where mode == .demolition || mode == .overlay: name = "wall_demolished"
            case .new where mode == .proposed || mode == .overlay: name = "wall_new"
            default: name = "wall"
            }
            line("o wall_\(wall.id.uuidString.prefix(8))")
            material(name)
            let dir = wall.direction
            let perp = dir.perpendicular
            let ht = max(wall.thickness, 0.02) / 2

            func box(from: Double, to: Double, bottom: Double, top: Double) {
                guard to - from > 0.01, top - bottom > 0.01 else { return }
                let p1 = wall.start + dir * from
                let p2 = wall.start + dir * to
                prism([p1 - perp * ht, p2 - perp * ht, p2 + perp * ht, p1 + perp * ht],
                      bottom: base + bottom, top: base + top)
            }

            let openings = wall.openings
                .filter { OBJExporter.included($0.changeStatus, mode) }
                .sorted { $0.startOffset < $1.startOffset }
            var cursor = 0.0
            for opening in openings {
                let start = max(0, opening.startOffset)
                let end = min(length, opening.endOffset)
                if start > cursor { box(from: cursor, to: start, bottom: 0, top: wall.height) }
                let headTop = opening.sillHeight + opening.height
                if headTop < wall.height { box(from: start, to: end, bottom: headTop, top: wall.height) }
                if opening.sillHeight > 0.02 { box(from: start, to: end, bottom: 0, top: opening.sillHeight) }
                cursor = max(cursor, end)
            }
            if cursor < length { box(from: cursor, to: length, bottom: 0, top: wall.height) }
        }

        mutating func floor(_ room: RoomShape, base: Double, slab: Double) {
            line("o floor_\(OBJExporter.safe(room.name))_\(room.id.uuidString.prefix(8))")
            material("floor")
            prism(room.polygon, bottom: base - slab, top: base)
        }

        mutating func fixture(_ fixture: FixtureItem, base: Double) {
            let defaults = OBJExporter.heightAndBottom(for: fixture.category)
            let height = fixture.height ?? defaults.height
            line("o \(fixture.category.rawValue)_\(fixture.id.uuidString.prefix(8))")
            material(fixture.category.isFurniture ? "furniture" : "fixture")
            if fixture.category == .stairs {
                // Solid steps rising toward the fixture's local +y, the way
                // the plan symbol's arrow points.
                let w = fixture.size.x
                let d = fixture.size.y
                let treads = max(2, Int(d / 0.28))
                func local(_ x: Double, _ y: Double) -> Vec2 { Vec2(x, y).rotated(by: fixture.rotation) + fixture.center }
                for i in 0..<treads {
                    let y0 = -d / 2 + d * Double(i) / Double(treads)
                    let y1 = -d / 2 + d * Double(i + 1) / Double(treads)
                    let top = height * Double(i + 1) / Double(treads)
                    prism([local(-w / 2, y0), local(w / 2, y0), local(w / 2, y1), local(-w / 2, y1)],
                          bottom: base, top: base + top)
                }
                return
            }
            prism(fixture.corners, bottom: base + defaults.bottom, top: base + defaults.bottom + height)
        }
    }
}
