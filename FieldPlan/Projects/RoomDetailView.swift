import SwiftUI
import SwiftData
import FieldPlanCore

/// Per-room hub: calculations, photos, notes, measurements (spec §26).
struct RoomDetailView: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord
    let snapshotID: UUID
    let levelID: UUID
    let roomID: UUID

    @State private var level: LevelGeometry? = nil
    @State private var room: RoomShape? = nil

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    var body: some View {
        List {
            if let room, let level {
                let calc = RoomCalculations.compute(room: room, in: level)

                Section("Plan") {
                    let scene: PlanScene = {
                        var options = PlanGenerator.Options()
                        options.formatter = formatter
                        options.showScaleBar = false
                        var roomLevel = level
                        roomLevel.rooms = [room]
                        roomLevel.walls = level.walls(for: room)
                        roomLevel.fixtures = level.fixtures.filter { $0.roomID == room.id }
                        roomLevel.annotations = []
                        return PlanGenerator.scene(for: roomLevel, options: options)
                    }()
                    PlanCanvasView(scene: scene)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                }

                Section("Calculations") {
                    StatRow(label: "Floor Area", value: formatter.area(calc.floorArea))
                    StatRow(label: "Ceiling Area", value: formatter.area(calc.ceilingArea))
                    StatRow(label: "Perimeter", value: formatter.linearFeet(calc.perimeter))
                    StatRow(label: "Ceiling Height",
                            value: calc.ceilingHeight.map { formatter.length($0) } ?? "Not set")
                    StatRow(label: "Gross Wall Area", value: formatter.area(calc.grossWallArea))
                    StatRow(label: "Window Area", value: formatter.area(calc.windowArea))
                    StatRow(label: "Door/Opening Area", value: formatter.area(calc.doorAndOpeningArea))
                    StatRow(label: "Net Wall Area", value: formatter.area(calc.netWallArea))
                    StatRow(label: "Base Molding", value: formatter.linearFeet(calc.baseMoldingLength))
                    StatRow(label: "Crown Molding", value: formatter.linearFeet(calc.crownMoldingLength))
                    StatRow(label: "Doors / Windows", value: "\(calc.doorCount) / \(calc.windowCount)")
                    let quantities = ContractorQuantities.compute(room: room, in: level)
                    StatRow(label: "Paintable Walls", value: formatter.area(quantities.paintableWallArea))
                    StatRow(label: "Wall Tile to 7'", value: formatter.area(quantities.wallTileArea))
                    StatRow(label: "Wainscot to 4'", value: formatter.area(quantities.wainscotArea))
                    StatRow(label: "Volume", value: formatter.volume(quantities.volume))
                    if quantities.fixtureTotal > 0 {
                        StatRow(label: "Fixtures", value: quantities.fixtureSummary)
                    }
                    if let evidence = room.evidence {
                        StatRow(label: "Confidence (evidence)", value: evidence.percentText)
                        if let coverage = evidence.coverage {
                            StatRow(label: "Floor observed", value: String(format: "%.0f%%", coverage * 100))
                        }
                    }
                }

                Section {
                    ForEach(Array(level.walls(for: room).enumerated()), id: \.element.id) { index, wall in
                        HStack {
                            Text("Wall \(index + 1)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatter.length(wall.length))
                                .monospacedDigit()
                            if let evidence = wall.evidence {
                                Text(evidence.percentText)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(confidenceColor(evidence.band).opacity(0.18)))
                                    .foregroundStyle(confidenceColor(evidence.band))
                            }
                            Text(wall.source.displayName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                    }
                } header: {
                    Text("Wall Lengths")
                } footer: {
                    Text("The percentage is an evidence score — scanner confidence, mesh coverage and tracking — not a measured accuracy. Verify against a tape in Accuracy → Test From Plan.")
                }

                Section("Documentation") {
                    NavigationLink {
                        PhotosScreen(project: project, roomFilter: room.id, roomName: room.name)
                    } label: {
                        Label("Photos (\(project.photos.filter { $0.roomID == room.id }.count))",
                              systemImage: "photo.on.rectangle")
                    }
                    NavigationLink {
                        NotesScreen(project: project, roomFilter: room.id, roomName: room.name)
                    } label: {
                        Label("Notes (\(project.noteRecords.filter { $0.roomID == room.id }.count))",
                              systemImage: "note.text")
                    }
                    NavigationLink {
                        MeasurementsScreen(project: project, roomFilter: room.id, roomName: room.name)
                    } label: {
                        Label("Measurements (\(project.measurements.filter { $0.roomID == room.id }.count))",
                              systemImage: "ruler")
                    }
                }
            } else {
                ContentUnavailableView("Room Not Found", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(room?.name ?? "Room")
        .onAppear(perform: load)
    }

    private func confidenceColor(_ band: ConfidenceBand) -> Color {
        switch band {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    private func load() {
        do {
            let snapshot = try ProjectStore.shared.loadSnapshot(projectID: project.id, snapshotID: snapshotID)
            level = snapshot.levels.first { $0.id == levelID }
            room = level?.rooms.first { $0.id == roomID }
        } catch {
            AppLog.store.error("Room load failed: \(error.localizedDescription)")
        }
    }
}
