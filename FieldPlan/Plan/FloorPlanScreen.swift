import SwiftUI
import SwiftData
import FieldPlanCore

/// Floor plan viewer: render modes (existing/proposed/demolition/overlay),
/// layer visibility, plan version switcher, side-by-side comparison, and the
/// gateway to the editor (spec §14, §23–§25).
struct FloorPlanScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @State private var snapshot: PlanSnapshot? = nil
    @State private var levelID: UUID? = nil
    @State private var mode: PlanRenderMode = .existing
    @State private var compareSideBySide = false
    @State private var showDimensions = true
    @State private var showFurniture = false
    @State private var showFixtures = true
    @State private var showLabels = true
    @State private var showAnnotations = true
    @State private var errorMessage: String? = nil
    @State private var selectedInfo: String? = nil

    private var currentLevel: LevelGeometry? {
        guard let snapshot else { return nil }
        if let levelID {
            return snapshot.levels.first { $0.id == levelID }
        }
        return snapshot.levels.first
    }

    private func makeScene(mode: PlanRenderMode) -> PlanScene? {
        guard let level = currentLevel else { return nil }
        var options = PlanGenerator.Options()
        options.mode = mode
        options.showDimensions = showDimensions
        options.showFurniture = showFurniture
        options.showFixtures = showFixtures
        options.showRoomLabels = showLabels
        options.showAreaLabels = showLabels
        options.showAnnotations = showAnnotations
        options.formatter = SettingsStore.shared.formatter
        return PlanGenerator.scene(for: level, options: options)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .navigationTitle("Floor Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                layerMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let snapshot, let level = currentLevel {
                    NavigationLink {
                        PlanEditorScreen(project: project, snapshotID: snapshot.id, levelID: level.id)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(snapshot.isLocked)
                }
            }
        }
        .onAppear(perform: load)
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            if let snapshot, snapshot.levels.count > 1 {
                Picker("Level", selection: Binding(
                    get: { levelID ?? snapshot.levels.first?.id },
                    set: { levelID = $0 })) {
                    ForEach(snapshot.levels.sorted(by: { $0.storyIndex < $1.storyIndex })) { level in
                        Text(level.name).tag(Optional(level.id))
                    }
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(PlanRenderMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)

                Spacer()

                Toggle(isOn: $compareSideBySide) {
                    Image(systemName: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Compare existing and proposed side by side")

                versionMenu
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var versionMenu: some View {
        Menu {
            ForEach(project.snapshots.sorted(by: { $0.createdAt < $1.createdAt })) { record in
                Button {
                    project.activeSnapshotID = record.id
                    try? context.save()
                    load()
                } label: {
                    if record.id == snapshot?.id {
                        Label(record.name, systemImage: "checkmark")
                    } else {
                        Text(record.name)
                    }
                }
            }
        } label: {
            Label(snapshot?.name ?? "Version", systemImage: "square.stack.3d.up")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
        }
    }

    private var layerMenu: some View {
        Menu {
            Toggle("Dimensions", isOn: $showDimensions)
            Toggle("Room Labels", isOn: $showLabels)
            Toggle("Fixtures", isOn: $showFixtures)
            Toggle("Furniture", isOn: $showFurniture)
            Toggle("Notes", isOn: $showAnnotations)
        } label: {
            Label("Layers", systemImage: "square.3.layers.3d.down.left")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let level = currentLevel, !(level.walls.isEmpty && level.rooms.isEmpty) {
            if compareSideBySide {
                comparisonView
            } else if let scene = makeScene(mode: mode) {
                ZStack(alignment: .bottom) {
                    PlanCanvasView(
                        scene: scene,
                        onTap: { point, tolerance in
                            tapInfo(point, tolerance: tolerance, level: level)
                        })
                    if let selectedInfo {
                        Text(selectedInfo)
                            .font(.callout.monospacedDigit())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Nothing Captured Yet",
                systemImage: "square.dashed",
                description: Text("Scan the property or add rooms manually, then the plan appears here."))
        }
    }

    private var comparisonView: some View {
        HStack(spacing: 1) {
            VStack(spacing: 0) {
                Text("Existing").font(.caption.weight(.semibold)).padding(4)
                if let scene = makeScene(mode: .existing) {
                    PlanCanvasView(scene: scene)
                }
            }
            Divider()
            VStack(spacing: 0) {
                Text("Proposed").font(.caption.weight(.semibold)).padding(4)
                if let scene = makeScene(mode: .proposed) {
                    PlanCanvasView(scene: scene)
                }
            }
        }
    }

    // MARK: Behavior

    private func load() {
        do {
            ProjectStore.shared.invalidateCache()
            let s = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            snapshot = s
            if levelID == nil || !s.levels.contains(where: { $0.id == levelID }) {
                levelID = s.levels.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func tapInfo(_ point: Vec2, tolerance: Double, level: LevelGeometry) {
        let formatter = SettingsStore.shared.formatter
        let hit = PlanHitTester.hit(point, level: level, tolerance: tolerance)
        withAnimation(.easeInOut(duration: 0.15)) {
            switch hit {
            case .wall(let id):
                if let wall = level.wall(withID: id) {
                    selectedInfo = "Wall — \(formatter.length(wall.length)) · H \(formatter.length(wall.height)) · \(wall.source.displayName)"
                }
            case .opening(let wallID, let openingID):
                if let wall = level.wall(withID: wallID),
                   let opening = wall.openings.first(where: { $0.id == openingID }) {
                    selectedInfo = "\(opening.kind.displayName) — \(formatter.length(opening.width)) × \(formatter.length(opening.height))"
                }
            case .fixture(let id):
                if let fixture = level.fixtures.first(where: { $0.id == id }) {
                    selectedInfo = "\(fixture.displayName) — \(formatter.length(fixture.size.x)) × \(formatter.length(fixture.size.y))"
                }
            case .room(let id):
                if let room = level.room(withID: id) {
                    selectedInfo = "\(room.name) — \(formatter.area(room.floorArea)) · Perimeter \(formatter.linearFeet(room.perimeter))"
                }
            case .corner(_, _, let position):
                selectedInfo = "Corner at (\(formatter.length(position.x)), \(formatter.length(position.y)))"
            case .annotation, .none:
                selectedInfo = nil
            }
        }
    }
}
