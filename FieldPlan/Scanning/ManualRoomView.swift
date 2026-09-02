import SwiftUI
import SwiftData
import FieldPlanCore

/// Manual field measurement room entry (spec §3 Mode B). Builds real
/// canonical geometry from tape/laser dimensions — rectangular or L-shaped —
/// and merges it into the selected level exactly like a scan would.
struct ManualRoomView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord

    enum Shape: String, CaseIterable {
        case rectangle = "Rectangle"
        case lShape = "L-Shape"
    }

    @State private var snapshot: PlanSnapshot? = nil
    @State private var levelID: UUID? = nil
    @State private var roomName = ""
    @State private var roomType: RoomType = .bedroom
    @State private var shape: Shape = .rectangle

    // All dimensions in meters (parsed by DimensionField).
    @State private var width: Double? = nil
    @State private var depth: Double? = nil
    @State private var ceiling: Double? = DimensionParser.parseLength("8'")
    // L-shape notch, removed from the max-X / max-Y corner.
    @State private var notchWidth: Double? = nil
    @State private var notchDepth: Double? = nil

    @State private var errorMessage: String? = nil

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    private var isValid: Bool {
        guard let width, let depth, width > 0.3, depth > 0.3 else { return false }
        if shape == .lShape {
            guard let notchWidth, let notchDepth,
                  notchWidth > 0.05, notchDepth > 0.05,
                  notchWidth < width - 0.05, notchDepth < depth - 0.05 else { return false }
        }
        return true
    }

    var body: some View {
        Form {
            Section("Room") {
                TextField("Room name", text: $roomName)
                Picker("Type", selection: $roomType) {
                    ForEach(RoomType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if let snapshot {
                    Picker("Level", selection: $levelID) {
                        ForEach(snapshot.levels.sorted(by: { $0.storyIndex < $1.storyIndex })) { level in
                            Text(level.name).tag(Optional(level.id))
                        }
                    }
                }
                Picker("Shape", selection: $shape) {
                    ForEach(Shape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Dimensions") {
                DimensionField(label: "Width", meters: $width, formatter: formatter, placeholder: "12' 6\"")
                DimensionField(label: "Depth", meters: $depth, formatter: formatter, placeholder: "15'")
                DimensionField(label: "Ceiling height", meters: $ceiling, formatter: formatter, placeholder: "8'")
                if shape == .lShape {
                    DimensionField(label: "Notch width (cut from far corner)", meters: $notchWidth,
                                   formatter: formatter, placeholder: "5'")
                    DimensionField(label: "Notch depth", meters: $notchDepth,
                                   formatter: formatter, placeholder: "6'")
                }
            }

            if let width, let depth {
                Section("Preview") {
                    let area: Double = {
                        var a = width * depth
                        if shape == .lShape, let nw = notchWidth, let nd = notchDepth {
                            a -= nw * nd
                        }
                        return a
                    }()
                    StatRow(label: "Floor area", value: formatter.area(area))
                    StatRow(label: "Perimeter", value: formatter.linearFeet(
                        shape == .rectangle
                            ? 2 * (width + depth)
                            : 2 * (width + depth) // L-shape same perimeter as bounding rect
                    ))
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    Label("Add Room to Plan", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .font(.headline)
                .disabled(!isValid)
            } footer: {
                Text("The room is placed beside existing rooms on the plan; drag it into position in the plan editor. Doors and windows are added by tapping walls in the editor.")
            }
        }
        .navigationTitle("Manual Room")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() {
        do {
            let s = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            snapshot = s
            if levelID == nil { levelID = s.levels.first?.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let snapshot, let levelID = levelID ?? snapshot.levels.first?.id,
              let width, let depth, let ceilingHeight = ceiling else { return }
        do {
            let current = try ProjectStore.shared.loadSnapshot(projectID: project.id, snapshotID: snapshot.id)
            guard var level = current.levels.first(where: { $0.id == levelID }) else {
                errorMessage = "Selected level no longer exists."
                return
            }

            // Place beside existing geometry with a 1 m gap.
            let bounds = level.bounds
            let origin = bounds.isNull ? Vec2(0, 0) : Vec2(bounds.maxX + 1.0, bounds.minY)

            // Build the boundary polygon (CCW).
            var polygon: [Vec2]
            switch shape {
            case .rectangle:
                polygon = [
                    origin,
                    origin + Vec2(width, 0),
                    origin + Vec2(width, depth),
                    origin + Vec2(0, depth),
                ]
            case .lShape:
                let nw = notchWidth ?? 0
                let nd = notchDepth ?? 0
                polygon = [
                    origin,
                    origin + Vec2(width, 0),
                    origin + Vec2(width, depth - nd),
                    origin + Vec2(width - nw, depth - nd),
                    origin + Vec2(width - nw, depth),
                    origin + Vec2(0, depth),
                ]
            }

            // One wall per polygon edge. The typed dimensions are the clear
            // (face-to-face) room, so the wall centerlines sit half a wall
            // outside it, with the thickness marked as assumed.
            let thickness = 0.1143   // 4 1/2" partition, the model's default
            let centerlines = GeometryOps.insetPolygon(polygon, by: -thickness / 2)
            var walls: [Wall] = []
            for i in 0..<polygon.count {
                let a = centerlines?[i] ?? polygon[i]
                let b = centerlines?[(i + 1) % polygon.count] ?? polygon[(i + 1) % polygon.count]
                walls.append(Wall(
                    start: a, end: b,
                    height: ceilingHeight,
                    thickness: thickness,
                    source: .manualEntry,
                    confidence: .high,
                    thicknessSource: centerlines == nil ? nil : .assumed))
            }

            let name = roomName.trimmingCharacters(in: .whitespaces)
            let room = RoomShape(
                name: name.isEmpty ? roomType.displayName : name,
                type: roomType,
                polygon: polygon,
                ceilingHeight: ceilingHeight,
                ceilingHeightSource: .manualEntry,
                wallIDs: walls.map(\.id))

            level.walls.append(contentsOf: walls)
            level.rooms.append(room)
            _ = try ProjectStore.shared.updateLevel(level, in: current, projectID: project.id)
            project.updatedAt = Date()
            if project.status == .lead { project.status = .measured }
            try context.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            AppLog.store.error("Manual room save failed: \(error.localizedDescription)")
        }
    }
}
