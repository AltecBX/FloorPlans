import SwiftUI
import SwiftData
import FieldPlanCore

/// Project hub: every major workflow is one tap away (spec §44).
struct ProjectDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var project: ProjectRecord

    @State private var showEdit = false
    @State private var showJobsite = false
    @State private var summary: ProjectSummaryStats? = nil
    @State private var qaStatus: QASeverity = .pass
    @State private var loadError: String? = nil

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                // Primary action.
                NavigationLink {
                    ScanFlowView(project: project)
                } label: {
                    Label("Scan Property", systemImage: "camera.metering.matrix")
                }
                .buttonStyle(BigButtonStyle())
                .padding(.horizontal)

                LazyVGrid(columns: columns, spacing: 10) {
                    NavigationLink {
                        FloorPlanScreen(project: project)
                    } label: {
                        ActionTile(title: "Floor Plan", systemImage: "square.grid.3x3.topleft.filled",
                                   badge: qaStatus == .pass ? nil : "QA: \(qaStatus.displayName)",
                                   tint: qaStatus == .pass ? .accentColor : AppTheme.severityColor(qaStatus))
                    }
                    NavigationLink {
                        ThreeDViewerScreen(project: project)
                    } label: {
                        ActionTile(title: "3D View", systemImage: "cube.transparent")
                    }
                    NavigationLink {
                        MeasurementsScreen(project: project)
                    } label: {
                        ActionTile(title: "Measure", systemImage: "ruler",
                                   badge: "\(project.measurements.count)")
                    }
                    NavigationLink {
                        PhotosScreen(project: project)
                    } label: {
                        ActionTile(title: "Photos", systemImage: "photo.on.rectangle",
                                   badge: "\(project.photos.count)")
                    }
                    NavigationLink {
                        NotesScreen(project: project)
                    } label: {
                        ActionTile(title: "Notes", systemImage: "note.text",
                                   badge: "\(project.noteRecords.count)")
                    }
                    NavigationLink {
                        PlanVersionsScreen(project: project)
                    } label: {
                        ActionTile(title: "Plan Versions", systemImage: "square.stack.3d.up",
                                   badge: "\(project.snapshots.count)")
                    }
                    NavigationLink {
                        TakeoffScreen(project: project)
                    } label: {
                        ActionTile(title: "Takeoff", systemImage: "sum",
                                   badge: "\(project.takeoffItems.count)")
                    }
                    NavigationLink {
                        ReportScreen(project: project)
                    } label: {
                        ActionTile(title: "Report", systemImage: "doc.richtext")
                    }
                    NavigationLink {
                        ExportScreen(project: project)
                    } label: {
                        ActionTile(title: "Export", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink {
                        AccuracyScreen(project: project)
                    } label: {
                        ActionTile(title: "Accuracy", systemImage: "checkmark.seal")
                    }
                    NavigationLink {
                        LevelsManagerView(project: project)
                    } label: {
                        ActionTile(title: "Levels", systemImage: "square.3.layers.3d")
                    }
                    NavigationLink {
                        ValidationScreen(project: project)
                    } label: {
                        ActionTile(title: "Validation", systemImage: "scope",
                                   badge: SettingsStore.shared.fieldValidationMode ? "ON" : nil,
                                   tint: SettingsStore.shared.fieldValidationMode ? .orange : .accentColor)
                    }
                    Button {
                        showJobsite = true
                    } label: {
                        ActionTile(title: "Jobsite Mode", systemImage: "hammer.fill", tint: .orange)
                    }
                }
                .padding(.horizontal)

                summarySection
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            ProjectFormView(existing: project)
        }
        .fullScreenCover(isPresented: $showJobsite) {
            JobsiteView(project: project)
        }
        .alert("Error", isPresented: .constant(loadError != nil)) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .onAppear {
            project.lastOpenedAt = Date()
            try? context.save()
            refreshSummary()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if !project.address.isEmpty {
                        Text(project.address + (project.unit.isEmpty ? "" : ", \(project.unit)"))
                            .font(.subheadline)
                    }
                    if !project.clientName.isEmpty {
                        Text(project.clientName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    ForEach(ProjectStatus.allCases, id: \.self) { status in
                        Button(status.displayName) {
                            project.status = status
                            project.updatedAt = Date()
                            try? context.save()
                        }
                    }
                } label: {
                    Text(project.status.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(AppTheme.statusColor(project.status).opacity(0.18)))
                        .foregroundStyle(AppTheme.statusColor(project.status))
                }
                .accessibilityLabel("Project status")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var summarySection: some View {
        if let summary {
            let formatter = SettingsStore.shared.formatter
            VStack(alignment: .leading, spacing: 8) {
                Text("Project Summary")
                    .font(.headline)
                StatRow(label: "Levels", value: "\(summary.totalLevels)")
                StatRow(label: "Rooms", value: "\(summary.totalRooms)")
                StatRow(label: "Floor Area", value: formatter.area(summary.totalFloorArea))
                StatRow(label: "Net Wall Area", value: formatter.area(summary.totalNetWallArea))
                StatRow(label: "Ceiling Area", value: formatter.area(summary.totalCeilingArea))
                StatRow(label: "Baseboard", value: formatter.linearFeet(summary.totalBaseboardLength))
                StatRow(label: "Doors / Windows", value: "\(summary.totalDoors) / \(summary.totalWindows)")
                StatRow(label: "Photos", value: "\(project.photos.count)")
                StatRow(label: "Measurements", value: "\(project.measurements.count)")
                let unverifiedCritical = project.measurements.filter {
                    $0.isCritical && $0.verificationRaw == VerificationStatus.unverified.rawValue
                }.count
                if unverifiedCritical > 0 {
                    StatRow(label: "⚠ Unverified Critical", value: "\(unverifiedCritical)")
                        .foregroundStyle(.orange)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: AppTheme.corner)
                .fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal)
        }
    }

    private func refreshSummary() {
        do {
            let snapshot = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            summary = ProjectSummaryStats.compute(levels: snapshot.levels)
            let findings = QAEngine.evaluate(snapshot: snapshot)
            qaStatus = QAEngine.overallStatus(findings)
        } catch {
            loadError = error.localizedDescription
            AppLog.store.error("Summary failed: \(error.localizedDescription)")
        }
    }
}

/// Level management (spec §7): add, rename, reorder, delete levels of the
/// active snapshot.
struct LevelsManagerView: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @State private var snapshot: PlanSnapshot? = nil
    @State private var newLevelName = ""
    @State private var errorMessage: String? = nil
    @State private var notice: String? = nil

    static let suggestedNames = [
        "Basement", "Cellar", "First Floor", "Second Floor", "Third Floor",
        "Penthouse", "Garage", "Exterior",
    ]

    var body: some View {
        List {
            if let snapshot {
                Section("Levels — \(snapshot.name)") {
                    ForEach(snapshot.levels.sorted(by: { $0.storyIndex < $1.storyIndex })) { level in
                        NavigationLink {
                            RoomListView(project: project, snapshotID: snapshot.id, levelID: level.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(level.name).font(.headline)
                                Text("\(level.rooms.count) rooms · \(level.walls.count) walls")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let height = relativeFloorHeight(of: level, in: snapshot) {
                                    Text(height)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            if snapshot.levels.count > 1 {
                                Button(role: .destructive) {
                                    deleteLevel(level)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if levelBelow(level, in: snapshot) != nil {
                                Button {
                                    alignToLevelBelow(level)
                                } label: {
                                    Label("Align Below", systemImage: "square.stack.3d.up")
                                }
                                .tint(.blue)
                            }
                        }
                        .contextMenu {
                            if let below = levelBelow(level, in: snapshot) {
                                Button {
                                    alignToLevelBelow(level)
                                } label: {
                                    Label("Align Over \(below.name)", systemImage: "square.stack.3d.up")
                                }
                            }
                        }
                    }
                }
                Section("Add Level") {
                    Picker("Name", selection: $newLevelName) {
                        Text("Choose…").tag("")
                        ForEach(Self.suggestedNames, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Custom name", text: $newLevelName)
                    Button {
                        addLevel()
                    } label: {
                        Label("Add Level", systemImage: "plus")
                    }
                    .disabled(newLevelName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("Levels")
        .onAppear(perform: load)
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Levels Aligned", isPresented: .constant(notice != nil)) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private func load() {
        do {
            snapshot = try ProjectStore.shared.activeSnapshot(for: project, context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Floor 9' 10" above the lowest scanned floor" — only meaningful once
    /// two levels carry scanned floor heights.
    private func relativeFloorHeight(of level: LevelGeometry, in snapshot: PlanSnapshot) -> String? {
        let measured = snapshot.levels.compactMap(\.elevation)
        guard measured.count > 1, let elevation = level.elevation, let lowest = measured.min() else { return nil }
        let formatter = SettingsStore.shared.formatter
        if elevation - lowest < 0.05 { return "Lowest scanned floor" }
        return "Floor \(formatter.length(elevation - lowest)) above the lowest scanned floor"
    }

    /// The nearest level under this one by story index.
    private func levelBelow(_ level: LevelGeometry, in snapshot: PlanSnapshot) -> LevelGeometry? {
        snapshot.levels
            .filter { $0.storyIndex < level.storyIndex }
            .max { $0.storyIndex < $1.storyIndex }
    }

    /// Slides a level over the one below it: staircase over staircase when
    /// both have one, footprint centre over footprint centre otherwise.
    private func alignToLevelBelow(_ level: LevelGeometry) {
        guard var current = snapshot, let below = levelBelow(level, in: current) else { return }
        let byStairs = LevelRegistration.alignByStairs(level, to: below)
        let aligned = byStairs ?? LevelRegistration.alignByFootprint(level, to: below)
        guard let aligned, let index = current.levels.firstIndex(where: { $0.id == level.id }) else {
            errorMessage = "Neither \(level.name) nor \(below.name) has geometry to align on yet."
            return
        }
        current.levels[index] = aligned.level
        persist(current)
        let formatter = SettingsStore.shared.formatter
        let how = byStairs != nil ? "its staircase over the one on" : "its footprint centred over"
        notice = "\(level.name) moved \(formatter.length(aligned.shift.length)) to put \(how) \(below.name). Undo by moving it back in the editor if the floors do not share a stair."
    }

    private func addLevel() {
        guard var current = snapshot else { return }
        let name = newLevelName.trimmingCharacters(in: .whitespaces)
        let nextIndex = (current.levels.map(\.storyIndex).max() ?? -1) + 1
        current.levels.append(LevelGeometry(name: name, storyIndex: name == "Basement" || name == "Cellar" ? -1 : nextIndex))
        persist(current)
        newLevelName = ""
    }

    private func deleteLevel(_ level: LevelGeometry) {
        guard var current = snapshot else { return }
        current.levels.removeAll { $0.id == level.id }
        persist(current)
    }

    private func persist(_ updated: PlanSnapshot) {
        do {
            try ProjectStore.shared.saveSnapshot(updated, projectID: project.id)
            snapshot = updated
            project.updatedAt = Date()
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Rooms on a level with per-room calculations (spec §26, §34).
struct RoomListView: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord
    let snapshotID: UUID
    let levelID: UUID

    @State private var level: LevelGeometry? = nil

    var body: some View {
        List {
            if let level {
                if level.rooms.isEmpty {
                    ContentUnavailableView("No Rooms", systemImage: "square.dashed",
                                           description: Text("Scan or draw rooms to see them here."))
                }
                ForEach(level.rooms) { room in
                    NavigationLink {
                        RoomDetailView(project: project, snapshotID: snapshotID,
                                       levelID: levelID, roomID: room.id)
                    } label: {
                        let formatter = SettingsStore.shared.formatter
                        VStack(alignment: .leading, spacing: 2) {
                            Text(room.name).font(.headline)
                            Text("\(room.type.displayName) · \(formatter.area(room.floorArea))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(level?.name ?? "Level")
        .onAppear {
            level = try? ProjectStore.shared
                .loadSnapshot(projectID: project.id, snapshotID: snapshotID)
                .levels.first { $0.id == levelID }
        }
    }
}
