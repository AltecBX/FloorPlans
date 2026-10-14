import SwiftUI
import SceneKit
import QuickLook
import SwiftData
import FieldPlanCore

/// Interactive 3D dollhouse (spec §32, §33) built from FieldPlan's canonical
/// geometry by the core's `DollhouseBuilder`: mitred wall corners, real door
/// and window openings with leaves, frames, glass and trim, floors by room,
/// furniture at its measured height. Dollhouse, top and walk-through views,
/// every plan mode, one floor or all, a true cutaway, element info on tap
/// and two-point measuring. SceneKit is used deliberately: orbit and fly
/// controls are built in and reliable offline. Raw scan USDZ files preview
/// through QuickLook.
struct ThreeDViewerScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    let project: ProjectRecord

    @State private var levels: [LevelGeometry] = []
    @State private var levelsVersion = 0
    @State private var mode: PlanRenderMode = .existing
    @State private var preset: ThreeDCameraPreset = .dollhouse
    @State private var cameraRequest = 0
    @State private var selectedLevelID: UUID? = nil
    @State private var showFurniture = true
    @State private var showLabels = true
    @State private var doorsOpen = true
    /// Wall height as a fraction of the tallest wall; 1 is full height.
    @State private var cutaway: Double = 1.0
    /// `cutaway` once the slider pauses: the walls are rebuilt at the new
    /// height, and a big plan should not be rebuilt for every pixel dragged.
    @State private var committedCutaway: Double = 1.0
    @State private var measureMode = false
    @State private var measurePoints: [SCNVector3] = []
    @State private var measuredDistance: Double? = nil
    @State private var selectionInfo: String? = nil
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
                    levelsVersion: levelsVersion,
                    configuration: configuration,
                    preset: preset,
                    cameraRequest: cameraRequest,
                    measureMode: measureMode,
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
                optionsMenu
            }
        }
        .onAppear(perform: load)
        .onChange(of: preset) { _, _ in
            selectionInfo = nil
            cameraRequest += 1
        }
        .onChange(of: selectedLevelID) { _, _ in cameraRequest += 1 }
        .onChange(of: cutaway) { _, value in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                if cutaway == value { committedCutaway = value }
            }
        }
        .sheet(item: $quickLookItem) { file in
            QuickLookPreview(url: file.url)
        }
    }

    /// What the scene should show, from the controls.
    private var configuration: DollhouseScene.Configuration {
        var configuration = DollhouseScene.Configuration()
        configuration.mode = mode
        configuration.doorsOpen = doorsOpen
        configuration.furniture = showFurniture
        configuration.darkBackground = colorScheme == .dark
        if preset == .walk {
            // Inside a room: full walls, ceilings on, one floor.
            configuration.ceilings = true
            configuration.labels = false
            configuration.visibleLevel = selectedLevelID ?? sortedLevels.first?.id
        } else {
            configuration.labels = showLabels
            configuration.visibleLevel = selectedLevelID
            configuration.cutHeight = cutHeight
        }
        return configuration
    }

    private var sortedLevels: [LevelGeometry] {
        levels.sorted { $0.storyIndex < $1.storyIndex }
    }

    private var tallestWall: Double {
        levels.flatMap(\.walls).map(\.height).max() ?? 2.44
    }

    private var cutHeight: Double? {
        cutHeight(for: committedCutaway)
    }

    private func cutHeight(for fraction: Double) -> Double? {
        fraction >= 0.98 ? nil : max(0.3, fraction * tallestWall)
    }

    // MARK: Controls

    private var optionsMenu: some View {
        Menu {
            Picker("Plan", selection: $mode) {
                ForEach(PlanRenderMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Toggle("Furniture", isOn: $showFurniture)
            Toggle("Room Names", isOn: $showLabels)
            Toggle("Doors Open", isOn: $doorsOpen)
            Divider()
            let usdzScans = project.scans.filter { $0.usdzFileName != nil }
            if !usdzScans.isEmpty {
                // Apple's own export of the capture, opened in QuickLook. It is
                // a plain white massing model with no colours or furniture —
                // kept as the untouched record of the scan, not as something
                // to show a client.
                Menu("Raw Scan File — Plain White") {
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

    private var controlsOverlay: some View {
        VStack(spacing: 8) {
            if let selectionInfo {
                Text(selectionInfo)
                    .font(.callout.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            if measureMode {
                Text(measureStatus)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
            }

            Picker("View", selection: $preset) {
                ForEach(ThreeDCameraPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            HStack(spacing: 14) {
                if levels.count > 1 {
                    Menu {
                        Picker("Floor", selection: $selectedLevelID) {
                            Text("All Floors").tag(UUID?.none)
                            ForEach(sortedLevels) { level in
                                Text(level.name).tag(UUID?.some(level.id))
                            }
                        }
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                    }
                    .accessibilityLabel("Choose floor")
                }

                Toggle(isOn: $measureMode) {
                    Image(systemName: "ruler")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Measure between two points")
                .onChange(of: measureMode) { _, _ in
                    measurePoints = []
                    measuredDistance = nil
                }

                if preset != .walk {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.down.right")
                            .font(.caption)
                        Slider(value: $cutaway, in: 0.15...1.0)
                            .frame(width: 120)
                            .accessibilityLabel("Wall height")
                            .accessibilityValue(cutHeight(for: cutaway).map { formatter.length($0) } ?? "Full height")
                    }
                }

                Button {
                    cameraRequest += 1
                } label: {
                    Image(systemName: "scope")
                }
                .accessibilityLabel("Re-centre the view")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
        }
        .padding(.bottom, 12)
        .padding(.horizontal, 16)
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
            levelsVersion += 1
            cameraRequest += 1
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
    let levelsVersion: Int
    let configuration: DollhouseScene.Configuration
    let preset: ThreeDCameraPreset
    let cameraRequest: Int
    let measureMode: Bool
    let onSelect: (String?) -> Void
    let onMeasurePoint: (SCNVector3) -> Void

    func makeUIView(context: Context) -> DollhouseView {
        let view = DollhouseView()
        let dollhouse = context.coordinator.dollhouse
        view.scene = dollhouse.scene
        view.pointOfView = dollhouse.cameraNode
        view.allowsCameraControl = true
        // Move our own camera rather than a hidden copy, so the view presets
        // and the gestures drive the same thing.
        view.cameraControlConfiguration.autoSwitchToFreeCamera = false
        view.cameraControlConfiguration.allowsTranslation = true
        // Off deliberately: the scene carries its own sun, fill and sky light,
        // and the default headlight would flatten the shadows they cast.
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        // Extra smoothing whenever the view is still.
        view.isJitteringEnabled = true
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        // The first layout gives the real size; frame the model for it.
        view.onFirstLayout = { [weak coordinator = context.coordinator] in
            coordinator?.refitAfterLayout()
        }
        return view
    }

    func updateUIView(_ view: DollhouseView, context: Context) {
        let coordinator = context.coordinator
        coordinator.measureMode = measureMode
        coordinator.onSelect = onSelect
        coordinator.onMeasurePoint = onMeasurePoint
        coordinator.levels = levels
        coordinator.dollhouse.update(levels: levels, version: levelsVersion, configuration: configuration)
        if coordinator.appliedCameraRequest != cameraRequest {
            coordinator.applyCamera(preset, animated: coordinator.appliedCameraRequest >= 0 && !levels.isEmpty)
            coordinator.appliedCameraRequest = cameraRequest
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(measureMode: measureMode, onSelect: onSelect, onMeasurePoint: onMeasurePoint)
    }

    /// Main-actor isolated: UIKit delivers tap callbacks on the main thread,
    /// and resolving a tapped element reads the main-actor `SettingsStore` for
    /// the owner's unit formatting.
    @MainActor
    final class Coordinator: NSObject {
        weak var view: DollhouseView?
        let dollhouse = DollhouseScene()
        var measureMode: Bool
        var onSelect: (String?) -> Void
        var onMeasurePoint: (SCNVector3) -> Void
        var appliedCameraRequest = -1
        var appliedPreset: ThreeDCameraPreset = .dollhouse
        var levels: [LevelGeometry] = []

        init(measureMode: Bool, onSelect: @escaping (String?) -> Void, onMeasurePoint: @escaping (SCNVector3) -> Void) {
            self.measureMode = measureMode
            self.onSelect = onSelect
            self.onMeasurePoint = onMeasurePoint
        }

        /// The camera was placed before the view had a size; place it again.
        func refitAfterLayout() {
            guard appliedCameraRequest >= 0 else { return }
            applyCamera(appliedPreset, animated: false)
        }

        func applyCamera(_ preset: ThreeDCameraPreset, animated: Bool) {
            appliedPreset = preset
            let size = view?.bounds.size ?? .zero
            // Before the first layout the view has no size; a phone held
            // upright is the safe guess.
            let aspect = size.width > 1 && size.height > 1 ? Float(size.width / size.height) : 0.46
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.6 : 0
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dollhouse.placeCamera(preset, aspect: aspect)
            SCNTransaction.commit()

            guard let view else { return }
            let controller = view.defaultCameraController
            controller.pointOfView = dollhouse.cameraNode
            switch preset {
            case .dollhouse, .top:
                let frame = dollhouse.framing(for: dollhouse.configuration.visibleLevel)
                controller.interactionMode = .orbitTurntable
                controller.target = SCNVector3(frame.center.x, frame.center.y, frame.center.z)
                // Never orbit under the floor.
                controller.minimumVerticalAngle = 3
                // Just past where the Top view starts, so the first drag
                // does not snap it.
                controller.maximumVerticalAngle = 89.95
            case .walk:
                controller.interactionMode = .fly
                controller.minimumVerticalAngle = -80
                controller.maximumVerticalAngle = 80
            }
            controller.inertiaEnabled = true
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            let location = recognizer.location(in: view)
            let hits = view.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .categoryBitMask: SceneCategory.model,
            ])
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
            while let current = node, current.name.map(Self.isElementName) != true {
                node = current.parent
            }
            guard let name = node?.name else {
                onSelect(nil)
                return
            }
            onSelect(Self.info(for: name, levels: levels))
        }

        static func isElementName(_ name: String) -> Bool {
            ["wall:", "opening:", "floor:", "ceiling:", "fixture:"].contains { name.hasPrefix($0) }
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
                case "opening":
                    for wall in level.walls {
                        guard let opening = wall.openings.first(where: { $0.id == id }) else { continue }
                        let size = "\(formatter.length(opening.width)) × \(formatter.length(opening.height))"
                        switch opening.kind {
                        case .door:
                            return "\(opening.resolvedStyle.displayName) door — \(size)"
                        case .window:
                            return "Window — \(size), sill \(formatter.length(opening.sillHeight))"
                        case .opening:
                            return "Opening — \(size)"
                        }
                    }
                case "fixture":
                    if let fixture = level.fixtures.first(where: { $0.id == id }) {
                        return "\(fixture.displayName) — \(formatter.length(fixture.size.x)) × \(formatter.length(fixture.size.y))"
                    }
                case "floor", "ceiling":
                    if let room = level.room(withID: id) {
                        let name = room.name.isEmpty ? room.type.displayName : room.name
                        return "\(name) — \(formatter.area(room.floorArea))"
                    }
                default:
                    break
                }
            }
            return nil
        }
    }
}

/// An SCNView that says when it first has a real size.
final class DollhouseView: SCNView {
    var onFirstLayout: (() -> Void)?
    private var hasSize = false

    override func layoutSubviews() {
        super.layoutSubviews()
        if !hasSize, bounds.width > 1, bounds.height > 1 {
            hasSize = true
            onFirstLayout?()
        }
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
