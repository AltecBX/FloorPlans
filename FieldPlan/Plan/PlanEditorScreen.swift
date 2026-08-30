import SwiftUI
import SwiftData
import FieldPlanCore

/// Professional 2D plan editor (spec §16, §17): select/move walls, corners,
/// openings and fixtures, exact dimension editing with strategies, add
/// elements, undo/redo, snap and grid — all with jobsite-sized controls.
struct PlanEditorScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord
    let snapshotID: UUID
    let levelID: UUID

    enum Tool: String, CaseIterable, Identifiable {
        case select, addWall, addDoor, addWindow, addOpening, addFixture, addNote, addDimension, splitRoom

        var id: String { rawValue }

        var label: (String, String) {
            switch self {
            case .select: return ("Select", "cursorarrow")
            case .addWall: return ("Wall", "line.diagonal")
            case .addDoor: return ("Door", "door.left.hand.open")
            case .addWindow: return ("Window", "window.vertical.open")
            case .addOpening: return ("Opening", "rectangle.portrait")
            case .addFixture: return ("Fixture", "sink")
            case .addNote: return ("Note", "note.text.badge.plus")
            case .addDimension: return ("Dimension", "ruler")
            case .splitRoom: return ("Split Room", "scissors")
            }
        }
    }

    // Working state
    @State private var level: LevelGeometry? = nil
    @State private var history: [LevelGeometry] = []
    @State private var historyIndex = 0
    @State private var tool: Tool = .select
    @State private var selection: PlanHit = .none
    @State private var showGrid = true
    @State private var snapEnabled = true
    @State private var orthoEnabled = true
    @State private var showDimensions = true
    @State private var showFurniture = true

    // Gesture state
    @State private var dragOriginLevel: LevelGeometry? = nil
    @State private var dragStartPoint: Vec2? = nil
    @State private var pendingPoint: Vec2? = nil // first tap of two-tap tools
    @State private var mergeSourceRoomID: UUID? = nil

    // UI state
    @State private var errorMessage: String? = nil
    @State private var showQA = false
    @State private var noteDraft = ""
    @State private var notePosition: Vec2? = nil
    @State private var fixturePlacement: PositionBox? = nil

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    private var scene: PlanScene? {
        guard let level else { return nil }
        var options = PlanGenerator.Options()
        options.mode = .overlay
        options.showDimensions = showDimensions
        options.showFurniture = showFurniture
        options.showScaleBar = false
        options.formatter = formatter
        return PlanGenerator.scene(for: level, options: options)
    }

    var body: some View {
        Group {
            if let scene, let level {
                PlanCanvasView(
                    scene: scene,
                    overlay: selectionOverlay(level: level),
                    onTap: handleTap,
                    onDragStart: handleDragStart,
                    onDragChanged: handleDragChanged,
                    onDragEnded: handleDragEnded,
                    showGrid: showGrid)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Edit Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { bottomPanel }
        .onAppear(perform: load)
        .onDisappear { persist() }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showQA) {
            if let level {
                QAFindingsSheet(level: level)
            }
        }
        .sheet(item: $fixturePlacement) { box in
            FixturePickerSheet(position: box.position) { fixture in
                commit { EditorEngine.addFixture(to: $0, fixture) }
                fixturePlacement = nil
            }
        }
        .alert("Add Note", isPresented: Binding(
            get: { notePosition != nil },
            set: { if !$0 { notePosition = nil } })) {
            TextField("Note text", text: $noteDraft)
            Button("Add") {
                if let position = notePosition, !noteDraft.isEmpty {
                    let annotation = PlanAnnotation(kind: .note, text: noteDraft, position: position)
                    commit { EditorEngine.addAnnotation(to: $0, annotation) }
                }
                noteDraft = ""
                notePosition = nil
            }
            Button("Cancel", role: .cancel) {
                noteDraft = ""
                notePosition = nil
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(historyIndex <= 0)
            .accessibilityLabel("Undo")

            Button {
                redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(historyIndex >= history.count - 1)
            .accessibilityLabel("Redo")

            Menu {
                Toggle("Grid", isOn: $showGrid)
                Toggle("Snap to Corners & Grid", isOn: $snapEnabled)
                Toggle("Ortho Snap (New Walls)", isOn: $orthoEnabled)
                Divider()
                Toggle("Dimensions", isOn: $showDimensions)
                Toggle("Furniture", isOn: $showFurniture)
                Divider()
                Button {
                    showQA = true
                } label: {
                    Label("Run QA Checks", systemImage: "checkmark.shield")
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Editor options")
        }
    }

    // MARK: - Bottom panel (tools + inspector)

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            inspector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Tool.allCases) { t in
                        Button {
                            tool = t
                            pendingPoint = nil
                            if t != .select { selection = .none }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: t.label.1)
                                    .font(.body)
                                Text(t.label.0)
                                    .font(.caption2)
                            }
                            .frame(minWidth: 58, minHeight: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(tool == t ? Color.accentColor.opacity(0.2) : Color.clear))
                            .foregroundStyle(tool == t ? Color.accentColor : Color.primary)
                        }
                        .accessibilityLabel(t.label.0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let level {
            switch selection {
            case .wall(let id):
                if let wall = level.wall(withID: id) {
                    WallInspector(
                        wall: wall,
                        formatter: formatter,
                        onSetLength: { newLength, strategy in
                            commit { EditorEngine.setWallLength(in: $0, wallID: id, newLength: newLength, strategy: strategy) }
                        },
                        onSetHeight: { height in
                            commit { lvl in
                                var updated = lvl
                                if let i = updated.walls.firstIndex(where: { $0.id == id }) {
                                    updated.walls[i].height = height
                                    updated.walls[i].source = .edited
                                }
                                return updated
                            }
                        },
                        onSetThickness: { thickness in
                            commit { lvl in
                                var updated = lvl
                                if let i = updated.walls.firstIndex(where: { $0.id == id }) {
                                    updated.walls[i].thickness = thickness
                                }
                                return updated
                            }
                        },
                        onStatus: { status in
                            commit { EditorEngine.setWallChangeStatus(in: $0, wallID: id, status: status) }
                        },
                        onSplit: {
                            if let wall = level.wall(withID: id) {
                                if let split = EditorEngine.splitWall(in: level, wallID: id, atOffset: wall.length / 2) {
                                    commitAbsolute(split)
                                } else {
                                    errorMessage = "This wall can't be split at its midpoint (an opening is in the way)."
                                }
                            }
                        },
                        onDelete: {
                            commit { EditorEngine.deleteWall(in: $0, wallID: id) }
                            selection = .none
                        })
                }
            case .opening(let wallID, let openingID):
                if let wall = level.wall(withID: wallID),
                   let opening = wall.openings.first(where: { $0.id == openingID }) {
                    OpeningInspector(
                        wall: wall,
                        opening: opening,
                        resolvedSwing: opening.swing
                            ?? DoorSwingInference.swing(for: opening, on: wall, in: level),
                        formatter: formatter,
                        onUpdate: { updated in
                            commit { EditorEngine.updateOpening(in: $0, wallID: wallID, opening: updated) }
                        },
                        onStatus: { status in
                            commit { EditorEngine.setOpeningChangeStatus(in: $0, openingID: openingID, status: status) }
                        },
                        onDelete: {
                            commit { EditorEngine.deleteOpening(in: $0, openingID: openingID) }
                            selection = .none
                        })
                }
            case .fixture(let id):
                if let fixture = level.fixtures.first(where: { $0.id == id }) {
                    FixtureInspector(
                        fixture: fixture,
                        formatter: formatter,
                        onUpdate: { updated in
                            commit { EditorEngine.updateFixture(in: $0, updated) }
                        },
                        onStatus: { status in
                            commit { EditorEngine.setFixtureChangeStatus(in: $0, fixtureID: id, status: status) }
                        },
                        onDelete: {
                            commit { EditorEngine.deleteFixture(in: $0, fixtureID: id) }
                            selection = .none
                        })
                }
            case .room(let id):
                if let room = level.room(withID: id) {
                    RoomInspector(
                        room: room,
                        formatter: formatter,
                        isMergeArmed: mergeSourceRoomID == id,
                        onRename: { name, type in
                            commit { EditorEngine.renameRoom(in: $0, roomID: id, name: name, type: type) }
                        },
                        onCeiling: { height in
                            commit { EditorEngine.setCeilingHeight(in: $0, roomID: id, height: height, source: .manualEntry) }
                        },
                        onMergeArm: {
                            mergeSourceRoomID = mergeSourceRoomID == id ? nil : id
                        },
                        onDelete: {
                            commit { lvl in
                                var updated = lvl
                                updated.rooms.removeAll { $0.id == id }
                                return updated
                            }
                            selection = .none
                        })
                }
            case .annotation(let id):
                if let annotation = level.annotations.first(where: { $0.id == id }) {
                    HStack {
                        Text(annotation.kind == .note ? "Note: \(annotation.text)" : "Dimension")
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            commit { EditorEngine.deleteAnnotation(in: $0, annotationID: id) }
                            selection = .none
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete annotation")
                    }
                    .padding(10)
                    .background(.bar)
                }
            case .corner(_, _, let position):
                HStack {
                    Label("Corner — drag to move. Connected walls follow.", systemImage: "smallcircle.filled.circle")
                        .font(.footnote)
                    Spacer()
                    Text("(\(formatter.length(position.x)), \(formatter.length(position.y)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.bar)
            case .none:
                if tool != .select {
                    Text(toolHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.bar)
                }
            }
        }
    }

    private var toolHint: String {
        switch tool {
        case .select: return ""
        case .addWall: return pendingPoint == nil ? "Tap the wall start point." : "Tap the wall end point."
        case .addDoor: return "Tap a wall where the door goes."
        case .addWindow: return "Tap a wall where the window goes."
        case .addOpening: return "Tap a wall where the opening goes."
        case .addFixture: return "Tap where the fixture goes."
        case .addNote: return "Tap where the note points."
        case .addDimension: return pendingPoint == nil ? "Tap the first point." : "Tap the second point."
        case .splitRoom: return pendingPoint == nil ? "Tap one side of the cut line." : "Tap the other side of the cut."
        }
    }

    // MARK: - Selection overlay

    private func selectionOverlay(level: LevelGeometry) -> [PlanPrimitive] {
        var overlay: [PlanPrimitive] = []
        switch selection {
        case .wall(let id):
            if let wall = level.wall(withID: id) {
                overlay.append(.line(a: wall.start, b: wall.end, pen: .wallNew))
                overlay.append(.circle(center: wall.start, radius: 0.08, pen: .wallNew, filled: true))
                overlay.append(.circle(center: wall.end, radius: 0.08, pen: .wallNew, filled: true))
            }
        case .corner(_, _, let position):
            overlay.append(.circle(center: position, radius: 0.12, pen: .wallNew, filled: false))
        case .opening(let wallID, let openingID):
            if let wall = level.wall(withID: wallID),
               let opening = wall.openings.first(where: { $0.id == openingID }) {
                let a = wall.point(atOffset: opening.startOffset)
                let b = wall.point(atOffset: opening.endOffset)
                overlay.append(.line(a: a, b: b, pen: .wallNew))
            }
        case .fixture(let id):
            if let fixture = level.fixtures.first(where: { $0.id == id }) {
                overlay.append(.polyline(points: fixture.corners, closed: true, pen: .wallNew))
            }
        case .room(let id):
            if let room = level.room(withID: id), room.polygon.count >= 3 {
                overlay.append(.polyline(points: room.polygon, closed: true, pen: .wallNew))
            }
        case .annotation(let id):
            if let annotation = level.annotations.first(where: { $0.id == id }) {
                overlay.append(.circle(center: annotation.position, radius: 0.15, pen: .wallNew, filled: false))
            }
        case .none:
            break
        }
        if let pendingPoint {
            overlay.append(.circle(center: pendingPoint, radius: 0.1, pen: .wallNew, filled: true))
        }
        return overlay
    }

    // MARK: - Tap handling

    private func handleTap(_ point: Vec2, tolerance: Double) {
        guard let level else { return }
        switch tool {
        case .select:
            let hit = PlanHitTester.hit(point, level: level, tolerance: tolerance)
            if case .room(let targetID) = hit, let sourceID = mergeSourceRoomID, sourceID != targetID {
                if let merged = EditorEngine.mergeRooms(in: level, roomA: sourceID, roomB: targetID) {
                    commitAbsolute(merged)
                    mergeSourceRoomID = nil
                    selection = .none
                } else {
                    errorMessage = "These rooms don't share a wall, so they can't be merged."
                    mergeSourceRoomID = nil
                }
                return
            }
            selection = hit
        case .addWall:
            let snapped = snapPoint(point, level: level)
            if let start = pendingPoint {
                var end = snapped
                if orthoEnabled {
                    let direction = EditorEngine.orthoSnappedDirection((end - start).normalized)
                    end = start + direction * (end - start).length
                }
                let height = defaultWallHeight(level: level)
                let (updated, wall) = EditorEngine.addWall(to: level, from: start, to: end, height: height)
                commitAbsolute(updated)
                pendingPoint = nil
                selection = .wall(wall.id)
                tool = .select
            } else {
                pendingPoint = snapped
            }
        case .addDoor, .addWindow, .addOpening:
            let hit = PlanHitTester.hit(point, level: level, tolerance: tolerance * 2)
            var wallID: UUID? = nil
            if case .wall(let id) = hit { wallID = id }
            if case .opening(let id, _) = hit { wallID = id }
            guard let wallID, let wall = level.wall(withID: wallID) else {
                errorMessage = "Tap directly on a wall to place this."
                return
            }
            let along = (point - wall.start).dot(wall.direction)
            let kind: OpeningKind = tool == .addDoor ? .door : (tool == .addWindow ? .window : .opening)
            let ft = UnitConstants.metersPerFoot
            let (width, height, sill): (Double, Double, Double) = {
                switch kind {
                case .door: return (2.5 * ft, 2.0320, 0)
                case .window: return (3.0 * ft, 4.0 * ft, 2.5 * ft)
                case .opening: return (4.0 * ft, 2.0320, 0)
                }
            }()
            if let (updated, opening) = EditorEngine.addOpening(
                in: level, wallID: wallID, kind: kind,
                centerOffset: along, width: min(width, wall.length * 0.9),
                height: height, sillHeight: sill) {
                commitAbsolute(updated)
                selection = .opening(wallID: wallID, openingID: opening.id)
                tool = .select
            } else {
                errorMessage = "The \(kind.displayName.lowercased()) doesn't fit there — it would overlap another opening."
            }
        case .addFixture:
            fixturePlacement = PositionBox(position: point)
            tool = .select
        case .addNote:
            notePosition = point
            tool = .select
        case .addDimension:
            if let first = pendingPoint {
                let annotation = PlanAnnotation(
                    kind: .dimension, text: "",
                    position: first.midpoint(point),
                    pointA: snapPoint(first, level: level),
                    pointB: snapPoint(point, level: level))
                commit { EditorEngine.addAnnotation(to: $0, annotation) }
                pendingPoint = nil
                tool = .select
            } else {
                pendingPoint = snapPoint(point, level: level)
            }
        case .splitRoom:
            if let first = pendingPoint {
                guard case .room(let roomID) = PlanHitTester.hit(
                    first.midpoint(point), level: level, tolerance: tolerance) else {
                    errorMessage = "The cut line must pass through a room."
                    pendingPoint = nil
                    return
                }
                if let split = EditorEngine.splitRoom(in: level, roomID: roomID, cutA: first, cutB: point) {
                    commitAbsolute(split)
                } else {
                    errorMessage = "The cut must cross the room from one side to the other."
                }
                pendingPoint = nil
                tool = .select
            } else {
                pendingPoint = point
            }
        }
    }

    // MARK: - Drag handling (move corner / wall / fixture)

    private func handleDragStart(_ point: Vec2, tolerance: Double) -> Bool {
        guard tool == .select, let level else { return false }
        let hit = PlanHitTester.hit(point, level: level, tolerance: tolerance)
        switch hit {
        case .corner, .wall, .fixture:
            selection = hit
            dragOriginLevel = level
            dragStartPoint = point
            return true
        default:
            return false
        }
    }

    private func handleDragChanged(_ point: Vec2) {
        guard let origin = dragOriginLevel, let start = dragStartPoint else { return }
        switch selection {
        case .corner(_, _, let position):
            let target = snapEnabled ? snapPoint(position + (point - start), level: origin, excluding: position) : position + (point - start)
            level = EditorEngine.moveCornerFree(in: origin, from: position, to: target)
        case .wall(let id):
            level = EditorEngine.translateWall(in: origin, wallID: id, delta: point - start)
        case .fixture(let id):
            if let fixture = origin.fixtures.first(where: { $0.id == id }) {
                var moved = fixture
                moved.center = fixture.center + (point - start)
                level = EditorEngine.updateFixture(in: origin, moved)
            }
        default:
            break
        }
    }

    private func handleDragEnded(_ point: Vec2) {
        guard dragOriginLevel != nil else { return }
        dragOriginLevel = nil
        dragStartPoint = nil
        if let level {
            // Refresh the selected corner position after the move.
            if case .corner(let wallID, let isStart, _) = selection,
               let wall = level.wall(withID: wallID) {
                selection = .corner(wallID: wallID, isStart: isStart, position: isStart ? wall.start : wall.end)
            }
            pushHistory(level)
            persist()
        }
    }

    // MARK: - Snapping

    /// Snaps to nearby corners first, then the 1" grid.
    private func snapPoint(_ point: Vec2, level: LevelGeometry, excluding: Vec2? = nil) -> Vec2 {
        guard snapEnabled else { return point }
        if let corner = EditorEngine.nearestCorner(in: level, to: point, tolerance: 0.12),
           excluding.map({ corner.distance(to: $0) > 0.01 }) ?? true {
            return corner
        }
        let inch = UnitConstants.metersPerInch
        return Vec2((point.x / inch).rounded() * inch, (point.y / inch).rounded() * inch)
    }

    private func defaultWallHeight(level: LevelGeometry) -> Double {
        let heights = level.walls.map(\.height).sorted()
        return heights.isEmpty ? 2.4384 : heights[heights.count / 2]
    }

    // MARK: - History / persistence

    private func load() {
        do {
            let snapshot = try ProjectStore.shared.loadSnapshot(projectID: project.id, snapshotID: snapshotID)
            guard let found = snapshot.levels.first(where: { $0.id == levelID }) else {
                errorMessage = "Level not found in this plan version."
                return
            }
            level = found
            history = [found]
            historyIndex = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies a mutation, records history, persists.
    private func commit(_ mutate: (LevelGeometry) -> LevelGeometry) {
        guard let current = level else { return }
        let updated = mutate(current)
        commitAbsolute(updated)
    }

    private func commitAbsolute(_ updated: LevelGeometry) {
        level = updated
        pushHistory(updated)
        persist()
    }

    private func pushHistory(_ state: LevelGeometry) {
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(state)
        if history.count > 100 {
            history.removeFirst(history.count - 100)
        }
        historyIndex = history.count - 1
    }

    private func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        level = history[historyIndex]
        persist()
    }

    private func redo() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        level = history[historyIndex]
        persist()
    }

    private func persist() {
        guard let level else { return }
        do {
            let snapshot = try ProjectStore.shared.loadSnapshot(projectID: project.id, snapshotID: snapshotID)
            _ = try ProjectStore.shared.updateLevel(level, in: snapshot, projectID: project.id)
            project.updatedAt = Date()
            try? context.save()
        } catch {
            errorMessage = "Autosave failed: \(error.localizedDescription)"
            AppLog.store.error("Editor autosave failed: \(error.localizedDescription)")
        }
    }
}

// Helper for sheet(item:) with a plain position payload.
private struct PositionBox: Identifiable {
    let id = UUID()
    let position: Vec2
}

// MARK: - Inspectors

private struct WallInspector: View {
    let wall: Wall
    let formatter: UnitFormatter
    let onSetLength: (Double, LengthEditStrategy) -> Void
    let onSetHeight: (Double) -> Void
    let onSetThickness: (Double) -> Void
    let onStatus: (ChangeStatus) -> Void
    let onSplit: () -> Void
    let onDelete: () -> Void

    @State private var showLengthEditor = false
    @State private var newLength: Double? = nil
    @State private var strategy: LengthEditStrategy = .moveEnd
    @State private var newHeight: Double? = nil
    @State private var newThickness: Double? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        newLength = wall.length
                        showLengthEditor = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(formatter.length(wall.length))
                                .font(.title3.weight(.semibold).monospacedDigit())
                            Image(systemName: "pencil.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Edit wall length")
                    HStack(spacing: 8) {
                        Text("H \(formatter.length(wall.height))")
                        Text("T \(formatter.length(wall.thickness))")
                        if let original = wall.originalLength {
                            Text("was \(formatter.length(original))")
                                .foregroundStyle(.orange)
                        }
                        Text(wall.source.displayName)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Spacer()
                Picker("Status", selection: Binding(get: { wall.changeStatus }, set: { onStatus($0) })) {
                    Text("Existing").tag(ChangeStatus.existing)
                    Text("Demo").tag(ChangeStatus.demolish)
                    Text("New").tag(ChangeStatus.new)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
            }
            HStack {
                Button("Split", action: onSplit)
                    .buttonStyle(.bordered)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(.bar)
        .sheet(isPresented: $showLengthEditor) {
            NavigationStack {
                Form {
                    Section("Exact Length") {
                        DimensionField(label: "New length", meters: $newLength,
                                       formatter: formatter, placeholder: formatter.length(wall.length))
                        Picker("Strategy", selection: $strategy) {
                            ForEach(LengthEditStrategy.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    Section("Height & Thickness") {
                        DimensionField(label: "Wall height", meters: $newHeight,
                                       formatter: formatter, placeholder: formatter.length(wall.height))
                        DimensionField(label: "Wall thickness", meters: $newThickness,
                                       formatter: formatter, placeholder: formatter.length(wall.thickness))
                    }
                    Section {
                        Button("Apply") {
                            if let newLength, abs(newLength - wall.length) > 1e-9 {
                                onSetLength(newLength, strategy)
                            }
                            if let newHeight, abs(newHeight - wall.height) > 1e-9 {
                                onSetHeight(newHeight)
                            }
                            if let newThickness, abs(newThickness - wall.thickness) > 1e-9 {
                                onSetThickness(newThickness)
                            }
                            showLengthEditor = false
                        }
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                    }
                }
                .navigationTitle("Edit Wall")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showLengthEditor = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct OpeningInspector: View {
    let wall: Wall
    let opening: WallOpening
    /// The swing actually drawn: the hand-set one, or the one derived from the
    /// rooms around the door. Flipping starts from what is on the plan, so the
    /// first tap always moves the door the owner is looking at.
    let resolvedSwing: DoorSwing
    let formatter: UnitFormatter
    let onUpdate: (WallOpening) -> Void
    let onStatus: (ChangeStatus) -> Void
    let onDelete: () -> Void

    @State private var showEditor = false
    @State private var width: Double? = nil
    @State private var height: Double? = nil
    @State private var sill: Double? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        width = opening.width
                        height = opening.height
                        sill = opening.sillHeight
                        showEditor = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(opening.kind.displayName) \(formatter.length(opening.width)) × \(formatter.length(opening.height))")
                                .font(.headline.monospacedDigit())
                            Image(systemName: "pencil.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if opening.kind == .window {
                        Text("Sill \(formatter.length(opening.sillHeight))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker("Status", selection: Binding(get: { opening.changeStatus }, set: { onStatus($0) })) {
                    Text("Existing").tag(ChangeStatus.existing)
                    Text("Demo").tag(ChangeStatus.demolish)
                    Text("New").tag(ChangeStatus.new)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
            }
            HStack(spacing: 8) {
                // Nudge along the wall in 1" steps.
                Button {
                    nudge(-UnitConstants.metersPerInch)
                } label: {
                    Image(systemName: "arrow.left")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Nudge toward wall start")
                Button {
                    nudge(UnitConstants.metersPerInch)
                } label: {
                    Image(systemName: "arrow.right")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Nudge toward wall end")
                if opening.kind == .door {
                    Button {
                        var updated = opening
                        updated.swing = resolvedSwing.mirrored
                        onUpdate(updated)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Flip hinge side")
                    Button {
                        var updated = opening
                        updated.swing = resolvedSwing.reversed
                        onUpdate(updated)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Flip swing direction")
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Delete opening")
            }
        }
        .padding(10)
        .background(.bar)
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                Form {
                    DimensionField(label: "Width", meters: $width, formatter: formatter)
                    DimensionField(label: "Height", meters: $height, formatter: formatter)
                    if opening.kind == .window {
                        DimensionField(label: "Sill height", meters: $sill, formatter: formatter)
                    }
                    Button("Apply") {
                        var updated = opening
                        if let width { updated.width = width }
                        if let height { updated.height = height }
                        if let sill, opening.kind == .window { updated.sillHeight = sill }
                        updated.source = .edited
                        onUpdate(updated)
                        showEditor = false
                    }
                    .frame(maxWidth: .infinity)
                    .font(.headline)
                }
                .navigationTitle("Edit \(opening.kind.displayName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showEditor = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func nudge(_ delta: Double) {
        var updated = opening
        updated.centerOffset += delta
        onUpdate(updated)
    }
}

private struct FixtureInspector: View {
    let fixture: FixtureItem
    let formatter: UnitFormatter
    let onUpdate: (FixtureItem) -> Void
    let onStatus: (ChangeStatus) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fixture.displayName)
                        .font(.headline)
                    Text("\(formatter.length(fixture.size.x)) × \(formatter.length(fixture.size.y))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Status", selection: Binding(get: { fixture.changeStatus }, set: { onStatus($0) })) {
                    Text("Existing").tag(ChangeStatus.existing)
                    Text("Demo").tag(ChangeStatus.demolish)
                    Text("New").tag(ChangeStatus.new)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
            }
            HStack(spacing: 8) {
                Button {
                    var updated = fixture
                    updated.rotation += .pi / 12
                    onUpdate(updated)
                } label: {
                    Image(systemName: "rotate.left")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Rotate 15 degrees")
                Button {
                    var updated = fixture
                    updated.rotation -= .pi / 12
                    onUpdate(updated)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Rotate minus 15 degrees")
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Delete fixture")
            }
        }
        .padding(10)
        .background(.bar)
    }
}

private struct RoomInspector: View {
    let room: RoomShape
    let formatter: UnitFormatter
    let isMergeArmed: Bool
    let onRename: (String, RoomType) -> Void
    let onCeiling: (Double) -> Void
    let onMergeArm: () -> Void
    let onDelete: () -> Void

    @State private var showEditor = false
    @State private var name = ""
    @State private var type: RoomType = .other
    @State private var ceiling: Double? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        name = room.name
                        type = room.type
                        ceiling = room.ceilingHeight
                        showEditor = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(room.name).font(.headline)
                            Image(systemName: "pencil.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    Text("\(formatter.area(room.floorArea)) · CLG \(room.ceilingHeight.map { formatter.length($0) } ?? "—")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isMergeArmed ? "Tap other room…" : "Merge…", action: onMergeArm)
                    .buttonStyle(.bordered)
                    .tint(isMergeArmed ? .orange : nil)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Delete room")
            }
        }
        .padding(10)
        .background(.bar)
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                Form {
                    TextField("Room name", text: $name)
                    Picker("Type", selection: $type) {
                        ForEach(RoomType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    DimensionField(label: "Ceiling height", meters: $ceiling, formatter: formatter, placeholder: "8'")
                    Button("Apply") {
                        onRename(name, type)
                        if let ceiling { onCeiling(ceiling) }
                        showEditor = false
                    }
                    .frame(maxWidth: .infinity)
                    .font(.headline)
                }
                .navigationTitle("Edit Room")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showEditor = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

private struct FixturePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let position: Vec2
    let onAdd: (FixtureItem) -> Void

    /// (category, default width ft, default depth ft)
    static let choices: [(FixtureCategory, Double, Double)] = [
        (.cabinetBase, 3, 2), (.cabinetUpper, 3, 1), (.island, 6, 3),
        (.countertop, 6, 2.1), (.refrigerator, 3, 2.8), (.stove, 2.5, 2.2),
        (.dishwasher, 2, 2.1), (.sink, 2.5, 1.8), (.vanity, 3, 1.8),
        (.toilet, 1.6, 2.3), (.bathtub, 5, 2.5), (.shower, 3, 3),
        (.washerDryer, 2.3, 2.3), (.radiator, 3, 0.8), (.column, 1, 1),
        (.stairs, 3, 10), (.medicineCabinet, 2, 0.4), (.soffit, 4, 1),
        (.bed, 5, 6.6), (.sofa, 7, 3), (.table, 4, 3), (.chair, 1.6, 1.6),
        (.storage, 3, 2), (.custom, 2, 2),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(Self.choices.enumerated()), id: \.offset) { _, choice in
                    Button {
                        let ft = UnitConstants.metersPerFoot
                        let fixture = FixtureItem(
                            category: choice.0,
                            center: position,
                            size: Vec2(choice.1 * ft, choice.2 * ft),
                            source: .manualEntry,
                            confidence: .high)
                        onAdd(fixture)
                        dismiss()
                    } label: {
                        HStack {
                            Text(choice.0.displayName)
                            Spacer()
                            Text("\(Int(choice.1))' × \(String(format: "%.1f", choice.2))'")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Add Fixture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// QA findings list (spec §29).
struct QAFindingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let level: LevelGeometry

    var body: some View {
        let findings = QAEngine.evaluate(level: level)
        NavigationStack {
            List {
                Section {
                    let status = QAEngine.overallStatus(findings)
                    Label(status.displayName, systemImage: status == .pass
                        ? "checkmark.seal.fill"
                        : (status == .review ? "exclamationmark.triangle.fill" : "xmark.seal.fill"))
                        .foregroundStyle(AppTheme.severityColor(status))
                        .font(.headline)
                }
                if findings.isEmpty {
                    Text("No issues found. Geometry is closed and consistent.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(finding.code.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(finding.severity.displayName)
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(AppTheme.severityColor(finding.severity).opacity(0.18)))
                                    .foregroundStyle(AppTheme.severityColor(finding.severity))
                            }
                            Text(finding.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("QA — \(level.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
