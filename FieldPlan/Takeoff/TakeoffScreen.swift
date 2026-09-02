import SwiftUI
import SwiftData
import FieldPlanCore

/// Quantity takeoff (spec §27, §28): scoped surface selection per room,
/// explicit waste factors, manual overrides, CSV export. Not a pricing engine.
struct TakeoffScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @State private var levels: [LevelGeometry] = []
    @State private var editingItem: TakeoffItemRecord? = nil
    @State private var showAddPicker = false
    @State private var csvShare: ShareFile? = nil
    @State private var errorMessage: String? = nil

    private var items: [TakeoffItemRecord] {
        project.takeoffItems.sorted { $0.createdAt < $1.createdAt }
    }

    private var computedLines: [TakeoffLine] {
        let models = items.compactMap(\.item)
        return TakeoffCalculator.lines(for: models, levels: levels)
    }

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    var body: some View {
        List {
            // What the whole job measures before any scoping or waste: the
            // numbers a bid starts from, read from the painted faces.
            let summary = ContractorSummary.compute(levels: levels)
            if !summary.rooms.isEmpty {
                Section {
                    StatRow(label: "Floor area", value: formatter.area(summary.floorArea))
                    StatRow(label: "Paintable walls (net)", value: formatter.area(summary.paintableWallArea))
                    StatRow(label: "Ceilings", value: formatter.area(summary.ceilingArea))
                    StatRow(label: "Wet-wall tile to 7'", value: formatter.area(summary.wetWallTileArea))
                    StatRow(label: "Baseboard", value: formatter.linearFeet(summary.baseboardLength))
                    StatRow(label: "Crown", value: formatter.linearFeet(summary.crownLength))
                    StatRow(label: "Volume", value: formatter.volume(summary.volume))
                    StatRow(label: "Doors / Windows", value: "\(summary.doorCount) / \(summary.windowCount)")
                    if !summary.fixtureSummary.isEmpty {
                        StatRow(label: "Fixtures", value: summary.fixtureSummary)
                    }
                    Button {
                        exportQuantitiesCSV()
                    } label: {
                        Label("Export Quantities CSV (per room)", systemImage: "tablecells")
                    }
                } header: {
                    Text("Job Quantities")
                } footer: {
                    Text("Read from the painted faces of every room, net of doors and windows, no waste. Add items below to scope surfaces and apply waste.")
                }
            }

            if items.isEmpty {
                ContentUnavailableView(
                    "No Takeoff Items",
                    systemImage: "sum",
                    description: Text("Add categories like flooring, paint or tile, then select exactly which floors, ceilings and walls are in scope."))
            }

            Section {
                ForEach(items) { record in
                    Button {
                        editingItem = record
                    } label: {
                        TakeoffLineRow(
                            line: computedLines.first { $0.itemID == record.id },
                            record: record)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) {
                            context.delete(record)
                            try? context.save()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                if !items.isEmpty { Text("Quantities") }
            } footer: {
                if !items.isEmpty {
                    Text("Waste factors are shown on every line — nothing is assumed silently. Quantities update automatically when the plan changes.")
                }
            }
        }
        .navigationTitle("Takeoff")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !items.isEmpty {
                    Button {
                        exportCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export takeoff CSV")
                }
                Button {
                    showAddPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add takeoff item")
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showAddPicker) {
            NavigationStack {
                List(TakeoffCategory.allCases, id: \.self) { category in
                    Button {
                        addItem(category: category)
                        showAddPicker = false
                    } label: {
                        Text(category.displayName)
                    }
                }
                .navigationTitle("Add Category")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showAddPicker = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingItem) { record in
            TakeoffItemEditor(record: record, levels: levels) {
                try? context.save()
            }
        }
        .sheet(item: $csvShare) { file in
            ShareSheet(items: [file.url])
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() {
        do {
            let snapshot = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            levels = snapshot.levels
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addItem(category: TakeoffCategory) {
        var item = TakeoffItem(category: category, wastePercent: SettingsStore.shared.defaultWastePercent)
        // Pre-create empty selections for every room so scoping is one tap away.
        item.selections = levels.flatMap { level in
            level.rooms.map { SurfaceSelection(roomID: $0.id) }
        }
        let record = TakeoffItemRecord(item: item)
        record.project = project
        context.insert(record)
        try? context.save()
        editingItem = record
    }

    private func exportQuantitiesCSV() {
        let csv = CSVExporter.contractorQuantities(levels: levels, formatter: formatter)
        let url = ProjectStore.shared.exportsDir(project.id).appendingPathComponent("quantities.csv")
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            csvShare = ShareFile(url: url)
        } catch {
            errorMessage = "CSV export failed: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        let csv = CSVExporter.takeoffSchedule(computedLines)
        let url = ProjectStore.shared.exportsDir(project.id).appendingPathComponent("takeoff.csv")
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            csvShare = ShareFile(url: url)
        } catch {
            errorMessage = "CSV export failed: \(error.localizedDescription)"
        }
    }
}

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIKit share sheet wrapper (spec §41).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct TakeoffLineRow: View {
    let line: TakeoffLine?
    let record: TakeoffItemRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.headline)
                if let line {
                    let rooms = line.roomNames.isEmpty ? "No surfaces selected" : line.roomNames.joined(separator: ", ")
                    Text(rooms)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let line {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(line.totalQuantity, specifier: "%.1f") \(line.unit.displayName)")
                        .font(.body.weight(.semibold).monospacedDigit())
                    Text("\(line.baseQuantity, specifier: "%.1f") + \(line.wastePercent, specifier: "%.0f")% waste")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Item editor: waste factor, manual override, per-room surface selection.
struct TakeoffItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    let record: TakeoffItemRecord
    let levels: [LevelGeometry]
    let onSave: () -> Void

    @State private var item: TakeoffItem = TakeoffItem(category: .other)
    @State private var customWasteText = ""
    @State private var manualQuantityText = ""
    @State private var manualLinear: Double? = nil

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    private var roomsByID: [UUID: (RoomShape, LevelGeometry)] {
        var map: [UUID: (RoomShape, LevelGeometry)] = [:]
        for level in levels {
            for room in level.rooms { map[room.id] = (room, level) }
        }
        return map
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Name", text: $item.name)
                    LabeledContent("Category", value: item.category.displayName)
                    Toggle("Exclude from takeoff", isOn: $item.isExcluded)
                }

                Section("Waste Factor") {
                    Picker("Waste", selection: $item.wastePercent) {
                        ForEach(WasteFactor.standardChoices, id: \.self) { pct in
                            Text("\(Int(pct))%").tag(pct)
                        }
                        if !WasteFactor.standardChoices.contains(item.wastePercent) {
                            Text("\(item.wastePercent, specifier: "%.0f")% (custom)").tag(item.wastePercent)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("Custom %", text: $customWasteText)
                            .keyboardType(.decimalPad)
                        Button("Set") {
                            if let value = Double(customWasteText), value >= 0, value <= 100 {
                                item.wastePercent = value
                            }
                            customWasteText = ""
                        }
                        .disabled(Double(customWasteText) == nil)
                    }
                }

                if item.category.measures == .linearLength {
                    Section("Linear Length (measured)") {
                        DimensionField(label: "Run length", meters: $manualLinear, formatter: formatter, placeholder: "10'")
                    }
                } else {
                    Section("Surfaces in Scope") {
                        ForEach($item.selections) { $selection in
                            if let (room, level) = roomsByID[selection.roomID] {
                                SurfaceSelectionRow(selection: $selection, room: room, level: level, formatter: formatter)
                            }
                        }
                    }
                }

                Section("Manual Override") {
                    HStack {
                        TextField("Override quantity", text: $manualQuantityText)
                            .keyboardType(.decimalPad)
                        Text(unitLabel)
                            .foregroundStyle(.secondary)
                    }
                    if item.manualQuantity != nil {
                        Button("Clear Override — Use Computed Quantity") {
                            item.manualQuantity = nil
                            manualQuantityText = ""
                        }
                    }
                }

                Section("Result") {
                    let line = TakeoffCalculator.line(for: currentItem(), levels: levels)
                    StatRow(label: "Base quantity",
                            value: String(format: "%.1f %@", line.baseQuantity, line.unit.displayName))
                    StatRow(label: "Waste", value: String(format: "%.0f%%", line.wastePercent))
                    StatRow(label: "Total",
                            value: String(format: "%.1f %@", line.totalQuantity, line.unit.displayName))
                }

                Section("Notes") {
                    TextField("Notes", text: $item.notes, axis: .vertical)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        record.apply(currentItem())
                        onSave()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let stored = record.item {
                    item = stored
                    manualLinear = stored.manualLinearMeters
                    if let manual = stored.manualQuantity {
                        manualQuantityText = String(format: "%.1f", manual)
                    }
                }
            }
        }
    }

    private var unitLabel: String {
        switch item.category.measures {
        case .baseboardLength, .perimeterLength, .linearLength: return "LF"
        case .doorCount, .windowCount, .custom: return "ea"
        default: return "sq ft"
        }
    }

    private func currentItem() -> TakeoffItem {
        var current = item
        current.manualLinearMeters = manualLinear
        current.manualQuantity = Double(manualQuantityText)
        return current
    }
}

/// Per-room scope controls: floor / ceiling / all walls / individual walls.
private struct SurfaceSelectionRow: View {
    @Binding var selection: SurfaceSelection
    let room: RoomShape
    let level: LevelGeometry
    let formatter: UnitFormatter

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Toggle("Floor (\(formatter.area(room.floorArea)))", isOn: $selection.includeFloor)
            Toggle("Ceiling", isOn: $selection.includeCeiling)
            Toggle("All Walls", isOn: $selection.includeAllWalls)
            if !selection.includeAllWalls {
                let walls = level.walls(for: room)
                ForEach(Array(walls.enumerated()), id: \.element.id) { index, wall in
                    Toggle(
                        "Wall \(index + 1) — \(formatter.length(wall.length)) (\(formatter.area(wall.netArea)))",
                        isOn: Binding(
                            get: { selection.wallIDs.contains(wall.id) },
                            set: { include in
                                if include {
                                    selection.wallIDs.insert(wall.id)
                                } else {
                                    selection.wallIDs.remove(wall.id)
                                }
                            }))
                }
            }
        } label: {
            HStack {
                Text(room.name)
                Spacer()
                if selection.selectsAnything {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }
}
