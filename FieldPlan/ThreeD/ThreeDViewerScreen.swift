import SwiftUI
import SceneKit
import QuickLook
import SwiftData
import FieldPlanCore

/// Interactive 3D dollhouse (spec §32, §33) built from FieldPlan's canonical
/// geometry — orbit/pan/zoom, existing/proposed modes, furniture toggle,
/// cutaway wall height, element selection and two-point measuring.
/// SceneKit is used deliberately: free-camera orbit controls are built in and
/// reliable offline. Raw scan USDZ files preview through QuickLook.
struct ThreeDViewerScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @State private var levels: [LevelGeometry] = []
    @State private var mode: PlanRenderMode = .existing
    @State private var showFurniture = true
    @State private var cutaway: Double = 1.0
    @State private var measureMode = false
    @State private var measurePoints: [SCNVector3] = []
    @State private var measuredDistance: Double? = nil
    @State private var selectionInfo: String? = nil
    @State private var sceneVersion = 0
    @State private var quickLookItem: ShareFile? = nil

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    var body: some View {
        ZStack(alignment: .bottom) {
            if levels.isEmpty || levels.allSatisfy({ $0.walls.isEmpty && $0.rooms.isEmpty }) {
                ContentUnavailableView(
                    "Nothing to Show in 3D",
                    systemImage: "cube.transparent",
                    description: Text("Scan rooms first — the 3D model builds from your floor plan geometry."))
            } else {
                SceneKitContainer(
                    levels: levels,
                    mode: mode,
                    showFurniture: showFurniture,
                    cutaway: cutaway,
                    measureMode: measureMode,
                    sceneVersion: sceneVersion,
                    onSelect: { info in
                        selectionInfo = info
                    },
                    onMeasurePoint: { point in
                        registerMeasurePoint(point)
                    })
                    .ignoresSafeArea(edges: .bottom)

                controlsOverlay
            }
        }
        .navigationTitle("3D View")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Mode", selection: $mode) {
                        Text("Existing").tag(PlanRenderMode.existing)
                        Text("Proposed").tag(PlanRenderMode.proposed)
                    }
                    Toggle("Furniture", isOn: $showFurniture)
                    Divider()
                    let usdzScans = project.scans.filter { $0.usdzFileName != nil }
                    if !usdzScans.isEmpty {
                        Menu("Raw Scan (USDZ)") {
                            ForEach(usdzScans) { scan in
                                Button(scan.roomName) {
                                    if let name = scan.usdzFileName {
                                        quickLookItem = ShareFile(url: ProjectStore.shared
                                            .scansDir(project.id)
                                            .appendingPathComponent(name))
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("3D options")
            }
        }
        .onAppear(perform: load)
        .onChange(of: mode) { _, _ in sceneVersion += 1 }
        .onChange(of: showFurniture) { _, _ in sceneVersion += 1 }
        .sheet(item: $quickLookItem) { file in
            QuickLookPreview(url: file.url)
        }
    }

    private var controlsOverlay: some View {
        VStack(spacing: 8) {
            if let selectionInfo {
                Text(selectionInfo)
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            if measureMode {
                Text(measureStatus)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            HStack(spacing: 14) {
                Toggle(isOn: $measureMode) {
                    Image(systemName: "ruler")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Measure between two points")
                .onChange(of: measureMode) { _, _ in
                    measurePoints = []
                    measuredDistance = nil
                }

                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.caption)
                    Slider(value: $cutaway, in: 0.15...1.0)
                        .frame(width: 130)
                        .accessibilityLabel("Wall cutaway height")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
        }
        .padding(.bottom, 12)
    }

    private var measureStatus: String {
        if let measuredDistance {
            return "Distance: \(formatter.length(measuredDistance)) — scan-derived, verify critical dimensions"
        }
        return measurePoints.isEmpty ? "Tap the first point" : "Tap the second point"
    }

    private func load() {
        do {
            let snapshot = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            levels = snapshot.levels
            sceneVersion += 1
        } catch {
            AppLog.store.error("3D load failed: \(error.localizedDescription)")
        }
    }

    private func registerMeasurePoint(_ point: SCNVector3) {
        measurePoints.append(point)
        if measurePoints.count == 2 {
            let a = measurePoints[0]
            let b = measurePoints[1]
            let dx = Double(b.x - a.x)
            let dy = Double(b.y - a.y)
            let dz = Double(b.z - a.z)
            measuredDistance = (dx * dx + dy * dy + dz * dz).squareRoot()
            measurePoints = []
        } else {
            measuredDistance = nil
        }
    }
}

// MARK: - SceneKit wrapper

private struct SceneKitContainer: UIViewRepresentable {
    let levels: [LevelGeometry]
    let mode: PlanRenderMode
    let showFurniture: Bool
    let cutaway: Double
    let measureMode: Bool
    let sceneVersion: Int
    let onSelect: (String?) -> Void
    let onMeasurePoint: (SCNVector3) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = UIColor.systemBackground
        view.antialiasingMode = .multisampling4X
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        rebuild(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.measureMode = measureMode
        context.coordinator.onSelect = onSelect
        context.coordinator.onMeasurePoint = onMeasurePoint
        if context.coordinator.builtVersion != sceneVersion {
            rebuild(view, coordinator: context.coordinator)
        }
        // Live cutaway without rebuilding.
        if let walls = view.scene?.rootNode.childNode(withName: "wallsGroup", recursively: false) {
            walls.scale = SCNVector3(1, Float(cutaway), 1)
        }
    }

    private func rebuild(_ view: SCNView, coordinator: Coordinator) {
        view.scene = ThreeDSceneBuilder.build(
            levels: levels, mode: mode, showFurniture: showFurniture)
        coordinator.builtVersion = sceneVersion
        coordinator.levels = levels
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(measureMode: measureMode, onSelect: onSelect, onMeasurePoint: onMeasurePoint)
    }

    final class Coordinator: NSObject {
        weak var view: SCNView?
        var measureMode: Bool
        var onSelect: (String?) -> Void
        var onMeasurePoint: (SCNVector3) -> Void
        var builtVersion = -1
        var levels: [LevelGeometry] = []

        init(measureMode: Bool, onSelect: @escaping (String?) -> Void, onMeasurePoint: @escaping (SCNVector3) -> Void) {
            self.measureMode = measureMode
            self.onSelect = onSelect
            self.onMeasurePoint = onMeasurePoint
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            let location = recognizer.location(in: view)
            let hits = view.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            guard let hit = hits.first else {
                onSelect(nil)
                return
            }
            if measureMode {
                onMeasurePoint(hit.worldCoordinates)
                return
            }
            // Resolve element info from the node name ("wall:<uuid>" etc).
            var node: SCNNode? = hit.node
            while let current = node, current.name == nil {
                node = current.parent
            }
            guard let name = node?.name else {
                onSelect(nil)
                return
            }
            onSelect(Self.info(for: name, levels: levels))
        }

        static func info(for nodeName: String, levels: [LevelGeometry]) -> String? {
            let formatter = SettingsStore.shared.formatter
            let parts = nodeName.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
            for level in levels {
                switch String(parts[0]) {
                case "wall":
                    if let wall = level.wall(withID: id) {
                        return "Wall — \(formatter.length(wall.length)) long · \(formatter.length(wall.height)) high"
                    }
                case "fixture":
                    if let fixture = level.fixtures.first(where: { $0.id == id }) {
                        return "\(fixture.displayName) — \(formatter.length(fixture.size.x)) × \(formatter.length(fixture.size.y))"
                    }
                case "room":
                    if let room = level.room(withID: id) {
                        return "\(room.name) — \(formatter.area(room.floorArea))"
                    }
                default:
                    break
                }
            }
            return nil
        }
    }
}

// MARK: - Scene building

enum ThreeDSceneBuilder {

    static func plans(_ p: Vec2, y: Double) -> SCNVector3 {
        SCNVector3(Float(p.x), Float(y), Float(-p.y))
    }

    static func build(levels: [LevelGeometry], mode: PlanRenderMode, showFurniture: Bool) -> SCNScene {
        let scene = SCNScene()
        let wallsGroup = SCNNode()
        wallsGroup.name = "wallsGroup"
        let floorsGroup = SCNNode()
        floorsGroup.name = "floorsGroup"

        let levelSpacing = 3.4 // vertical separation between stories
        for level in levels.sorted(by: { $0.storyIndex < $1.storyIndex }) {
            let baseY = Double(level.storyIndex) * levelSpacing

            for wall in level.walls where includeInMode(wall.changeStatus, mode: mode) {
                for node in wallNodes(for: wall, mode: mode) {
                    node.position.y += Float(baseY)
                    wallsGroup.addChildNode(node)
                }
            }
            for room in level.rooms where room.polygon.count >= 3 {
                if let node = floorNode(for: room) {
                    node.position.y += Float(baseY)
                    floorsGroup.addChildNode(node)
                }
            }
            for fixture in level.fixtures where includeInMode(fixture.changeStatus, mode: mode) {
                if fixture.category.isFurniture && !showFurniture { continue }
                let node = fixtureNode(for: fixture, mode: mode)
                node.position.y += Float(baseY)
                wallsGroup.addChildNode(node)
            }
        }

        scene.rootNode.addChildNode(floorsGroup)
        scene.rootNode.addChildNode(wallsGroup)

        // Frame the model with a starting camera.
        let (center, radius) = boundingSphere(of: levels)
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 500
        let distance = max(radius * 2.2, 6)
        cameraNode.position = SCNVector3(
            Float(center.x + distance * 0.7),
            Float(distance * 0.8),
            Float(-center.y + distance * 0.7))
        cameraNode.look(at: SCNVector3(Float(center.x), 0, Float(-center.y)))
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        return scene
    }

    static func includeInMode(_ status: ChangeStatus, mode: PlanRenderMode) -> Bool {
        switch mode {
        case .proposed: return status != .demolish
        default: return status != .new
        }
    }

    static func wallMaterial(for status: ChangeStatus, mode: PlanRenderMode) -> SCNMaterial {
        let material = SCNMaterial()
        switch status {
        case .new where mode == .proposed:
            material.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.85)
        case .demolish where mode != .proposed:
            material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.5)
        default:
            material.diffuse.contents = UIColor(white: 0.92, alpha: 1)
        }
        material.locksAmbientWithDiffuse = true
        return material
    }

    /// Boxes for the wall body split around openings (real holes for doors
    /// and windows, headers and sills included).
    static func wallNodes(for wall: Wall, mode: PlanRenderMode) -> [SCNNode] {
        var nodes: [SCNNode] = []
        let length = wall.length
        guard length > 0.02 else { return nodes }
        let angle = wall.angle
        let material = wallMaterial(for: wall.changeStatus, mode: mode)

        func box(from: Double, to: Double, bottom: Double, top: Double) {
            let w = to - from
            let h = top - bottom
            guard w > 0.01, h > 0.01 else { return }
            let geometry = SCNBox(
                width: CGFloat(w), height: CGFloat(h),
                length: CGFloat(max(wall.thickness, 0.02)), chamferRadius: 0)
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            let mid2D = wall.point(atOffset: (from + to) / 2)
            node.position = plans(mid2D, y: bottom + h / 2)
            node.eulerAngles.y = Float(angle)
            node.name = "wall:\(wall.id.uuidString)"
            nodes.append(node)
        }

        let openings = wall.openings
            .filter { includeInMode($0.changeStatus, mode: mode) }
            .sorted { $0.startOffset < $1.startOffset }

        var cursor = 0.0
        for opening in openings {
            let start = max(0, opening.startOffset)
            let end = min(length, opening.endOffset)
            if start > cursor {
                box(from: cursor, to: start, bottom: 0, top: wall.height)
            }
            // Header above the opening.
            let headTop = opening.sillHeight + opening.height
            if headTop < wall.height {
                box(from: start, to: end, bottom: headTop, top: wall.height)
            }
            // Sill below windows.
            if opening.sillHeight > 0.02 {
                box(from: start, to: end, bottom: 0, top: opening.sillHeight)
            }
            cursor = max(cursor, end)
        }
        if cursor < length {
            box(from: cursor, to: length, bottom: 0, top: wall.height)
        }
        return nodes
    }

    static func floorNode(for room: RoomShape) -> SCNNode? {
        let polygon = room.polygon
        guard polygon.count >= 3 else { return nil }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: polygon[0].x, y: polygon[0].y))
        for p in polygon.dropFirst() {
            path.addLine(to: CGPoint(x: p.x, y: p.y))
        }
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0.08)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.8, alpha: 1)
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        // Shape lies in its local XY plane extruded along Z; lay it flat so
        // plan +y maps to scene −z and the slab top sits at floor level.
        node.eulerAngles.x = -.pi / 2
        node.position.y = -0.04
        node.name = "room:\(room.id.uuidString)"
        return node
    }

    static func fixtureNode(for fixture: FixtureItem, mode: PlanRenderMode) -> SCNNode {
        let height = fixture.height ?? defaultHeight(for: fixture.category)
        let geometry = SCNBox(
            width: CGFloat(max(fixture.size.x, 0.05)),
            height: CGFloat(max(height, 0.05)),
            length: CGFloat(max(fixture.size.y, 0.05)),
            chamferRadius: 0.01)
        let material = SCNMaterial()
        switch fixture.changeStatus {
        case .demolish where mode != .proposed:
            material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.45)
        case .new where mode == .proposed:
            material.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.6)
        default:
            material.diffuse.contents = fixture.category.isFurniture
                ? UIColor.systemBrown.withAlphaComponent(0.55)
                : UIColor.systemTeal.withAlphaComponent(0.6)
        }
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position = plans(fixture.center, y: height / 2)
        node.eulerAngles.y = Float(fixture.rotation)
        node.name = "fixture:\(fixture.id.uuidString)"
        return node
    }

    static func defaultHeight(for category: FixtureCategory) -> Double {
        switch category {
        case .cabinetBase, .island, .vanity: return 0.9
        case .cabinetUpper, .medicineCabinet: return 0.75
        case .countertop: return 0.04
        case .refrigerator: return 1.75
        case .stove, .oven, .dishwasher, .washerDryer: return 0.9
        case .toilet: return 0.75
        case .bathtub: return 0.55
        case .shower: return 2.0
        case .bed: return 0.6
        case .sofa, .chair: return 0.8
        case .table: return 0.75
        case .storage: return 1.8
        case .column: return 2.4
        case .radiator: return 0.7
        case .fireplace: return 1.1
        case .stairs: return 0.2
        case .television: return 0.7
        case .rangeHood: return 0.4
        case .sink: return 0.2
        case .soffit: return 0.3
        case .custom: return 0.9
        }
    }

    static func boundingSphere(of levels: [LevelGeometry]) -> (center: Vec2, radius: Double) {
        var bounds = Rect2.null
        for level in levels {
            bounds.include(level.bounds)
        }
        guard !bounds.isNull else { return (Vec2.zero, 5) }
        return (bounds.center, max(bounds.width, bounds.height) / 2 + 1)
    }
}

// MARK: - QuickLook (raw USDZ scans)

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
