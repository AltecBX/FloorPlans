import SwiftUI
import SwiftData
import FieldPlanCore

// MARK: - Field Validation Mode (build 15, priorities 4–6, 13–16, 22)
//
// The screen that turns a property visit into evidence. It says out loud
// which build produced the numbers, checks the phone can do the walk before
// it starts, keeps score of what has been ground-truthed, and produces the
// one bundle that carries the visit home.
//
// Nothing here changes a measurement. Everything here records one.

struct ValidationScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @StateObject private var store = ValidationStore.shared
    @State private var snapshot: PlanSnapshot? = nil
    @State private var session: ValidationSession? = nil
    @State private var samples: [ValidationSample] = []
    @State private var markers: [ProblemMarker] = []
    @State private var progress: ValidationProgress? = nil
    @State private var showPreflight = false
    @State private var showGroundTruth = false
    @State private var showChecklist = false
    @State private var showAnalysis = false
    @State private var notes = ""
    @State private var exportURL: URL? = nil
    @State private var exportError: String? = nil
    @State private var loadError: String? = nil

    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        List {
            modeSection
            sessionSection
            progressSection
            samplesSection
            markersSection
            finishSection
        }
        .navigationTitle("Field Validation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .sheet(isPresented: $showPreflight) {
            PreflightSheet(project: project)
        }
        .sheet(isPresented: $showGroundTruth, onDismiss: refresh) {
            if let snapshot, let session {
                GroundTruthCaptureView(project: project, snapshot: snapshot, session: session)
            }
        }
        .sheet(isPresented: $showChecklist) {
            FieldVisitChecklistSheet(project: project, snapshot: snapshot,
                                     sampleCount: samples.count)
        }
        .sheet(isPresented: $showAnalysis) {
            MethodComparisonSheet(samples: samples)
        }
        .sheet(item: Binding(
            get: { exportURL.map { ExportedBundle(url: $0) } },
            set: { if $0 == nil { exportURL = nil } })) { bundle in
            ShareSheet(items: [bundle.url])
        }
        .alert("Export Failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: Mode banner (priority 4)

    private var modeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.fieldValidationMode },
                set: { settings.fieldValidationMode = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Field Validation Mode")
                        .font(.headline)
                    Text("Forces sensor recording on for every scan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if settings.fieldValidationMode {
                // Every number collected today has to be attributable to the
                // build that produced it, or the dataset cannot be compared
                // across builds later.
                VStack(alignment: .leading, spacing: 4) {
                    ValidationFactRow("App", AppInfo.versionAndBuild)
                    ValidationFactRow("Device", DeviceInfoProvider.model)
                    ValidationFactRow("iOS", UIDevice.current.systemVersion)
                    ValidationFactRow("LiDAR", DeviceInfoProvider.hasLiDAR ? "Present" : "Not present")
                    ValidationFactRow("Sensor recording",
                                      settings.recordSensorData ? "On" : "Off")
                    if let session {
                        ValidationFactRow("Validation session", session.name)
                        ValidationFactRow("Session ID", session.id.uuidString)
                    }
                }
                .font(.caption.monospacedDigit())
                .padding(.vertical, 4)
            }
        } header: {
            if settings.fieldValidationMode {
                Text("VALIDATION MODE — RECORDING EVIDENCE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            } else {
                Text("Mode")
            }
        } footer: {
            Text("Validation mode does not change how anything is measured. It records what was measured, by which method, next to what the laser said.")
        }
    }

    // MARK: Session (priorities 4, 5, 16)

    private var sessionSection: some View {
        Section("Property Visit") {
            if let session {
                LabeledContent("Started", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
                TextField("Session notes — conditions, what was odd, what to check",
                          text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                    .onSubmit(saveNotes)
                Button("Save Notes") { saveNotes() }
                    .disabled(notes == (session.notes))
                if session.endedAt == nil {
                    Button("End This Visit") {
                        store.endSession(session)
                        refresh()
                    }
                } else {
                    LabeledContent("Ended", value: session.endedAt!.formatted(date: .abbreviated, time: .shortened))
                    Button("Start Another Visit") { startSession() }
                }
            } else {
                Button {
                    startSession()
                } label: {
                    Label("Start Validation Visit", systemImage: "record.circle")
                }
            }
            Button {
                showPreflight = true
            } label: {
                Label("Run Preflight Test", systemImage: "checklist.checked")
            }
        }
    }

    // MARK: Progress (priority 13)

    @ViewBuilder
    private var progressSection: some View {
        if let progress, !progress.lines.isEmpty {
            Section {
                ForEach(progress.lines, id: \.kind) { line in
                    HStack {
                        Text(line.displayName)
                            .font(.subheadline)
                        Spacer()
                        Text("\(line.tested) of \(line.available)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(line.tested == 0 ? .secondary : .primary)
                    }
                }
                HStack {
                    Text("Elements measured in more than one scan")
                    Spacer()
                    Text("\(progress.repeatedElementCount)")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Validation Coverage")
            } footer: {
                Text("What exists on the plan against what has been ground-truthed. This is orientation, not a quota — measure what matters and what looks wrong.")
            }
        }
    }

    // MARK: Samples (priorities 8–11)

    private var samplesSection: some View {
        Section {
            Button {
                if session == nil { startSession() }
                showGroundTruth = true
            } label: {
                Label("Measure Elements", systemImage: "ruler.fill")
                    .font(.headline)
            }
            .disabled(snapshot == nil)

            if samples.isEmpty {
                Text("No ground truth recorded yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showAnalysis = true
                } label: {
                    Label("Compare Methods", systemImage: "chart.bar.xaxis")
                }
                ForEach(samples.sorted(by: { $0.recordedAt > $1.recordedAt }).prefix(20)) { sample in
                    ValidationSampleRow(sample: sample)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.deleteSample(sample.id, projectID: project.id)
                                refresh()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                if samples.count > 20 {
                    Text("…and \(samples.count - 20) more. All of them travel in the bundle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Ground Truth — \(samples.count) sample(s)")
        } footer: {
            Text("Each row keeps every method's answer beside the laser value. Nothing is averaged and nothing is overwritten — recording ground truth never edits the plan.")
        }
    }

    // MARK: Problem markers (priority 14)

    @ViewBuilder
    private var markersSection: some View {
        if !markers.isEmpty {
            Section("Problems Flagged — \(markers.count)") {
                ForEach(markers.sorted(by: { $0.recordedAt > $1.recordedAt })) { marker in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(marker.kind.displayName)
                            .font(.subheadline.weight(.medium))
                        if !marker.note.isEmpty {
                            Text(marker.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(marker.recordedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: Before leaving (priorities 15, 22)

    private var finishSection: some View {
        Section {
            Button {
                showChecklist = true
            } label: {
                Label("Field Visit Checklist", systemImage: "list.bullet.clipboard")
            }
            Button {
                exportBundle()
            } label: {
                Label("Export Validation Bundle", systemImage: "shippingbox")
            }
        } header: {
            Text("Before Leaving The Property")
        } footer: {
            Text("The bundle carries the samples, the analysis, the problem markers, the scan event log and the plan, and lists the raw captures, world maps and sensor sessions by path rather than copying gigabytes twice.")
        }
    }

    // MARK: Data

    private func refresh() {
        do {
            let snapshot = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            self.snapshot = snapshot
            let sessions = store.sessions(for: project.id)
            session = sessions.last
            notes = session?.notes ?? ""
            samples = store.samples(for: project.id)
            markers = store.markers(for: project.id)
            progress = ValidationProgress.compute(
                levels: snapshot.levels, samples: samples, problemMarkers: markers)
        } catch {
            loadError = error.localizedDescription
            AppLog.store.error("Validation refresh failed: \(error.localizedDescription)")
        }
    }

    private func startSession() {
        session = store.startSession(projectID: project.id)
        settings.fieldValidationMode = true
        refresh()
    }

    private func saveNotes() {
        guard var session else { return }
        session.notes = notes
        store.updateSession(session)
        self.session = session
    }

    private func exportBundle() {
        do {
            exportURL = try store.exportBundle(project: project, snapshot: snapshot)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private struct ExportedBundle: Identifiable {
        let id = UUID()
        let url: URL
    }
}

// MARK: - Rows

struct ValidationFactRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// One recorded sample: the laser value, and how far each method was from it.
struct ValidationSampleRow: View {
    let sample: ValidationSample

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(sample.elementLabel)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(sample.method.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("\(sample.kind.displayName) · \(measure(sample.groundTruth)) measured")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Every method that had an answer, and how far off it was.
            let errors = MeasurementMethod.allCases.compactMap { method -> (MeasurementMethod, Double)? in
                sample.error(for: method).map { (method, $0) }
            }
            if errors.isEmpty {
                Text("No method produced a value for this element.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 10) {
                    ForEach(errors, id: \.0) { method, error in
                        Text("\(method.shortName) \(delta(error))")
                            .foregroundStyle(color(for: error))
                    }
                }
                .font(.caption2.monospacedDigit())
            }
            if let key = sample.physicalElementKey {
                Text(key)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func measure(_ value: Double) -> String {
        sample.kind.isArea ? formatter.area(value) : formatter.length(value)
    }

    private func delta(_ error: Double) -> String {
        if sample.kind.isArea {
            let feet = error / UnitConstants.squareMetersPerSquareFoot
            return String(format: "%+.1f sf", feet)
        }
        return String(format: "%+.2f\"", error / UnitConstants.metersPerInch)
    }

    private func color(for error: Double) -> Color {
        guard !sample.kind.isArea else { return .secondary }
        let inches = abs(error / UnitConstants.metersPerInch)
        return inches <= 0.5 ? .green : (inches <= 1 ? .orange : .red)
    }
}

extension MeasurementMethod {
    /// Short enough to fit four of them on one line in the field.
    var shortName: String {
        switch self {
        case .canonical: return "App"
        case .roomPlan: return "RP"
        case .meshFit: return "Mesh"
        case .originalScanned: return "Scan"
        case .userEdited: return "Edit"
        }
    }

    var displayName: String {
        switch self {
        case .canonical: return "FieldPlan value"
        case .roomPlan: return "RoomPlan"
        case .meshFit: return "Mesh fit"
        case .originalScanned: return "Originally scanned"
        case .userEdited: return "User edited"
        }
    }
}

extension GroundTruthMethod {
    var displayName: String {
        switch self {
        case .laser: return "Laser"
        case .tape: return "Tape"
        case .other: return "Other"
        }
    }
}

extension ProblemKind {
    var displayName: String {
        switch self {
        case .wrongWall: return "Wall in the wrong place"
        case .missingWall: return "Missing wall"
        case .wrongCorner: return "Wrong corner"
        case .missingDoor: return "Missing door"
        case .wrongDoorWidth: return "Wrong door width"
        case .missingWindow: return "Missing window"
        case .wrongWindow: return "Wrong window"
        case .wrongRoomBoundary: return "Wrong room boundary"
        case .wrongFixture: return "Wrong or missing fixture"
        case .wrongRoomLabel: return "Wrong room label"
        case .wrongFloor: return "Room on the wrong floor"
        case .floorAlignment: return "Floors not aligned"
        case .stairs: return "Stairs wrong"
        case .coverage: return "Area not captured"
        case .other: return "Something else"
        }
    }

    var symbolName: String {
        switch self {
        case .wrongWall, .missingWall, .wrongCorner, .wrongRoomBoundary: return "square.dashed"
        case .missingDoor, .wrongDoorWidth: return "door.left.hand.open"
        case .missingWindow, .wrongWindow: return "window.casement"
        case .wrongFixture: return "shower"
        case .wrongRoomLabel: return "tag"
        case .wrongFloor, .floorAlignment: return "square.3.layers.3d"
        case .stairs: return "stairs"
        case .coverage: return "viewfinder.trianglebadge.exclamationmark"
        case .other: return "questionmark.circle"
        }
    }
}

// MARK: - Preflight (priority 5)

struct PreflightSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord

    @State private var report: PreflightReport? = nil

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    Section {
                        HStack {
                            Image(systemName: report.canScan ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(report.canScan ? .green : .red)
                                .font(.title2)
                            Text(report.summary)
                                .font(.headline)
                        }
                    }
                    Section("Checks") {
                        ForEach(report.checks, id: \.id) { check in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: symbol(check.status))
                                    .foregroundStyle(color(check.status))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(check.title)
                                        .font(.subheadline.weight(.medium))
                                    Text(check.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView("Checking…")
                }
            }
            .navigationTitle("Preflight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Re-run") { run() } }
            }
            .onAppear(perform: run)
        }
    }

    private func run() {
        report = Preflight.run(
            sensorRecordingEnabled: SettingsStore.shared.recordSensorData,
            sessionDirectory: ProjectStore.shared.sessionsDir(project.id))
    }

    private func symbol(_ status: PreflightStatus) -> String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(_ status: PreflightStatus) -> Color {
        switch status {
        case .ready: return .green
        case .warning: return .orange
        case .blocked: return .red
        case .unknown: return .secondary
        }
    }
}

// MARK: - Field visit checklist (priority 22)

struct FieldVisitChecklistSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    let snapshot: PlanSnapshot?
    let sampleCount: Int

    @State private var checklist: FieldVisitChecklist? = nil

    var body: some View {
        NavigationStack {
            List {
                if let checklist {
                    Section {
                        Label(checklist.isReadyToLeave
                              ? "Nothing outstanding — safe to leave."
                              : "\(checklist.unresolved.count) item(s) still open.",
                              systemImage: checklist.isReadyToLeave ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(checklist.isReadyToLeave ? .green : .orange)
                    }
                    Section("Checklist") {
                        ForEach(checklist.items) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.isSatisfied ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isSatisfied ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.medium))
                                    Text(item.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Before You Leave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Re-check") { build() } }
            }
            .onAppear(perform: build)
        }
    }

    /// Built from what the app actually holds right now — not a static list.
    private func build() {
        let levels = snapshot?.levels ?? []
        let findings = levels.flatMap { MissingSpaceDetector.findings(for: $0, levels: levels) }
        var lowCoverage = 0
        for level in levels {
            for wall in level.walls where (wall.evidence?.coverage ?? 1) < 0.35 {
                lowCoverage += 1
            }
        }

        // Tracking is judged from what the sessions recorded, not from a
        // guess: a relocalization that failed, or a session that spent a
        // meaningful share of its poses not tracking normally.
        var trackingFailed = false
        var finalized = false
        for scan in project.scans {
            guard let sessionID = scan.sessionID,
                  let log = try? ProjectStore.shared.loadSessionLog(projectID: project.id, sessionID: sessionID)
            else { continue }
            if log.events.contains(where: { $0.kind == .relocalizationFailed }) {
                trackingFailed = true
            }
            if let summary = log.summary {
                finalized = true
                if summary.trackingNormalFraction < 0.85 { trackingFailed = true }
            }
        }
        let checkpoints = ScanCheckpointStore.shared.checkpoints(for: project.id)
        let outstanding = CheckpointStore.outstanding(checkpoints).count
        let maps = SpatialSession.loadLatestCheckpoint(
            in: ScanCheckpointStore.shared.worldMapsDir(project.id))
        let bundle = (try? FileManager.default.contentsOfDirectory(
            at: ProjectStore.shared.exportsDir(project.id), includingPropertiesForKeys: nil))?
            .contains { $0.lastPathComponent.hasSuffix("validation.zip") } ?? false

        checklist = FieldVisitChecklist.build(.init(
            levels: levels,
            findings: findings,
            lowCoverageWallCount: lowCoverage,
            trackingFailed: trackingFailed,
            outstandingCheckpoints: outstanding,
            worldMapSaved: maps != nil,
            sensorSessionFinalized: finalized,
            validationSampleCount: sampleCount,
            unsavedValidationEdits: false,
            projectSaved: !project.snapshots.isEmpty,
            bundleAvailable: bundle))
    }
}

// MARK: - Method comparison (priorities 10, 11, 18)

struct MethodComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let samples: [ValidationSample]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let ranked = ValidationAnalysis.rankedSources(samples)
                    if ranked.isEmpty {
                        Text("Not enough samples yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ranked, id: \.source) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.source.displayName)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(inches(entry.statistics.meanAbsoluteError))
                                    .font(.subheadline.monospacedDigit())
                            }
                            Text("n=\(entry.sampleCount) · no answer on \(entry.missingCount) · bias \(signedInches(entry.statistics.meanSignedError)) · worst \(inches(entry.statistics.maxAbsoluteError))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Mean Absolute Error By Method")
                } footer: {
                    Text("Lengths only, over the samples where each method had an answer. A method that answers rarely is not better for being right when it does — the “no answer” count says how often it declined.")
                }

                Section {
                    let pairs: [(MeasurementMethod, MeasurementMethod)] = [
                        (.canonical, .meshFit), (.canonical, .roomPlan), (.meshFit, .roomPlan),
                    ]
                    ForEach(pairs, id: \.0) { pair in
                        if let head = ValidationAnalysis.headToHead(samples, pair.0, pair.1) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(pair.0.displayName) vs \(pair.1.displayName)")
                                    .font(.subheadline.weight(.medium))
                                Text("\(head.aCloserCount) – \(head.bCloserCount) over \(head.pairCount) shared element(s), \(head.tiedCount) tied")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("MAE \(inches(head.meanAbsoluteErrorA)) vs \(inches(head.meanAbsoluteErrorB))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Head To Head")
                } footer: {
                    Text("Compared only where both methods answered the same element. FieldPlan does not pick a winner from this — that decision needs far more properties than one.")
                }

                let spreads = ValidationAnalysis.repeatability(samples).filter { $0.scanCount > 1 }
                if !spreads.isEmpty {
                    Section {
                        ForEach(spreads, id: \.self) { spread in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(spread.physicalElementKey)
                                    .font(.subheadline.weight(.medium))
                                Text("\(spread.source.displayName) · \(spread.kind.displayName) · \(spread.scanCount) scans")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("spread \(inches(spread.range))"
                                     + (spread.standardDeviation.map { " · sd \(inches($0))" } ?? "")
                                     + (spread.bias.map { " · bias \(signedInches($0))" } ?? ""))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Repeatability")
                    } footer: {
                        Text("Linked by the “same physical element” name you typed, not by element IDs — a rescan produces new IDs for the same wall.")
                    }
                }
            }
            .navigationTitle("Method Comparison")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func inches(_ meters: Double) -> String {
        String(format: "%.2f\"", meters / UnitConstants.metersPerInch)
    }

    private func signedInches(_ meters: Double) -> String {
        String(format: "%+.2f\"", meters / UnitConstants.metersPerInch)
    }
}
