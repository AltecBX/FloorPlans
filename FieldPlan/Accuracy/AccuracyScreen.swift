import SwiftUI
import SwiftData
import FieldPlanCore

/// Accuracy & Verification (spec §31): honest reporting of measurement
/// sources, geometry QA status and verification coverage — never a marketing
/// accuracy claim — plus known-dimension testing against trusted references.
struct AccuracyScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @State private var findings: [QAFinding] = []
    @State private var sourceCounts: [(String, Int)] = []
    @State private var showTestForm = false

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    var body: some View {
        List {
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

            Section {
                ForEach(project.accuracyTests.sorted(by: { $0.createdAt > $1.createdAt })) { test in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(test.name).font(.subheadline.weight(.medium))
                        HStack {
                            Text("Known \(formatter.length(test.knownValue))")
                            Text("App \(formatter.length(test.appValue))")
                            Spacer()
                            let deltaInches = abs(test.delta) / UnitConstants.metersPerInch
                            Text(String(format: "Δ %.2f\"", deltaInches))
                                .foregroundStyle(deltaInches <= 0.5 ? .green : (deltaInches <= 1 ? .orange : .red))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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
                    showTestForm = true
                } label: {
                    Label("Add Known-Dimension Test", systemImage: "plus")
                }
            } header: {
                Text("Known-Dimension Tests")
            } footer: {
                Text("Measure something with a trusted tape or laser, then compare against what the app captured. This shows this device's real performance — the app makes no blanket accuracy claims.")
            }
        }
        .navigationTitle("Accuracy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .sheet(isPresented: $showTestForm) {
            AccuracyTestForm(project: project)
        }
    }

    private func refresh() {
        do {
            let snapshot = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            findings = QAEngine.evaluate(snapshot: snapshot)
            var counts: [String: Int] = [:]
            for level in snapshot.levels {
                for wall in level.walls {
                    counts[wall.source.displayName, default: 0] += 1
                }
                for fixture in level.fixtures {
                    counts[fixture.source.displayName, default: 0] += 1
                }
            }
            for m in project.measurements {
                counts[m.model.source.displayName, default: 0] += 1
            }
            sourceCounts = counts.sorted { $0.value > $1.value }
        } catch {
            AppLog.store.error("Accuracy refresh failed: \(error.localizedDescription)")
        }
    }
}

private struct AccuracyTestForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord

    @State private var name = ""
    @State private var known: Double? = nil
    @State private var app: Double? = nil

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    var body: some View {
        NavigationStack {
            Form {
                TextField("What was measured (e.g. Kitchen north wall)", text: $name)
                DimensionField(label: "Known value (tape/laser)", meters: $known, formatter: formatter)
                DimensionField(label: "App value (scanned)", meters: $app, formatter: formatter)
                Button("Save Test") {
                    guard let known, let app, !name.isEmpty else { return }
                    let test = AccuracyTestRecord(
                        name: name, knownValue: known, appValue: app, source: .lidarScanned)
                    test.project = project
                    context.insert(test)
                    try? context.save()
                    dismiss()
                }
                .disabled(known == nil || app == nil || name.isEmpty)
            }
            .navigationTitle("Known-Dimension Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
