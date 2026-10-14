import SwiftUI
import SwiftData
import FieldPlanCore

/// Manual measurement hub (spec §18): dedicated measurements with categories,
/// kinds, provenance, verification status and critical flags. Templates
/// (spec §60) pre-fill common bathroom/kitchen/flooring/painting checklists.
struct MeasurementsScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord
    var roomFilter: UUID? = nil
    var roomName: String? = nil

    @State private var showForm = false
    @State private var editTarget: MeasurementRecord? = nil
    @State private var showTemplates = false
    @State private var filterCritical = false
    @State private var filterUnverified = false

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    private var records: [MeasurementRecord] {
        project.measurements
            .filter { roomFilter == nil || $0.roomID == roomFilter }
            .filter { !filterCritical || $0.isCritical }
            .filter { !filterUnverified || $0.verificationRaw == VerificationStatus.unverified.rawValue }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            summarySection
            Section {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No Measurements",
                        systemImage: "ruler",
                        description: Text("Add individual measurements or start from a template."))
                }
                ForEach(records) { record in
                    Button {
                        editTarget = record
                    } label: {
                        MeasurementRow(record: record, formatter: formatter)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            context.delete(record)
                            try? context.save()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            record.verificationRaw = VerificationStatus.fieldChecked.rawValue
                            try? context.save()
                        } label: {
                            Label("Field Checked", systemImage: "checkmark")
                        }
                        .tint(.blue)
                        Button {
                            record.verificationRaw = VerificationStatus.laserVerified.rawValue
                            record.sourceRaw = MeasurementSource.laserVerified.rawValue
                            try? context.save()
                        } label: {
                            Label("Laser Verified", systemImage: "scope")
                        }
                        .tint(.green)
                    }
                }
            }
        }
        .navigationTitle(roomName.map { "\($0) Measurements" } ?? "Measurements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Toggle("Critical Only", isOn: $filterCritical)
                    Toggle("Unverified Only", isOn: $filterUnverified)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter measurements")
                Button {
                    showTemplates = true
                } label: {
                    Image(systemName: "list.clipboard")
                }
                .accessibilityLabel("Measurement templates")
                Button {
                    showForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add measurement")
            }
        }
        .sheet(isPresented: $showForm) {
            MeasurementFormView(project: project, roomID: roomFilter)
        }
        .sheet(item: $editTarget) { record in
            MeasurementFormView(project: project, roomID: roomFilter, existing: record)
        }
        .sheet(isPresented: $showTemplates) {
            TemplateRunnerView(project: project, roomID: roomFilter)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        let all = project.measurements.filter { roomFilter == nil || $0.roomID == roomFilter }
        let critical = all.filter(\.isCritical)
        let unverifiedCritical = critical.filter { $0.verificationRaw == VerificationStatus.unverified.rawValue }
        if !all.isEmpty {
            Section {
                StatRow(label: "Total", value: "\(all.count)")
                StatRow(label: "Critical", value: "\(critical.count)")
                if !unverifiedCritical.isEmpty {
                    StatRow(label: "⚠ Critical Unverified", value: "\(unverifiedCritical.count)")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct MeasurementRow: View {
    let record: MeasurementRecord
    let formatter: UnitFormatter

    var body: some View {
        let model = record.model
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if model.isCritical {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    Text(model.name).font(.headline)
                }
                Text("\(model.category.displayName) · \(model.kind.displayName) · \(model.source.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let original = model.originalValue {
                    Text("Original: \(model.kind.isArea ? formatter.area(original) : formatter.length(original))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(model.formattedValue(formatter))
                    .font(.body.weight(.semibold).monospacedDigit())
                Text(model.verification.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppTheme.verificationColor(model.verification).opacity(0.15)))
                    .foregroundStyle(AppTheme.verificationColor(model.verification))
            }
        }
    }
}

/// Add/edit measurement form. Editing preserves the original value (spec §12).
struct MeasurementFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    var roomID: UUID? = nil
    var existing: MeasurementRecord? = nil
    var prefill: MeasurementPrompt? = nil
    var onSaved: (() -> Void)? = nil

    @State private var name = ""
    @State private var category: MeasurementCategory = .custom
    @State private var kind: MeasurementKind = .length
    @State private var meters: Double? = nil
    @State private var areaText = ""
    @State private var source: MeasurementSource = .manualEntry
    @State private var verification: VerificationStatus = .unverified
    @State private var isCritical = false
    @State private var notes = ""

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    private var isValid: Bool {
        if kind.isArea {
            return Double(areaText) != nil && !name.isEmpty
        }
        return meters != nil && !name.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    TextField("Name (e.g. Tub Length)", text: $name)
                    Picker("Category", selection: $category) {
                        ForEach(MeasurementCategory.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Picker("Type", selection: $kind) {
                        ForEach(MeasurementKind.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
                Section("Value") {
                    if kind.isArea {
                        HStack {
                            TextField("Area", text: $areaText)
                                .keyboardType(.decimalPad)
                            Text("sq ft")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        DimensionField(label: "Measurement", meters: $meters, formatter: formatter)
                    }
                    if let existingOriginal = existing?.originalValue {
                        LabeledContent("Original value",
                                       value: formatter.length(existingOriginal))
                    }
                }
                Section("Provenance") {
                    Picker("Source", selection: $source) {
                        ForEach([MeasurementSource.manualEntry, .laserVerified, .arMeasured, .calculated], id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Picker("Verification", selection: $verification) {
                        ForEach(VerificationStatus.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Toggle("Critical dimension", isOn: $isCritical)
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(existing == nil ? "New Measurement" : "Edit Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear(perform: load)
            .onChange(of: category) { _, newCategory in
                if existing == nil && !isCritical {
                    isCritical = newCategory.isTypicallyCritical
                }
            }
        }
    }

    private func load() {
        if let existing {
            let model = existing.model
            name = model.name
            category = model.category
            kind = model.kind
            if model.kind.isArea {
                areaText = String(format: "%.1f", model.value / UnitConstants.squareMetersPerSquareFoot)
            } else {
                meters = model.value
            }
            source = model.source
            verification = model.verification
            isCritical = model.isCritical
            notes = model.notes
        } else if let prefill {
            name = prefill.name
            category = prefill.category
            kind = prefill.kind
            isCritical = prefill.isCritical
        }
    }

    private func save() {
        let value: Double
        if kind.isArea {
            value = (Double(areaText) ?? 0) * UnitConstants.squareMetersPerSquareFoot
        } else {
            value = meters ?? 0
        }

        if let existing {
            if abs(existing.value - value) > 1e-12 {
                existing.applyEdit(newValue: value, source: source == existing.model.source ? .edited : source)
            }
            var model = existing.model
            model.name = name
            model.category = category
            model.kind = kind
            model.verification = verification
            model.isCritical = isCritical
            model.notes = notes
            existing.apply(model)
        } else {
            let model = FieldMeasurementModel(
                name: name, category: category, kind: kind, value: value,
                source: source, verification: verification, isCritical: isCritical,
                notes: notes, roomID: roomID)
            let record = MeasurementRecord(model: model)
            record.project = project
            context.insert(record)
        }
        project.updatedAt = Date()
        do {
            try context.save()
        } catch {
            AppLog.store.error("Measurement save failed: \(error.localizedDescription)")
        }
        onSaved?()
        dismiss()
    }
}

/// Walks a template's prompts one by one; skipping is always allowed
/// (spec §60: never force fields you don't need).
struct TemplateRunnerView: View {
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    var roomID: UUID? = nil

    @State private var selectedTemplate: MeasurementTemplate? = nil
    @State private var promptIndex = 0
    @State private var showPromptForm = false

    var body: some View {
        NavigationStack {
            List {
                if let template = selectedTemplate {
                    Section("\(template.name) — \(promptIndex)/\(template.prompts.count) done") {
                        ForEach(Array(template.prompts.enumerated()), id: \.element.id) { index, prompt in
                            HStack {
                                Image(systemName: index < promptIndex ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(index < promptIndex ? .green : .secondary)
                                Text(prompt.name)
                                if prompt.isCritical {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                }
                                Spacer()
                            }
                        }
                    }
                    Section {
                        if promptIndex < template.prompts.count {
                            Button {
                                showPromptForm = true
                            } label: {
                                Label("Measure: \(template.prompts[promptIndex].name)",
                                      systemImage: "ruler")
                            }
                            .font(.headline)
                            Button("Skip This One") {
                                promptIndex += 1
                            }
                        } else {
                            Label("Template complete", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }
                } else {
                    Section("Choose a Template") {
                        ForEach(MeasurementTemplates.all) { template in
                            Button {
                                selectedTemplate = template
                                promptIndex = 0
                            } label: {
                                HStack {
                                    Text(template.name)
                                    Spacer()
                                    Text("\(template.prompts.count) items")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPromptForm) {
                if let template = selectedTemplate, promptIndex < template.prompts.count {
                    MeasurementFormView(
                        project: project,
                        roomID: roomID,
                        prefill: template.prompts[promptIndex],
                        onSaved: { promptIndex += 1 })
                }
            }
        }
    }
}
