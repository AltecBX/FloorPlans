import Foundation

// MARK: - Dollhouse model
//
// The whole 3D model of a plan, built from the canonical geometry and nothing
// else: walls that meet cleanly at every corner, real door and window
// openings with jambs, heads, sills, frames, glass and open door leaves,
// baseboards, floors with a finish per room, and — optionally — ceilings.
// Every element keeps its plan ID and its renovation tint, so the viewer can
// answer a tap and colour new and demolished work the way the 2D plan does.
//
// Nothing is smoothed, averaged or moved: every face sits where the plan
// says. What is added (trim sizes, door leaf thickness, frame depth) is
// drawn detail, the same few centimetres a hand-drawn elevation would add,
// and never changes a measured dimension.

/// A plan built as 3D geometry, one entry per level.
public struct DollhouseModel: Sendable {

    public struct Element: Sendable {
        public enum Kind: String, Sendable {
            case wall, opening, floor, ceiling, fixture
        }
        public var kind: Kind
        /// The plan element this was built from.
        public var id: UUID
        public var tint: DollhouseTint
        public var mesh: DollhouseMesh
    }

    /// Where a room's name goes in 3D.
    public struct RoomLabel: Sendable {
        public var id: UUID
        public var name: String
        public var type: RoomType
        /// Floor area, square metres.
        public var area: Double
        /// On the floor, at the room's visual centre.
        public var position: Vec3
    }

    public struct Level: Sendable {
        public var id: UUID
        public var name: String
        public var storyIndex: Int
        /// Finished floor height in the model, metres.
        public var floorHeight: Double
        /// Tallest wall on the level as built (after any cut).
        public var wallHeight: Double
        public var elements: [Element]
        public var rooms: [RoomLabel]

        public var bounds: (min: Vec3, max: Vec3)? {
            DollhouseModel.union(elements.compactMap(\.mesh.bounds))
        }
    }

    public var levels: [Level]

    public init(levels: [Level]) {
        self.levels = levels
    }

    public var bounds: (min: Vec3, max: Vec3)? {
        DollhouseModel.union(levels.compactMap(\.bounds))
    }

    public var triangleCount: Int {
        levels.reduce(0) { $0 + $1.elements.reduce(0) { $0 + $1.mesh.triangleCount } }
    }

    static func union(_ boxes: [(min: Vec3, max: Vec3)]) -> (min: Vec3, max: Vec3)? {
        guard var result = boxes.first else { return nil }
        for box in boxes.dropFirst() {
            result.min = Vec3(min(result.min.x, box.min.x), min(result.min.y, box.min.y), min(result.min.z, box.min.z))
            result.max = Vec3(max(result.max.x, box.max.x), max(result.max.y, box.max.y), max(result.max.z, box.max.z))
        }
        return result
    }
}

public enum DollhouseBuilder {

    public struct Options: Sendable {
        public var mode: PlanRenderMode = .existing
        /// Walls stop this far above each level's floor, drawn with a cut
        /// top; nil draws them full height.
        public var cutHeight: Double?
        /// Ceilings, for looking around inside. Never drawn with a cut.
        public var includeCeilings = false
        /// Hinged and folding doors drawn open, so rooms read as connected.
        public var doorsOpen = true
        /// Story spacing when the levels carry no measured floor heights. Nil
        /// stacks each story on the walls below it, with a floor structure
        /// between.
        public var levelSpacing: Double?
        /// Floor slab thickness below the finished floor of the lowest level.
        /// Upper levels' slabs fill down to the walls below them.
        public var slabThickness = 0.08
        /// Baseboards, casings, stools and aprons.
        public var includeTrim = true
        /// Plain boxes for fixtures and furniture (the OBJ export; the viewer
        /// draws its own models).
        public var includeFixtures = false
        public var includeFurniture = false

        public init() {}
    }

    // MARK: Drawn detail (metres)

    static let baseboardHeight = 0.09
    static let baseboardDepth = 0.013
    static let casingWidth = 0.07
    static let casingDepth = 0.012
    /// A door saddle's height above the floor.
    static let thresholdHeight = 0.008
    /// A cased opening's floor, just proud of the rooms either side so the two
    /// never fight for the same pixels.
    static let openingFloorHeight = 0.004

    /// Depth of the floor structure between stories when levels are stacked
    /// without measured heights (joists and subfloor, about a foot).
    public static let floorStructure = 0.3

    // MARK: Building

    /// Where each level sits: its finished floor height and how thick its
    /// slab is drawn.
    public struct Placement: Hashable, Sendable {
        public var floorHeight: Double
        public var slab: Double
    }

    /// Measured floor heights are used when every level has one; otherwise
    /// each story stands on the tallest wall below it plus a floor structure
    /// (or at a fixed `levelSpacing`). The lowest level is at zero. An upper
    /// slab is drawn down to the walls below, so the stories read as one
    /// building rather than floating trays. The viewer, the snapshot and
    /// the OBJ all use this.
    public static func placements(for levels: [LevelGeometry], options: Options = Options()) -> [UUID: Placement] {
        let sorted = levels.sorted { $0.storyIndex < $1.storyIndex }
        let measured = levels.count > 1 && levels.allSatisfy { $0.elevation != nil }
        func tallest(_ level: LevelGeometry) -> Double {
            level.walls.filter { PlanGenerator.includeElement($0.changeStatus, mode: options.mode) }
                .map(\.height).max() ?? 2.4384
        }

        var floors: [Double] = []
        if measured {
            let lowest = levels.compactMap(\.elevation).min() ?? 0
            floors = sorted.map { ($0.elevation ?? 0) - lowest }
        } else if let spacing = options.levelSpacing {
            let lowest = sorted.first.map { Double($0.storyIndex) * spacing } ?? 0
            floors = sorted.map { Double($0.storyIndex) * spacing - lowest }
        } else {
            var height = 0.0
            for level in sorted {
                floors.append(height)
                height += tallest(level) + floorStructure
            }
        }

        var result: [UUID: Placement] = [:]
        for (i, level) in sorted.enumerated() {
            var slab = options.slabThickness
            if i > 0 {
                let below = floors[i - 1] + tallest(sorted[i - 1])
                let gap = floors[i] - below
                // Fill a plausible floor structure; a bigger gap is a scan
                // that put the stories apart, and stays visible.
                if gap > slab && gap < 1.0 { slab = gap }
            }
            result[level.id] = Placement(floorHeight: floors[i], slab: slab)
        }
        return result
    }

    /// Finished floor height of each level (see `placements`).
    public static func floorHeights(for levels: [LevelGeometry], options: Options = Options()) -> [UUID: Double] {
        placements(for: levels, options: options).mapValues(\.floorHeight)
    }

    public static func build(levels: [LevelGeometry], options: Options = Options()) -> DollhouseModel {
        let placed = placements(for: levels, options: options)
        let sorted = levels.sorted { $0.storyIndex < $1.storyIndex }
        return DollhouseModel(levels: sorted.map { level in
            var own = options
            let placement = placed[level.id] ?? Placement(floorHeight: 0, slab: options.slabThickness)
            own.slabThickness = placement.slab
            return build(level: level, floorHeight: placement.floorHeight, options: own)
        })
    }

    public static func build(level: LevelGeometry, floorHeight: Double, options: Options) -> DollhouseModel.Level {
        let mode = options.mode
        let walls = level.walls.filter {
            PlanGenerator.includeElement($0.changeStatus, mode: mode) && $0.length > 0.02
        }
        let rooms = level.rooms.filter {
            PlanGenerator.includeElement($0.changeStatus, mode: mode) && $0.polygon.count >= 3
                && GeometryOps.area($0.polygon) > 0.05
        }
        let context = WallContext(walls: walls, rooms: rooms, base: floorHeight, options: options)

        var elements: [DollhouseModel.Element] = []
        var tallest = 0.0
        for index in walls.indices {
            let built = context.build(wall: index)
            tallest = max(tallest, context.top(of: index))
            elements.append(built.wall)
            elements += built.openings
        }

        for room in rooms {
            let tint = DollhouseTint.for(room.changeStatus, mode: mode)
            var mesh = DollhouseMesh()
            addFloor(room, base: floorHeight, slab: options.slabThickness, to: &mesh)
            elements.append(.init(kind: .floor, id: room.id, tint: tint, mesh: mesh))

            if options.includeCeilings && options.cutHeight == nil {
                let height = room.ceilingHeight ?? context.ceilingFallback(for: room)
                var ceiling = DollhouseMesh()
                ceiling.addHorizontal(room.polygon, y: floorHeight + height, facingUp: false, material: .ceiling)
                elements.append(.init(kind: .ceiling, id: room.id, tint: tint, mesh: ceiling))
            }
        }

        if options.includeFixtures || options.includeFurniture {
            for fixture in level.fixtures where PlanGenerator.includeElement(fixture.changeStatus, mode: mode) {
                if fixture.category.isFurniture {
                    guard options.includeFurniture else { continue }
                } else {
                    guard options.includeFixtures else { continue }
                }
                let mesh = fixtureMesh(fixture, base: floorHeight)
                guard !mesh.isEmpty else { continue }
                elements.append(.init(kind: .fixture, id: fixture.id,
                                      tint: DollhouseTint.for(fixture.changeStatus, mode: mode), mesh: mesh))
            }
        }

        let labels = rooms.map { room in
            DollhouseModel.RoomLabel(
                id: room.id,
                name: room.name.isEmpty ? room.type.displayName : room.name,
                type: room.type,
                area: room.floorArea,
                position: Scene3D.point(room.labelPoint, floorHeight + 0.01))
        }

        return DollhouseModel.Level(
            id: level.id, name: level.name, storyIndex: level.storyIndex,
            floorHeight: floorHeight, wallHeight: tallest,
            elements: elements, rooms: labels)
    }

    // MARK: Floors

    /// A room's floor slab: the finish on top, ceiling paint underneath, and
    /// the cut edge in the section colour.
    static func addFloor(_ room: RoomShape, base: Double, slab: Double, to mesh: inout DollhouseMesh) {
        let polygon = GeometryOps.counterClockwise(room.polygon)
        let finish = FloorFinish.for(room.type)
        mesh.addHorizontal(polygon, y: base, facingUp: true, material: .floor(finish),
                           uvAngle: plankAngle(polygon))
        mesh.addHorizontal(polygon, y: base - slab, facingUp: false, material: .ceiling)
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            let edge = b - a
            guard edge.length > 1e-7 else { continue }
            mesh.addVertical(from: a, to: b, bottom: base - slab, top: base,
                             outward: Vec2(edge.y, -edge.x), material: .wallCap)
        }
    }

    /// Floorboards run along a room's longest wall, the way they are laid.
    static func plankAngle(_ polygon: [Vec2]) -> Double {
        var best = 0.0
        var angle = 0.0
        for i in polygon.indices {
            let edge = polygon[(i + 1) % polygon.count] - polygon[i]
            if edge.length > best {
                best = edge.length
                angle = edge.angle
            }
        }
        return angle
    }

    // MARK: Fixtures

    /// A plain solid for a fixture at its mounting height; stairs as steps.
    public static func fixtureMesh(_ fixture: FixtureItem, base: Double) -> DollhouseMesh {
        var mesh = DollhouseMesh()
        let material: DollhouseMaterial = fixture.category.isFurniture ? .furniture : .fixture
        let extent = FixtureMounting.extent(of: fixture)
        let w = max(fixture.size.x, 0.02)
        let d = max(fixture.size.y, 0.02)
        func local(_ x: Double, _ y: Double) -> Vec2 {
            Vec2(x, y).rotated(by: fixture.rotation) + fixture.center
        }
        if fixture.category == .stairs {
            // Solid steps rising toward the fixture's local +y, the way the
            // plan symbol's arrow points.
            let treads = max(2, Int(d / 0.28))
            for i in 0..<treads {
                let y0 = -d / 2 + d * Double(i) / Double(treads)
                let y1 = -d / 2 + d * Double(i + 1) / Double(treads)
                let top = extent.height * Double(i + 1) / Double(treads)
                mesh.addPrism([local(-w / 2, y0), local(w / 2, y0), local(w / 2, y1), local(-w / 2, y1)],
                              bottom: base, top: base + top, material: material, skipBottom: true)
            }
            return mesh
        }
        mesh.addPrism(fixture.corners, bottom: base + extent.bottom, top: base + extent.top,
                      material: material, skipBottom: extent.bottom < 0.001)
        return mesh
    }
}
