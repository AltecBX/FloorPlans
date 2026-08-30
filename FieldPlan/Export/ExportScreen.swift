import SwiftUI
import SwiftData
import FieldPlanCore

/// Export hub (spec §36–§41): floor-plan PNG/SVG/PDF-style quick export,
/// DXF for CAD, CSV schedules, JSON archive, USDZ scans, and the portable
/// .fieldplan package — all through the native share sheet.
struct ExportScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @State private var snapshot: PlanSnapshot? = nil
    @State private var levelID: UUID? = nil
    @State private var mode: PlanRenderMode = .existing
    @State private var includeDimensions = true
    @State private var includeAreas = true
    @State private var includeFurniture = false
    @State private var includeFixtures = true
    @State private var shareItem: ShareFile? = nil
    @State private var errorMessage: String? = nil
    @State private var working = false

    private var currentLevel: LevelGeometry? {
        guard let snapshot else { return nil }
        return snapshot.levels.first { $0.id == (levelID ?? snapshot.levels.first?.id) }
    }

    var body: some View {
        Form {
            Section("Floor Plan Export") {
                if let snapshot, snapshot.levels.count > 1 {
                    Picker("Level", selection: Binding(
                        get: { levelID ?? snapshot.levels.first?.id },
                        set: { levelID = $0 })) {
                        ForEach(snapshot.levels.sorted(by: { $0.storyIndex < $1.storyIndex })) { level in
                            Text(level.name).tag(Optional(level.id))
                        }
                    }
                }
                Picker("Plan", selection: $mode) {
                    ForEach(PlanRenderMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Dimensions", isOn: $includeDimensions)
                Toggle("Room areas", isOn: $includeAreas)
                Toggle("Fixtures", isOn: $includeFixtures)
                Toggle("Furniture", isOn: $includeFurniture)

                exportButton("Floor Plan PNG", icon: "photo") { try exportPNG() }
                exportButton("3D Dollhouse PNG", icon: "cube.fill") { try export3DPNG() }
                exportButton("Floor Plan SVG (vector)", icon: "square.on.circle") { try exportSVG() }
                exportButton("DXF for CAD", icon: "square.grid.3x3.square") { try exportDXF() }
            }

            Section("Data Exports") {
                exportButton("Room Schedule CSV", icon: "tablecells") { try exportRoomCSV() }
                exportButton("Measurements CSV", icon: "ruler") { try exportMeasurementsCSV() }
                exportButton("Project JSON", icon: "curlybraces") { try exportJSON() }
            }

            Section("3D Scans (USDZ)") {
                let scans = project.scans.filter { $0.usdzFileName != nil }
                if scans.isEmpty {
                    Text("No USDZ scans yet — they are saved automatically when you scan rooms.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    ForEach(scans) { scan in
                        Button {
                            if let name = scan.usdzFileName {
                                shareItem = ShareFile(url: ProjectStore.shared.scansDir(project.id)
                                    .appendingPathComponent(name))
                            }
                        } label: {
                            Label("\(scan.roomName) — \(scan.capturedAt.formatted(date: .abbreviated, time: .shortened))",
                                  systemImage: "cube")
                        }
                    }
                }
            }

            Section("Complete Project") {
                exportButton(".fieldplan Package (backup / transfer)", icon: "shippingbox") {
                    try ProjectStore.shared.exportPackage(project)
                }
            } footer: {
                Text("The .fieldplan package contains the full project — geometry, all plan versions, measurements, photos and raw scans — and can be re-imported from the Projects screen.")
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(item: $shareItem) { file in
            ShareSheet(items: [file.url])
        }
        .alert("Export Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func exportButton(_ title: String, icon: String, action: @escaping () throws -> URL) -> some View {
        Button {
            guard !working else { return }
            working = true
            do {
                shareItem = ShareFile(url: try action())
            } catch {
                errorMessage = error.localizedDescription
                AppLog.export.error("Export failed: \(error.localizedDescription)")
            }
            working = false
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func load() {
        do {
            snapshot = try ProjectStore.shared.activeSnapshot(for: project, context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Exports

    private func planOptions() -> PlanGenerator.Options {
        var options = PlanGenerator.Options()
        options.mode = mode
        options.showDimensions = includeDimensions
        options.showAreaLabels = includeAreas
        options.showRoomLabels = true
        options.showFurniture = includeFurniture
        options.showFixtures = includeFixtures
        options.formatter = SettingsStore.shared.formatter
        return options
    }

    private func requireLevel() throws -> LevelGeometry {
        guard let level = currentLevel, !(level.walls.isEmpty && level.rooms.isEmpty) else {
            throw ProjectStore.StoreError.importUnreadable("No plan geometry to export yet — scan or draw rooms first.")
        }
        return level
    }

    private func fileURL(_ name: String) -> URL {
        ProjectStore.shared.exportsDir(project.id).appendingPathComponent(name)
    }

    private func exportPNG() throws -> URL {
        let level = try requireLevel()
        let scene = PlanGenerator.scene(for: level, options: planOptions())
        let image = PlanImageRenderer.image(for: scene)
        guard let data = image.pngData() else {
            throw ProjectStore.StoreError.importUnreadable("PNG encoding failed.")
        }
        let url = fileURL("\(level.name) \(mode.displayName).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func export3DPNG() throws -> URL {
        let level = try requireLevel()
        let renderMode: PlanRenderMode = mode == .demolition ? .existing : mode
        guard let image = ThreeDSnapshot.render(levels: [level], mode: renderMode, showFurniture: includeFurniture || includeFixtures),
              let data = image.pngData() else {
            throw ProjectStore.StoreError.importUnreadable("3D rendering is unavailable on this device.")
        }
        let url = fileURL("\(level.name) 3D.png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func exportSVG() throws -> URL {
        let level = try requireLevel()
        let scene = PlanGenerator.scene(for: level, options: planOptions())
        var svgOptions = SVGExporter.Options()
        svgOptions.title = "\(project.name) — \(level.name) (\(mode.displayName))"
        let svg = SVGExporter.svg(for: scene, options: svgOptions)
        let url = fileURL("\(level.name) \(mode.displayName).svg")
        try Data(svg.utf8).write(to: url, options: .atomic)
        return url
    }

    private func exportDXF() throws -> URL {
        let level = try requireLevel()
        let scene = PlanGenerator.scene(for: level, options: planOptions())
        let dxf = DXFExporter.dxf(for: scene)
        let url = fileURL("\(level.name) \(mode.displayName).dxf")
        try Data(dxf.utf8).write(to: url, options: .atomic)
        return url
    }

    private func exportRoomCSV() throws -> URL {
        guard let snapshot else { throw ProjectStore.StoreError.importUnreadable("No plan data.") }
        let csv = CSVExporter.roomSchedule(levels: snapshot.levels, formatter: SettingsStore.shared.formatter)
        let url = fileURL("rooms.csv")
        try Data(csv.utf8).write(to: url, options: .atomic)
        return url
    }

    private func exportMeasurementsCSV() throws -> URL {
        var roomNames: [UUID: String] = [:]
        for level in snapshot?.levels ?? [] {
            for room in level.rooms { roomNames[room.id] = room.name }
        }
        let csv = CSVExporter.measurementSchedule(
            project.measurements.map(\.model),
            roomNames: roomNames,
            formatter: SettingsStore.shared.formatter)
        let url = fileURL("measurements.csv")
        try Data(csv.utf8).write(to: url, options: .atomic)
        return url
    }

    private func exportJSON() throws -> URL {
        guard let snapshot else { throw ProjectStore.StoreError.importUnreadable("No plan data.") }
        var snapshots: [PlanSnapshot] = []
        for record in project.snapshots {
            if let s = try? ProjectStore.shared.loadSnapshot(projectID: project.id, snapshotID: record.id) {
                snapshots.append(s)
            }
        }
        if snapshots.isEmpty { snapshots = [snapshot] }
        let archive = ProjectArchive(
            appVersion: AppInfo.version,
            meta: project.meta,
            snapshots: snapshots,
            activeSnapshotID: project.activeSnapshotID,
            measurements: project.measurements.map(\.model),
            photos: project.photos.map(\.photoMeta),
            notes: project.noteRecords.map(\.noteMeta),
            takeoffItems: project.takeoffItems.compactMap(\.item))
        let url = fileURL("project.json")
        try archive.jsonData().write(to: url, options: .atomic)
        return url
    }
}
