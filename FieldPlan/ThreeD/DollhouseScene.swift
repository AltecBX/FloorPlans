import SceneKit
import UIKit
import FieldPlanCore

/// The ways to look at the model.
enum ThreeDCameraPreset: String, CaseIterable, Identifiable {
    /// High three-quarter view, orbiting the house.
    case dollhouse
    /// Straight down, like the plan with walls.
    case top
    /// Eye height inside a room, looking around.
    case walk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dollhouse: return "Dollhouse"
        case .top: return "Top"
        case .walk: return "Walk"
        }
    }

    var systemImage: String {
        switch self {
        case .dollhouse: return "house"
        case .top: return "square.grid.2x2"
        case .walk: return "figure.walk"
        }
    }
}

/// The SceneKit scene for a plan: the core's dollhouse geometry turned into
/// nodes with materials, furniture placed at its measured height, room
/// labels, light and a camera.
///
/// It is kept alive while the viewer is on screen and updated in place: a
/// new cut height rebuilds only the walls, a furniture toggle only the
/// furniture, a floor change only flips which level is visible — the camera
/// never jumps because something unrelated changed.
@MainActor
final class DollhouseScene {

    struct Configuration: Equatable {
        var mode: PlanRenderMode = .existing
        /// Walls stop this far above each floor; nil is full height.
        var cutHeight: Double? = nil
        var doorsOpen = true
        var ceilings = false
        var furniture = true
        var labels = true
        /// The one level shown; nil shows them all.
        var visibleLevel: UUID? = nil
        var darkBackground = false
    }

    /// What the camera frames.
    struct Framing {
        var center: SIMD3<Float>
        var radius: Float
        var min: SIMD3<Float>
        var max: SIMD3<Float>
    }

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private(set) var levels: [LevelGeometry] = []
    private(set) var configuration = Configuration()
    private(set) var model = DollhouseModel(levels: [])

    private let modelRoot = SCNNode()
    private var levelNodes: [UUID: LevelNodes] = [:]
    private var rig: SCNNode?
    private var structureKey: StructureKey?
    private var furnitureKey: FurnitureKey?

    private struct LevelNodes {
        var root = SCNNode()
        var structure = SCNNode()
        var fixtures = SCNNode()
        var labels = SCNNode()
    }

    private struct StructureKey: Equatable {
        var version: Int
        var mode: PlanRenderMode
        var cut: Double?
        var doorsOpen: Bool
        var ceilings: Bool
    }

    private struct FurnitureKey: Equatable {
        var version: Int
        var mode: PlanRenderMode
        var furniture: Bool
    }

    private var levelsVersion = 0

    init() {
        modelRoot.name = "model"
        scene.rootNode.addChildNode(modelRoot)
        let camera = SCNCamera()
        camera.fieldOfView = 35
        SceneStyling.styleCamera(camera)
        cameraNode.camera = camera
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)
    }

    // MARK: Updating

    /// Brings the scene up to date, rebuilding only what changed. `version`
    /// changes whenever `levels` do.
    func update(levels: [LevelGeometry], version: Int, configuration: Configuration) {
        let levelsChanged = version != levelsVersion || self.levels.isEmpty != levels.isEmpty
        if levelsChanged {
            self.levels = levels
            levelsVersion = version
            for nodes in levelNodes.values { nodes.root.removeFromParentNode() }
            levelNodes = [:]
            for level in levels {
                var nodes = LevelNodes()
                nodes.root.name = "level:\(level.id.uuidString)"
                nodes.root.addChildNode(nodes.structure)
                nodes.root.addChildNode(nodes.fixtures)
                nodes.root.addChildNode(nodes.labels)
                modelRoot.addChildNode(nodes.root)
                levelNodes[level.id] = nodes
            }
            structureKey = nil
            furnitureKey = nil
        }

        let structure = StructureKey(version: version, mode: configuration.mode, cut: configuration.cutHeight,
                                     doorsOpen: configuration.doorsOpen, ceilings: configuration.ceilings)
        if structure != structureKey {
            rebuildStructure(configuration)
            structureKey = structure
        }
        let furniture = FurnitureKey(version: version, mode: configuration.mode, furniture: configuration.furniture)
        if furniture != furnitureKey {
            rebuildFixtures(configuration)
            furnitureKey = furniture
        }

        if levelsChanged || rig == nil {
            // Light and ground follow the whole, uncut model, so they stay put
            // while the cut or the visible floor changes.
            rig?.removeFromParentNode()
            let whole = framing(for: nil)
            let newRig = SceneStyling.lightingRig(center: whole.center, radius: whole.radius, groundY: whole.min.y)
            scene.rootNode.addChildNode(newRig)
            rig = newRig
        }

        for (id, nodes) in levelNodes {
            nodes.root.isHidden = configuration.visibleLevel.map { $0 != id } ?? false
            nodes.labels.isHidden = !configuration.labels
        }
        SceneStyling.applyEnvironment(to: scene, background: SceneStyling.background(dark: configuration.darkBackground))
        self.configuration = configuration
    }

    private func buildOptions(_ configuration: Configuration) -> DollhouseBuilder.Options {
        var options = DollhouseBuilder.Options()
        options.mode = configuration.mode
        options.cutHeight = configuration.cutHeight
        options.doorsOpen = configuration.doorsOpen
        options.includeCeilings = configuration.ceilings
        return options
    }

    private func rebuildStructure(_ configuration: Configuration) {
        model = DollhouseBuilder.build(levels: levels, options: buildOptions(configuration))
        let formatter = SettingsStore.shared.formatter
        let whole = model.bounds.map { simdBox($0) }
        let labelScale = whole.map { Swift.max(1, simd_length($0.max - $0.min) / 14) } ?? 1
        for level in model.levels {
            guard let nodes = levelNodes[level.id] else { continue }
            nodes.structure.childNodes.forEach { $0.removeFromParentNode() }
            nodes.labels.childNodes.forEach { $0.removeFromParentNode() }
            for element in level.elements {
                if let node = Self.node(for: element) {
                    nodes.structure.addChildNode(node)
                }
            }
            for room in level.rooms {
                nodes.labels.addChildNode(Self.labelNode(
                    room, area: formatter.area(room.area), scale: labelScale,
                    height: configuration.cutHeight.map { Swift.min($0, 1.6) } ?? 1.6))
            }
        }
    }

    private func rebuildFixtures(_ configuration: Configuration) {
        let placements = DollhouseBuilder.placements(for: levels, options: buildOptions(configuration))
        for level in levels {
            guard let nodes = levelNodes[level.id] else { continue }
            nodes.fixtures.childNodes.forEach { $0.removeFromParentNode() }
            let floor = placements[level.id]?.floorHeight ?? 0
            for fixture in level.fixtures
            where PlanGenerator.includeElement(fixture.changeStatus, mode: configuration.mode) {
                if fixture.category.isFurniture && !configuration.furniture { continue }
                let tint = DollhouseTint.for(fixture.changeStatus, mode: configuration.mode)
                nodes.fixtures.addChildNode(FixturePlacement.node(for: fixture, in: level, floor: floor, tint: tint))
            }
        }
    }

    // MARK: Framing

    /// The box the camera should frame: one level, or everything.
    func framing(for levelID: UUID?) -> Framing {
        let boxes: [(min: Vec3, max: Vec3)]
        if let levelID, let level = model.levels.first(where: { $0.id == levelID }), let box = level.bounds {
            boxes = [box]
        } else {
            boxes = model.levels.compactMap(\.bounds)
        }
        guard var lo = boxes.first?.min, var hi = boxes.first?.max else {
            return Framing(center: .zero, radius: 5, min: SIMD3(-5, 0, -5), max: SIMD3(5, 3, 5))
        }
        for box in boxes.dropFirst() {
            lo = Vec3(Swift.min(lo.x, box.min.x), Swift.min(lo.y, box.min.y), Swift.min(lo.z, box.min.z))
            hi = Vec3(Swift.max(hi.x, box.max.x), Swift.max(hi.y, box.max.y), Swift.max(hi.z, box.max.z))
        }
        let box = simdBox((lo, hi))
        let center = (box.min + box.max) / 2
        return Framing(center: center, radius: Swift.max(simd_length(box.max - box.min) / 2, 1.5),
                       min: box.min, max: box.max)
    }

    private func simdBox(_ box: (min: Vec3, max: Vec3)) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        (SIMD3(Float(box.min.x), Float(box.min.y), Float(box.min.z)),
         SIMD3(Float(box.max.x), Float(box.max.y), Float(box.max.z)))
    }

    // MARK: Camera presets

    /// Puts the camera where a preset looks from. `aspect` is width ÷ height
    /// of the view, so the whole model fits whichever way the phone is held.
    func placeCamera(_ preset: ThreeDCameraPreset, aspect: Float) {
        guard let camera = cameraNode.camera else { return }
        let frame = framing(for: configuration.visibleLevel)
        let fit = { (fov: Float) -> Float in
            // Distance at which the bounding sphere fits the narrower side.
            let vertical = fov * .pi / 180
            let horizontal = 2 * atan(tan(vertical / 2) * Swift.max(aspect, 0.2))
            return frame.radius / sin(Swift.min(vertical, horizontal) / 2) * 1.02
        }
        camera.usesOrthographicProjection = false

        switch preset {
        case .dollhouse:
            camera.fieldOfView = 35
            SceneStyling.styleCamera(camera)
            let distance = fit(35)
            // From the south-east, 38° above the horizon.
            let azimuth: Float = 35 * .pi / 180
            let elevation: Float = 38 * .pi / 180
            let offset = SIMD3<Float>(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
            cameraNode.simdPosition = frame.center + offset * distance
            cameraNode.simdLook(at: frame.center)
        case .top:
            camera.fieldOfView = 25
            SceneStyling.styleCamera(camera)
            let extentX = (frame.max.x - frame.min.x) / 2
            let extentZ = (frame.max.z - frame.min.z) / 2
            let vertical: Float = 25 * .pi / 180
            let halfHeight = Swift.max(extentZ, extentX / Swift.max(aspect, 0.2)) * 1.08
            let distance = halfHeight / tan(vertical / 2) + frame.max.y - frame.center.y
            // A hair off vertical, so orbiting from here never flips.
            cameraNode.simdPosition = frame.center + SIMD3<Float>(0, distance, 0.002 * distance)
            cameraNode.simdLook(at: frame.center)
        case .walk:
            camera.fieldOfView = 68
            SceneStyling.styleCamera(camera, interior: true)
            let (eye, target) = walkStart()
            cameraNode.simdPosition = eye
            cameraNode.simdLook(at: target)
        }
    }

    /// Eye height in the largest room of the level in view, looking across it.
    private func walkStart() -> (eye: SIMD3<Float>, target: SIMD3<Float>) {
        let level = model.levels.first { $0.id == configuration.visibleLevel } ?? model.levels.first
        let source = levels.first { $0.id == level?.id }
        let floor = Float(level?.floorHeight ?? 0)
        guard let room = source?.rooms.filter({ $0.polygon.count >= 3 }).max(by: { $0.floorArea < $1.floorArea })
        else {
            let frame = framing(for: nil)
            return (frame.center + SIMD3(0, 0.2, 0), frame.center + SIMD3(0, 0, -1))
        }
        // Stand near one end of the room's long axis and look along it.
        let polygon = room.polygon
        let label = room.labelPoint
        var far = polygon[0]
        for p in polygon where p.distance(to: label) > far.distance(to: label) { far = p }
        let back = label + (label - far).normalized * Swift.min(1.0, label.distance(to: far) * 0.3)
        let eyePlan = GeometryOps.polygonContains(polygon, back) ? back : label
        let eye = SIMD3<Float>(Float(eyePlan.x), floor + 1.6, Float(-eyePlan.y))
        let target = SIMD3<Float>(Float(far.x), floor + 1.25, Float(-far.y))
        return (eye, simd_distance(eye, target) > 0.3 ? target : eye + SIMD3(0, -0.1, -1))
    }

    // MARK: Nodes

    /// A node for one element, named so a tap finds it ("wall:<uuid>").
    /// Glass is a child of its own that casts no shadow, so a window lets the
    /// sun into the room.
    static func node(for element: DollhouseModel.Element) -> SCNNode? {
        let mesh = element.mesh
        guard !mesh.isEmpty else { return nil }
        let opaque = mesh.submeshes.filter { $0.material != .glass }
        let glass = mesh.submeshes.filter { $0.material == .glass }
        let node = SCNNode()
        node.name = "\(element.kind.rawValue):\(element.id.uuidString)"
        node.categoryBitMask = SceneCategory.model
        node.geometry = geometry(mesh, opaque, tint: element.tint)
        if let panes = geometry(mesh, glass, tint: element.tint) {
            let child = SCNNode(geometry: panes)
            child.castsShadow = false
            child.categoryBitMask = SceneCategory.model
            node.addChildNode(child)
        }
        return node
    }

    static func geometry(_ mesh: DollhouseMesh, _ submeshes: [DollhouseMesh.Submesh],
                         tint: DollhouseTint) -> SCNGeometry? {
        guard !submeshes.isEmpty else { return nil }
        let vertices = mesh.positions.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
        let normals = mesh.normals.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
        let uvs = mesh.uvs.map { CGPoint(x: $0.x, y: $0.y) }
        let sources = [
            SCNGeometrySource(vertices: vertices),
            SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: uvs),
        ]
        let elements = submeshes.map { SCNGeometryElement(indices: $0.indices, primitiveType: .triangles) }
        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = submeshes.map { SceneStyling.material($0.material, tint: tint) }
        return geometry
    }

    /// A room's name and area on a card that always faces the camera,
    /// floating above the floor.
    static func labelNode(_ room: DollhouseModel.RoomLabel, area: String, scale: Float, height: Double) -> SCNNode {
        let image = labelImage(name: room.name, detail: area)
        let worldHeight = CGFloat(0.34 * scale)
        let plane = SCNPlane(width: worldHeight * image.size.width / Swift.max(image.size.height, 1),
                             height: worldHeight)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.name = "label:\(room.id.uuidString)"
        node.position = SCNVector3(Float(room.position.x), Float(room.position.y + height * 0.6),
                                   Float(room.position.z))
        node.renderingOrder = 100
        node.castsShadow = false
        node.categoryBitMask = SceneCategory.label
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    private static func labelImage(name: String, detail: String) -> UIImage {
        let title = NSAttributedString(string: name, attributes: [
            .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: UIColor(white: 0.12, alpha: 1),
        ])
        let subtitle = NSAttributedString(string: detail, attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 26, weight: .regular),
            .foregroundColor: UIColor(white: 0.35, alpha: 1),
        ])
        let titleSize = title.size()
        let subtitleSize = subtitle.size()
        let padding: CGFloat = 22
        let size = CGSize(width: ceil(Swift.max(titleSize.width, subtitleSize.width) + padding * 2),
                          height: ceil(titleSize.height + subtitleSize.height + padding * 1.2))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let card = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height * 0.28)
            UIColor(white: 1, alpha: 0.9).setFill()
            card.fill()
            title.draw(at: CGPoint(x: (size.width - titleSize.width) / 2, y: padding * 0.6))
            subtitle.draw(at: CGPoint(x: (size.width - subtitleSize.width) / 2,
                                      y: padding * 0.6 + titleSize.height))
        }
    }
}

// MARK: - Fixtures

/// Furniture and fixtures in the 3D model: a real model where one is
/// installed, the parametric one otherwise, standing at its measured height.
@MainActor
enum FixturePlacement {

    static func node(for fixture: FixtureItem, in level: LevelGeometry, floor: Double, tint: DollhouseTint) -> SCNNode {
        let extent = FixtureMounting.extent(of: fixture)
        // Renovation state overrides the palette so new and demolished items
        // stay obvious, the same blue and red the walls use.
        let override: UIColor?
        switch tint {
        case .none: override = nil
        case .new: override = SceneStyling.newWork.color
        case .demolish: override = SceneStyling.demolition.color
        }
        // Both builds put their origin at the footprint centre on its
        // underside, so placement is identical either way.
        let node = (override == nil
                    ? FurnitureLibrary.node(for: fixture.category, size: fixture.size, height: extent.height)
                    : nil)
            ?? FurnitureModels.node(for: fixture, height: extent.height, override: override)
        node.position = SCNVector3(Float(fixture.center.x), Float(floor + extent.bottom), Float(-fixture.center.y))
        node.eulerAngles.y = Float(wallFacingYaw(for: fixture, in: level) ?? fixture.rotation)
        node.name = "fixture:\(fixture.id.uuidString)"
        return node
    }

    /// Turns a piece so its back is to the nearest wall.
    ///
    /// RoomPlan reports an oriented bounding box with no notion of a front, so
    /// the scanned rotation is only correct to a half turn — with primitives
    /// that hardly showed, but a real sofa rendered backwards into the room is
    /// obvious. Anything that belongs against a wall is turned to face away
    /// from the nearest one; free-standing pieces (tables, chairs, islands)
    /// keep the rotation as scanned.
    ///
    /// Returns nil when nothing is close enough to take a cue from.
    static func wallFacingYaw(for fixture: FixtureItem, in level: LevelGeometry) -> Double? {
        guard backsToWall(fixture.category) else { return nil }
        let reach = max(fixture.size.x, fixture.size.y) * 0.75 + 0.35

        var nearest: (distance: Double, forward: Vec2)?
        for wall in level.walls {
            let closest = GeometryOps.closestPointOnSegment(fixture.center, wall.start, wall.end)
            let distance = fixture.center.distance(to: closest)
            guard distance < reach else { continue }
            guard nearest == nil || distance < nearest!.distance else { continue }
            let away = fixture.center - closest
            let forward = away.length > 1e-6 ? away.normalized : wall.direction.perpendicular
            nearest = (distance, forward)
        }
        guard let forward = nearest?.forward else { return nil }

        // Plan (x, y) maps to scene (x, -y), and a model's front is its local
        // -Z, which a yaw rotation sends to (-sin, 0, -cos).
        return atan2(-forward.x, forward.y)
    }

    /// Pieces that stand against a wall in a real room.
    static func backsToWall(_ category: FixtureCategory) -> Bool {
        switch category {
        case .sofa, .bed, .refrigerator, .stove, .oven, .dishwasher, .washerDryer,
             .toilet, .sink, .vanity, .cabinetBase, .cabinetUpper, .storage,
             .television, .mirror, .bathtub, .shower, .fireplace, .medicineCabinet,
             .radiator:
            return true
        default:
            return false
        }
    }
}
