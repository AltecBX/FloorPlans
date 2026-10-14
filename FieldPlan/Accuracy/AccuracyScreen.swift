import SwiftUI
import SwiftData
import FieldPlanCore

/// Accuracy & Verification (spec §31, brief §9): honest reporting of
/// measurement sources, geometry QA, scan findings and verification
/// coverage — plus the known-dimension test framework, which is the only
/// place an accuracy figure can come from. Tests are taken straight off the
/// plan: tap a wall, door, window or room, type what the tape says, and the
/// app's value, the element and its evidence score are recorded with it.
struct AccuracyScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @State private var snapshot: PlanSnapshot? = nil
    @State private var findings: [QAFinding] = []
    @State private var spaceFindings: [SpaceFinding] = []
    @State private var sourceCounts: [(String, Int)] = []
    @State private var confidenceCounts: (high: Int, medium: Int, low: Int, unscored: Int) = (0, 0, 0, 0)
    @State private var showManualTest = false
    @State private var showPlanPicker = false

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }
    private var samples: [AccuracySample] { project.accuracyTests.map(\.sample) }

    var body: some View {
        List {
            statisticsSection
            calibrationSection
            testsSection

            Section("Geometry QA") {
                let status = QAEngine.overallStatus(findings)
                HStack {
                    Label(status.displayName, systemImage: status == .pass
                        ? "checkmark.seal.fill"
                        : (status == .review ? "exclamationmark.triangle.fill" : "xmark.seal.fill"))
                        .foregroundStyle(AppTheme.severityColor(status))
                        .font(.headline)
                    Spacer()
                    Text("\(findings.count) finding(s)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                ForEach(findings.prefix(12)) { finding in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.code.displayName)
                            .font(.subheadline.weight(.medium))
                        Text(finding.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if spaceFindings.isEmpty {
                    Label("No unscanned space detected", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                ForEach(spaceFindings) { finding in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.kind.displayName)
                            .font(.subheadline.weight(.medium))
                        Text(finding.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Scan Completeness")
            } footer: {
                Text("Derived from the geometry: enclosed areas no room explains, doorways that lead nowhere, room edges with no wall behind them, stairs with no adjacent level.")
            }

            Section {
                StatRow(label: "High (≥ 85%)", value: "\(confidenceCounts.high)")
                StatRow(label: "Medium (60–85%)", value: "\(confidenceCounts.medium)")
                StatRow(label: "Low (< 60%)", value: "\(confidenceCounts.low)")
                if confidenceCounts.unscored > 0 {
                    StatRow(label: "No evidence score", value: "\(confidenceCounts.unscored)")
                }
            } header: {
                Text("Wall Evidence")
            } footer: {
                Text("Evidence scores combine the scanner's confidence, how much of each wall has LiDAR mesh behind it and how good tracking was. They are not accuracy figures — the tests above are.")
            }

            Section("Measurement Sources") {
                if sourceCounts.isEmpty {
                    Text("No measured elements yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sourceCounts, id: \.0) { source, count in
                    StatRow(label: source, value: "\(count)")
                }
            }

            Section("Verification Coverage") {
                let measurements = project.measurements.map(\.model)
                let critical = measurements.filter(\.isCritical)
                let unverified = critical.filter { $0.verification == .unverified }
                StatRow(label: "Measurements", value: "\(measurements.count)")
                StatRow(label: "Critical dimensions", value: "\(critical.count)")
                StatRow(label: "Critical verified", value: "\(critical.count - unverified.count)")
                if !unverified.isEmpty {
                    ForEach(unverified) { m in
                        Label(m.name, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Accuracy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .sheet(isPresented: $showManualTest) {
            AccuracyTestForm(project: project, prefill: nil)
        }
        .sheet(isPresented: $showPlanPicker) {
            if let snapshot {
                PlanAccuracyPicker(project: project, snapshot: snapshot)
            }
        }
    }

    // MARK: Statistics

    @ViewBuilder
    private var statisticsSection: some View {
        Section {
            if let stats = AccuracyStatistics.compute(samples.filter { !$0.kind.isArea }) {
                StatRow(label: "Length tests", value: "\(stats.count)")
                StatRow(label: "Mean absolute error", value: inches(stats.meanAbsoluteError))
                StatRow(label: "Median absolute error", value: inches(stats.medianAbsoluteError))
                StatRow(label: "95th percentile", value: inches(stats.p95AbsoluteError))
                StatRow(label: "Maximum", value: inches(stats.maxAbsoluteError))
                StatRow(label: "Bias (app − tape)", value: signedInches(stats.meanSignedError))
                if let within = stats.withinOneInch {
                    StatRow(label: "Within 1\"", value: percent(within))
                }
                if let within = stats.withinThreePercent {
                    StatRow(label: "Within 3%", value: percent(within))
                }
                if let p95 = stats.p95PercentError {
                    StatRow(label: "95th percentile error", value: String(format: "%.1f%%", p95))
                }
            } else {
                Text("No length tests yet. Tap “Test From Plan”, pick a wall, door or window, and enter what the tape says.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let areaStats = AccuracyStatistics.compute(samples.filter(\.kind.isArea)) {
                StatRow(label: "Area tests", value: "\(areaStats.count)")
                if let mean = areaStats.meanPercentError {
                    StatRow(label: "Area error (mean)", value: String(format: "%.1f%%", mean))
                }
                if let p95 = areaStats.p95PercentError {
                    StatRow(label: "Area error (95th)", value: String(format: "%.1f%%", p95))
                }
            }
            let byKind = AccuracyStatistics.byKind(samples)
            if byKind.count > 1 {
                DisclosureGroup("By measurement type") {
                    ForEach(AccuracyMeasureKind.allCases, id: \.self) { kind in
                        if let stats = byKind[kind] {
                            HStack {
                                Text(kind.displayName)
                                Spacer()
                                Text(kind.isArea
                                     ? String(format: "%.1f%% mean · n=%d", stats.meanPercentError ?? 0, stats.count)
                                     : "\(inches(stats.meanAbsoluteError)) mean · n=\(stats.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption.monospacedDigit())
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            let repeats = AccuracyAnalysis.repeatability(samples)
            if !repeats.isEmpty {
                DisclosureGroup("Repeated scans") {
                    ForEach(repeats, id: \.name) { group in
                        HStack {
                            Text(group.name)
                            Spacer()
                            Text("SD \(group.kind.isArea ? formatter.area(group.standardDeviation) : inches(group.standardDeviation)) · n=\(group.count)")
                                .foregroundStyle(.secondary)
                                .font(.caption.monospacedDigit())
                        }
                        .font(.subheadline)
                    }
                }
            }
        } header: {
            Text("Measured Accuracy")
        } footer: {
            Text("Every figure here comes from a test against a tape or laser on this property. CubiCasa's published benchmark for LiDAR phones is “within 3%”; the numbers above are what this device actually did.")
        }
    }

    @ViewBuilder
    private var calibrationSection: some View {
        let bins = AccuracyAnalysis.calibration(samples)
        if !bins.isEmpty {
            Section {
                ForEach(bins, id: \.lower) { bin in
                    HStack {
                        Text("\(Int(bin.lower * 100))–\(Int(bin.upper * 100))%")
                            .font(.subheadline.monospacedDigit())
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(inches(bin.meanAbsoluteError)) mean · n=\(bin.count)")
                            if let within = bin.withinOneInch {
                                Text("\(percent(within)) within 1\"")
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Confidence Calibration")
            } footer: {
                Text("What each evidence-score band actually delivered. If high-confidence walls are not more accurate than low ones, the score needs retuning — say so.")
            }
        }
    }

    // MARK: Tests

    private var testsSection: some View {
        Section {
            ForEach(project.accuracyTests.sorted(by: { $0.createdAt > $1.createdAt })) { test in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(test.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(test.kind.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        let isArea = test.kind.isArea
                        Text("Tape \(isArea ? formatter.area(test.knownValue) : formatter.length(test.knownValue))")
                        Text("App \(isArea ? formatter.area(test.appValue) : formatter.length(test.appValue))")
                        Spacer()
                        if isArea {
                            let pct = test.knownValue > 1e-9 ? abs(test.delta) / test.knownValue * 100 : 0
                            Text(String(format: "Δ %.1f%%", pct))
                                .foregroundStyle(pct <= 1.5 ? .green : (pct <= 3 ? .orange : .red))
                        } else {
                            let deltaInches = test.delta / UnitConstants.metersPerInch
                            Text(String(format: "Δ %+.2f\"", deltaInches))
                                .foregroundStyle(abs(deltaInches) <= 0.5 ? .green : (abs(deltaInches) <= 1 ? .orange : .red))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if let confidence = test.predictedConfidence {
                        Text("Evidence score at test time: \(ConfidenceModel.percent(confidence))%")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        context.delete(test)
                        try? context.save()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            Button {
                showPlanPicker = true
            } label: {
                Label("Test From Plan", systemImage: "scope")
            }
            .disabled(snapshot == nil)
            Button {
                showManualTest = true
            } label: {
                Label("Add Manual Test", systemImage: "plus")
            }
        } header: {
            Text("Known-Dimension Tests")
        } footer: {
            Text("Measure something with a trusted tape or laser, then compare against what the app captured. Use the same name for the same wall across repeated scans and the spread shows up under Repeated Scans.")
        }
    }

    // MARK: Helpers

    private func inches(_ meters: Double) -> String {
        String(format: "%.2f\"", meters / UnitConstants.metersPerInch)
    }

    private func signedInches(_ meters: Double) -> String {
        String(format: "%+.2f\"", meters / UnitConstants.metersPerInch)
    }

    private func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    private func refresh() {
        do {
            let snapshot = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            self.snapshot = snapshot
            findings = QAEngine.evaluate(snapshot: snapshot)
            spaceFindings = snapshot.levels.flatMap { MissingSpaceDetector.findings(for: $0, levels: snapshot.levels) }
            var counts: [String: Int] = [:]
            var high = 0, medium = 0, low = 0, unscored = 0
            for level in snapshot.levels {
                for wall in level.walls {
                    counts[wall.source.displayName, default: 0] += 1
                    if let evidence = wall.evidence {
                        switch evidence.band {
                        case .high: high += 1
                        case .medium: medium += 1
                        case .low: low += 1
                        }
                    } else if wall.source == .lidarScanned {
                        unscored += 1
                    }
                }
                for fixture in level.fixtures {
                    counts[fixture.source.displayName, default: 0] += 1
                }
            }
            for m in project.measurements {
                counts[m.model.source.displayName, default: 0] += 1
            }
            sourceCounts = counts.sorted { $0.value > $1.value }
            confidenceCounts = (high, medium, low, unscored)
        } catch {
            AppLog.store.error("Accuracy refresh failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Test entry

/// What a test is about, filled in from the plan or typed by hand.
struct AccuracyTestPrefill {
    var name: String
    var kind: AccuracyMeasureKind
    var appValue: Double?
    var elementID: UUID?
    var roomID: UUID?
    var predictedConfidence: Double?
    var alternateValue: Double?
    var scanSessionID: UUID?
}

private struct AccuracyTestForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    let prefill: AccuracyTestPrefill?

    @State private var name = ""
    @State private var kind: AccuracyMeasureKind = .wallLength
    @State private var known: Double? = nil
    @State private var knownAreaText = ""
    @State private var app: Double? = nil
    @State private var appAreaText = ""
    @State private var notes = ""

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    private var knownValue: Double? {
        kind.isArea ? Double(knownAreaText).map { $0 * UnitConstants.squareMetersPerSquareFoot } : known
    }

    private var appValue: Double? {
        if let prefilled = prefill?.appValue { return prefilled }
        return kind.isArea ? Double(appAreaText).map { $0 * UnitConstants.squareMetersPerSquareFoot } : app
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What was measured") {
                    TextField("Name (e.g. Kitchen north wall)", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(AccuracyMeasureKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .disabled(prefill?.appValue != nil)
                }
                Section("Values") {
                    if let prefilled = prefill?.appValue {
                        LabeledContent("App value", value: kind.isArea ? formatter.area(prefilled) : formatter.length(prefilled))
                    } else if kind.isArea {
                        HStack {
                            TextField("App value", text: $appAreaText).keyboardType(.decimalPad)
                            Text("sq ft").foregroundStyle(.secondary)
                        }
                    } else {
                        DimensionField(label: "App value (scanned)", meters: $app, formatter: formatter)
                    }
                    if kind.isArea {
                        HStack {
                            TextField("Tape / laser value", text: $knownAreaText).keyboardType(.decimalPad)
                            Text("sq ft").foregroundStyle(.secondary)
                        }
                    } else {
                        DimensionField(label: "Tape / laser value", meters: $known, formatter: formatter)
                    }
                    if let confidence = prefill?.predictedConfidence {
                        LabeledContent("Evidence score", value: "\(ConfidenceModel.percent(confidence))%")
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                Button("Save Test") { save() }
                    .disabled(knownValue == nil || appValue == nil || name.isEmpty)
            }
            .navigationTitle("Known-Dimension Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let prefill {
                    name = prefill.name
                    kind = prefill.kind
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let knownValue, let appValue, !name.isEmpty else { return }
        let test = AccuracyTestRecord(
            name: name, knownValue: knownValue, appValue: appValue, source: .lidarScanned,
            kind: kind, elementID: prefill?.elementID, roomID: prefill?.roomID,
            predictedConfidence: prefill?.predictedConfidence, alternateValue: prefill?.alternateValue,
            scanSessionID: prefill?.scanSessionID, notes: notes.isEmpty ? nil : notes)
        test.project = project
        context.insert(test)
        try? context.save()
        dismiss()
    }
}

/// Tap an element on the plan to test it: the app's value, the element and
/// its evidence score come along, only the tape value is typed.
private struct PlanAccuracyPicker: View {
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    let snapshot: PlanSnapshot

    @State private var levelID: UUID? = nil
    @State private var prefill: AccuracyTestPrefill? = nil
    @State private var roomChoice: RoomShape? = nil
    @State private var hint = "Tap a wall, door, window or room."

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
                    .padding()
                }
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                if let level {
                    PlanCanvasView(scene: scene(for: level), onTap: { point, tolerance in
                        pick(point, tolerance: tolerance, level: level)
                    })
                }
            }
            .navigationTitle("Test From Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { prefill.map { PrefillBox(prefill: $0) } },
                set: { if $0 == nil { prefill = nil } })) { box in
                AccuracyTestForm(project: project, prefill: box.prefill)
            }
            .confirmationDialog("Which room measurement?", isPresented: Binding(
                get: { roomChoice != nil }, set: { if !$0 { roomChoice = nil } }),
                titleVisibility: .visible) {
                if let room = roomChoice, let extents = GeometryOps.orientedExtents(room.polygon) {
                    Button("Width \(formatter.length(extents.width))") {
                        prefill = roomPrefill(room, kind: .roomWidth, value: extents.width)
                    }
                    Button("Depth \(formatter.length(extents.depth))") {
                        prefill = roomPrefill(room, kind: .roomDepth, value: extents.depth)
                    }
                    Button("Area \(formatter.area(room.floorArea))") {
                        prefill = roomPrefill(room, kind: .roomArea, value: room.floorArea)
                    }
                    if let ceiling = room.ceilingHeight {
                        Button("Ceiling \(formatter.length(ceiling))") {
                            prefill = roomPrefill(room, kind: .ceilingHeight, value: ceiling)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { roomChoice = nil }
            }
        }
    }

    private struct PrefillBox: Identifiable {
        let id = UUID()
        let prefill: AccuracyTestPrefill
    }

    private func scene(for level: LevelGeometry) -> PlanScene {
        var options = PlanGenerator.Options()
        options.showDimensions = true
        options.formatter = formatter
        return PlanGenerator.scene(for: level, options: options)
    }

    private func roomPrefill(_ room: RoomShape, kind: AccuracyMeasureKind, value: Double) -> AccuracyTestPrefill {
        AccuracyTestPrefill(
            name: "\(room.name) \(kind.displayName.lowercased())", kind: kind, appValue: value,
            elementID: room.id, roomID: room.id,
            predictedConfidence: room.evidence?.confidence,
            alternateValue: nil, scanSessionID: room.evidence?.sessionID)
    }

    private func pick(_ point: Vec2, tolerance: Double, level: LevelGeometry) {
        switch PlanHitTester.hit(point, level: level, tolerance: tolerance) {
        case .wall(let id), .corner(let id, _, _):
            guard let wall = level.wall(withID: id) else { return }
            let room = level.rooms.first { GeometryOps.distanceToPolygonBoundary($0.polygon, wall.midpoint) < 0.3 }
            let index = level.walls.firstIndex { $0.id == id } ?? 0
            prefill = AccuracyTestPrefill(
                name: "\(room?.name ?? "Wall") wall \(index + 1)", kind: .wallLength, appValue: wall.length,
                elementID: wall.id, roomID: room?.id,
                predictedConfidence: wall.evidence?.confidence,
                alternateValue: wall.evidence?.alternate?.value,
                scanSessionID: wall.evidence?.sessionID)
        case .opening(let wallID, let openingID):
            guard let wall = level.wall(withID: wallID),
                  let opening = wall.openings.first(where: { $0.id == openingID }) else { return }
            let kind: AccuracyMeasureKind = opening.kind == .window ? .windowWidth : .doorWidth
            let room = level.rooms.first { GeometryOps.distanceToPolygonBoundary($0.polygon, wall.point(atOffset: opening.centerOffset)) < 0.3 }
            prefill = AccuracyTestPrefill(
                name: "\(room?.name ?? "") \(opening.kind.displayName.lowercased()) width".trimmingCharacters(in: .whitespaces),
                kind: kind, appValue: opening.width,
                elementID: opening.id, roomID: room?.id,
                predictedConfidence: opening.evidence?.confidence,
                alternateValue: nil, scanSessionID: opening.evidence?.sessionID)
        case .room(let id):
            roomChoice = level.room(withID: id)
        case .fixture, .annotation, .none:
            hint = "That is not a measurable element — tap a wall, door, window or room."
        }
    }
}
