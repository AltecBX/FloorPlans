import SwiftUI
import SwiftData
import FieldPlanCore

// MARK: - Tap an element, type one number (build 15, priorities 8–12, 14)
//
// Hundreds of measurements only get collected if each one is a tap and a
// number. Everything else — project, session, level, room, element, every
// method's answer and the evidence behind it — is filled in from the model.
//
// The plan itself is the interface: tap a wall to measure it, long-press to
// flag it as wrong. Markers already dropped and elements already measured
// show on the plan, so the next tap goes somewhere new.

struct GroundTruthCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    let snapshot: PlanSnapshot
    let session: ValidationSession

    @State private var levelID: UUID? = nil
    @State private var options: [ValidationPrefill.Option] = []
    @State private var pendingOption: ValidationPrefill.Option? = nil
    @State private var problemTarget: ProblemTarget? = nil
    @State private var hint = "Tap a wall, door, window, room or stairs to measure it."
    @State private var samples: [ValidationSample] = []
    @State private var markers: [ProblemMarker] = []
    @State private var lastSaved: String? = nil
    @State private var flagMode = false

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    private var level: LevelGeometry? {
        snapshot.levels.first { $0.id == (levelID ?? snapshot.levels.first?.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if snapshot.levels.count > 1 {
                    Picker("Level", selection: Binding(
                        get: { levelID ?? snapshot.levels.first?.id },
                        set: { levelID = $0 })) {
                        ForEach(snapshot.levels.sorted(by: { $0.storyIndex < $1.storyIndex })) { level in
                            Text(level.name).tag(Optional(level.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                header

                if let level {
                    PlanCanvasView(
                        scene: scene(for: level),
                        overlay: overlay(for: level),
                        onTap: { point, tolerance in tap(point, tolerance: tolerance, level: level) })
                } else {
                    ContentUnavailableView("No plan yet",
                                           systemImage: "square.dashed",
                                           description: Text("Scan the property first — ground truth is recorded against a plan."))
                }
            }
            .navigationTitle(session.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        flagMode.toggle()
                        hint = flagMode
                            ? "Flag mode: tap what is wrong on the plan."
                            : "Tap a wall, door, window, room or stairs to measure it."
                    } label: {
                        Label("Flag", systemImage: flagMode ? "flag.fill" : "flag")
                            .foregroundStyle(flagMode ? Color.orange : Color.accentColor)
                    }
                }
            }
            .confirmationDialog("What was measured?", isPresented: Binding(
                get: { !options.isEmpty }, set: { if !$0 { options = [] } }),
                titleVisibility: .visible) {
                ForEach(options, id: \.suggestedPhysicalKey) { option in
                    Button(optionTitle(option)) {
                        pendingOption = option
                        options = []
                    }
                }
                Button("Cancel", role: .cancel) { options = [] }
            }
            .sheet(item: $pendingOption) { option in
                GroundTruthEntrySheet(
                    option: option,
                    session: session,
                    project: project,
                    level: level,
                    priorKeys: priorKeys) { sample in
                    ValidationStore.shared.addSample(sample, projectID: project.id)
                    lastSaved = "\(sample.elementLabel) — \(measureText(sample.groundTruth, kind: sample.kind))"
                    reload()
                }
            }
            .sheet(item: $problemTarget) { target in
                ProblemMarkerSheet(target: target, session: session, project: project) { marker in
                    ValidationStore.shared.addMarker(marker, projectID: project.id)
                    reload()
                }
            }
            .onAppear(perform: reload)
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(hint)
                .font(.footnote)
                .foregroundStyle(flagMode ? Color.orange : Color.secondary)
            HStack(spacing: 14) {
                Label("\(samples.count) measured", systemImage: "ruler")
                Label("\(markers.count) flagged", systemImage: "flag")
                if let lastSaved {
                    Text("Last: \(lastSaved)")
                        .lineLimit(1)
                        .foregroundStyle(.green)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: Plan

    private func scene(for level: LevelGeometry) -> PlanScene {
        var options = PlanGenerator.Options()
        options.showDimensions = true
        options.formatter = formatter
        return PlanGenerator.scene(for: level, options: options)
    }

    /// Validation markers (priority 12): only drawn here, never on a plan a
    /// client sees. Measured elements get a tick, flagged spots a warning
    /// circle, so the next tap is an informed one.
    private func overlay(for level: LevelGeometry) -> [PlanPrimitive] {
        var primitives: [PlanPrimitive] = []
        let tested = ValidationProgress.testedElementIDs(samples)
        for wall in level.walls {
            guard let count = tested[wall.id] else { continue }
            primitives.append(.circle(center: wall.midpoint, radius: 0.13,
                                      pen: .symbol, filled: true))
            if count > 1 {
                primitives.append(.text(string: "\(count)", position: wall.midpoint,
                                        height: 0.16, rotation: 0, anchor: .center, pen: .text))
            }
        }
        for room in level.rooms where tested[room.id] != nil {
            primitives.append(.circle(center: room.labelPoint, radius: 0.16,
                                      pen: .symbol, filled: false))
        }
        for wall in level.walls {
            for opening in wall.openings where tested[opening.id] != nil {
                primitives.append(.circle(center: wall.point(atOffset: opening.centerOffset),
                                          radius: 0.10, pen: .symbol, filled: true))
            }
        }
        for marker in markers where marker.levelID == level.id {
            guard let position = marker.planPosition else { continue }
            primitives.append(.circle(center: position, radius: 0.22, pen: .finding, filled: false))
            primitives.append(.text(string: "!", position: position, height: 0.26,
                                    rotation: 0, anchor: .center, pen: .finding))
        }
        return primitives
    }

    private func tap(_ point: Vec2, tolerance: Double, level: LevelGeometry) {
        let hit = PlanHitTester.hit(point, level: level, tolerance: tolerance)
        if flagMode {
            problemTarget = ProblemTarget(
                levelID: level.id,
                roomID: roomID(for: hit, in: level),
                elementID: elementID(for: hit),
                planPoint: point,
                suggestedKind: suggestedKind(for: hit))
            return
        }
        guard let target = prefillTarget(for: hit) else {
            hint = "Nothing measurable there — tap a wall, door, window, room or stairs."
            return
        }
        let found = ValidationPrefill.options(for: target, in: level, formatter: formatter)
        if found.count == 1 {
            // One thing to measure means no menu: straight to the number.
            pendingOption = found[0]
        } else {
            options = found
        }
    }

    private func prefillTarget(for hit: PlanHit) -> ValidationPrefill.Target? {
        switch hit {
        case .wall(let id), .corner(let id, _, _): return .wall(id)
        case .opening(let wallID, let openingID): return .opening(wallID: wallID, openingID: openingID)
        case .room(let id): return .room(id)
        case .fixture(let id): return .fixture(id)
        case .annotation, .none: return nil
        }
    }

    private func elementID(for hit: PlanHit) -> UUID? {
        switch hit {
        case .wall(let id), .corner(let id, _, _), .room(let id), .fixture(let id), .annotation(let id):
            return id
        case .opening(_, let openingID): return openingID
        case .none: return nil
        }
    }

    private func roomID(for hit: PlanHit, in level: LevelGeometry) -> UUID? {
        switch hit {
        case .room(let id): return id
        case .wall(let id), .corner(let id, _, _):
            return level.rooms.first { $0.wallIDs.contains(id) }?.id
        case .opening(let wallID, _):
            return level.rooms.first { $0.wallIDs.contains(wallID) }?.id
        case .fixture(let id):
            return level.fixtures.first { $0.id == id }?.roomID
        case .annotation, .none: return nil
        }
    }

    private func suggestedKind(for hit: PlanHit) -> ProblemKind {
        switch hit {
        case .wall, .corner: return .wrongWall
        case .opening(let wallID, let openingID):
            let opening = snapshot.levels
                .compactMap { $0.wall(withID: wallID) }
                .first?.openings.first { $0.id == openingID }
            return opening?.kind == .window ? .wrongWindow : .wrongDoorWidth
        case .room: return .wrongRoomBoundary
        case .fixture: return .wrongFixture
        case .annotation, .none: return .other
        }
    }

    // MARK: Helpers

    /// Links offered when recording a repeat measurement, so the same wall
    /// scanned twice is written with the same name both times.
    private var priorKeys: [String] {
        Array(Set(samples.compactMap(\.physicalElementKey))).sorted()
    }

    private func optionTitle(_ option: ValidationPrefill.Option) -> String {
        let value = option.measurements.canonical
        guard let value else { return option.label }
        return "\(option.label) — \(measureText(value, kind: option.kind))"
    }

    private func measureText(_ value: Double, kind: AccuracyMeasureKind) -> String {
        kind.isArea ? formatter.area(value) : formatter.length(value)
    }

    private func reload() {
        samples = ValidationStore.shared.samples(for: project.id)
        markers = ValidationStore.shared.markers(for: project.id)
    }
}

// MARK: - One number (priorities 8, 9, 11)

/// Everything already known is shown but not editable. One field takes the
/// laser value, and Save & Next goes straight back to the plan.
struct GroundTruthEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let option: ValidationPrefill.Option
    let session: ValidationSession
    let project: ProjectRecord
    let level: LevelGeometry?
    let priorKeys: [String]
    let onSave: (ValidationSample) -> Void

    @State private var meters: Double? = nil
    @State private var areaText = ""
    @State private var method: GroundTruthMethod = .laser
    @State private var note = ""
    @State private var physicalKey = ""
    @State private var showKeyPicker = false
    @FocusState private var valueFocused: Bool

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    private var value: Double? {
        option.kind.isArea
            ? Double(areaText).map { $0 * UnitConstants.squareMetersPerSquareFoot }
            : meters
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if option.kind.isArea {
                        HStack {
                            TextField("0", text: $areaText)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 32, weight: .semibold, design: .rounded))
                                .focused($valueFocused)
                            Text("sq ft")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        DimensionField(label: "", meters: $meters, formatter: formatter,
                                       prominent: true, autoFocus: true)
                    }
                    Picker("Measured with", selection: $method) {
                        ForEach(GroundTruthMethod.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("LASER / TAPE VALUE")
                        .font(.headline)
                } footer: {
                    Text("This is evidence recorded beside the plan. It does not change any measurement.")
                }

                Section("What is being measured") {
                    ValidationFactRow("Element", option.label)
                    ValidationFactRow("Type", option.kind.displayName)
                    if !option.roomName.isEmpty {
                        ValidationFactRow("Room", option.roomName)
                    }
                    if let level {
                        ValidationFactRow("Level", level.name)
                    }
                }

                Section {
                    ForEach(MeasurementMethod.allCases, id: \.self) { source in
                        if let value = option.measurements.value(for: source) {
                            ValidationFactRow(source.displayName, display(value))
                        }
                    }
                    if let residual = option.measurements.meshResidual {
                        ValidationFactRow("Mesh fit residual", String(format: "%.1f mm", residual * 1000))
                    }
                    if let inliers = option.measurements.meshInlierCount {
                        ValidationFactRow("Mesh inliers", "\(inliers)")
                    }
                } header: {
                    Text("What each method says")
                } footer: {
                    Text("Methods with no answer for this element are left out rather than shown as zero.")
                }

                Section("Evidence at capture") {
                    if let confidence = option.evidence.confidence {
                        ValidationFactRow("Evidence score", "\(ConfidenceModel.percent(confidence))%")
                    }
                    if let coverage = option.evidence.coverage {
                        ValidationFactRow("Mesh coverage", "\(Int((coverage * 100).rounded()))%")
                    }
                    if let capture = option.evidence.captureConfidence {
                        ValidationFactRow("Scanner confidence", capture.displayName)
                    }
                    if let tracking = option.evidence.trackingQuality {
                        ValidationFactRow("Tracking normal", "\(Int((tracking * 100).rounded()))%")
                    }
                    if let observations = option.evidence.observationCount {
                        ValidationFactRow("Observations", "\(observations)")
                    }
                    if let thickness = option.evidence.thicknessSource {
                        ValidationFactRow("Thickness from", thickness.displayName)
                    }
                }

                Section {
                    HStack {
                        TextField("Same physical element", text: $physicalKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !priorKeys.isEmpty {
                            Button("Pick") { showKeyPicker = true }
                        }
                    }
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Repeat Scan Link")
                } footer: {
                    Text("Use the same name for the same real wall on every visit. Element IDs change on every rescan, so the name is what ties the measurements together.")
                }

                Button {
                    save()
                } label: {
                    Label("Save & Next Element", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(value == nil)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Ground Truth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog("Link to", isPresented: $showKeyPicker, titleVisibility: .visible) {
                ForEach(priorKeys, id: \.self) { key in
                    Button(key) { physicalKey = key }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                physicalKey = option.suggestedPhysicalKey
                valueFocused = true
            }
        }
    }

    private func display(_ value: Double) -> String {
        option.kind.isArea ? formatter.area(value) : formatter.length(value)
    }

    private func save() {
        guard let value else { return }
        let sample = ValidationPrefill.sample(
            from: option,
            groundTruth: value,
            method: method,
            note: note,
            validationSessionID: session.id,
            levelID: level?.id,
            levelName: level?.name ?? "",
            physicalElementKey: physicalKey.trimmingCharacters(in: .whitespaces))
        onSave(sample)
        dismiss()
    }
}

// MARK: - One-tap problem marker (priority 14)

struct ProblemTarget: Identifiable {
    let id = UUID()
    var levelID: UUID?
    var roomID: UUID?
    var elementID: UUID?
    var planPoint: Vec2
    var suggestedKind: ProblemKind
}

struct ProblemMarkerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: ProblemTarget
    let session: ValidationSession
    let project: ProjectRecord
    let onSave: (ProblemMarker) -> Void

    @State private var kind: ProblemKind = .other
    @State private var note = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("What is wrong (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                } footer: {
                    Text("Flagging a problem records where and what. It never edits the plan — the wrong geometry stays as scanned so it can be studied later.")
                }
                Section("What is wrong here") {
                    ForEach(ProblemKind.allCases, id: \.self) { candidate in
                        Button {
                            kind = candidate
                            save()
                        } label: {
                            Label(candidate.displayName, systemImage: candidate.symbolName)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("Flag A Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { kind = target.suggestedKind }
        }
    }

    private func save() {
        onSave(ProblemMarker(
            validationSessionID: session.id,
            levelID: target.levelID,
            roomID: target.roomID,
            elementID: target.elementID,
            kind: kind,
            note: note,
            planX: target.planPoint.x,
            planY: target.planPoint.y))
        dismiss()
    }
}
