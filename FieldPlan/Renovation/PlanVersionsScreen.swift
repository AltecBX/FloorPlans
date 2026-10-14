import SwiftUI
import SwiftData
import FieldPlanCore

/// Plan versions (spec §22–§23): the Existing Conditions baseline plus
/// proposed renovation plans duplicated from it. Locking the baseline makes
/// it immutable; renovation edits happen only on duplicates.
struct PlanVersionsScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @State private var showDuplicateSheet: SnapshotRecord? = nil
    @State private var duplicateName = ""
    @State private var errorMessage: String? = nil

    private var sortedSnapshots: [SnapshotRecord] {
        project.snapshots.sorted { a, b in
            if a.kind != b.kind { return a.kind == .existingConditions }
            return a.createdAt < b.createdAt
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(sortedSnapshots) { record in
                    HStack(spacing: 12) {
                        Image(systemName: record.kind == .existingConditions
                            ? (record.isLocked ? "lock.square.stack.fill" : "square.stack.3d.up.fill")
                            : "square.stack.3d.up.badge.a")
                            .foregroundStyle(record.kind == .existingConditions ? Color.indigo : Color.blue)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name).font(.headline)
                            HStack(spacing: 6) {
                                Text(record.kind.displayName)
                                if record.isLocked {
                                    Label("Locked", systemImage: "lock.fill")
                                }
                                if record.id == project.activeSnapshotID {
                                    Text("Active")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if record.id != project.activeSnapshotID {
                            Button("Open") {
                                project.activeSnapshotID = record.id
                                try? context.save()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if record.kind == .proposed {
                            Button(role: .destructive) {
                                delete(record)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Button {
                            showDuplicateSheet = record
                            duplicateName = suggestedName(for: record)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .tint(.blue)
                        if record.kind == .existingConditions {
                            Button {
                                record.isLocked.toggle()
                                syncLock(record)
                            } label: {
                                Label(record.isLocked ? "Unlock" : "Lock",
                                      systemImage: record.isLocked ? "lock.open" : "lock")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            } header: {
                Text("Plan Versions")
            } footer: {
                Text("Existing Conditions is the scanned baseline — lock it once the survey is corrected. Duplicate it to design the proposed renovation; mark walls, doors and fixtures as Demolish or New in the plan editor, then view the Demolition and Proposed plans from the Floor Plan screen.")
            }

            Section {
                Button {
                    ensureBaselineAndDuplicate()
                } label: {
                    Label("Create Proposed Plan from Existing", systemImage: "plus.square.on.square.fill")
                }
            }
        }
        .navigationTitle("Plan Versions")
        .onAppear {
            // Ensure the baseline exists even before any scan.
            _ = try? ProjectStore.shared.existingConditions(for: project, context: context)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $showDuplicateSheet) { source in
            NavigationStack {
                Form {
                    TextField("New plan name", text: $duplicateName)
                    Button("Duplicate") {
                        duplicate(source, name: duplicateName)
                        showDuplicateSheet = nil
                    }
                    .disabled(duplicateName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .navigationTitle("Duplicate Plan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showDuplicateSheet = nil }
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
    }

    private func suggestedName(for record: SnapshotRecord) -> String {
        let proposedCount = project.snapshots.filter { $0.kind == .proposed }.count
        return proposedCount == 0 ? "Proposed Plan" : "Proposed Plan \(proposedCount + 1)"
    }

    private func ensureBaselineAndDuplicate() {
        do {
            _ = try ProjectStore.shared.existingConditions(for: project, context: context)
            if let baseline = project.snapshots.first(where: { $0.kind == .existingConditions }) {
                showDuplicateSheet = baseline
                duplicateName = suggestedName(for: baseline)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicate(_ record: SnapshotRecord, name: String) {
        do {
            let source = try ProjectStore.shared.loadSnapshot(projectID: project.id, snapshotID: record.id)
            let copy = try ProjectStore.shared.duplicateSnapshot(
                source, named: name, project: project, context: context)
            project.activeSnapshotID = copy.id
            project.updatedAt = Date()
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ record: SnapshotRecord) {
        ProjectStore.shared.deleteSnapshotFile(projectID: project.id, snapshotID: record.id)
        if project.activeSnapshotID == record.id {
            project.activeSnapshotID = project.snapshots.first(where: { $0.kind == .existingConditions })?.id
        }
        context.delete(record)
        try? context.save()
    }

    private func syncLock(_ record: SnapshotRecord) {
        do {
            var snapshot = try ProjectStore.shared.loadSnapshot(projectID: project.id, snapshotID: record.id)
            snapshot.isLocked = record.isLocked
            try ProjectStore.shared.saveSnapshot(snapshot, projectID: project.id)
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
