import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import FieldPlanCore

/// Project dashboard: search, filter, sort, create, duplicate, archive,
/// delete, resume last inspection (spec §5).
struct ProjectListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ProjectRecord.updatedAt, order: .reverse) private var allProjects: [ProjectRecord]

    @State private var searchText = ""
    @State private var statusFilter: ProjectStatus? = nil
    @State private var showArchived = false
    @State private var sortMode: SortMode = .updated
    @State private var showNewProject = false
    @State private var showImporter = false
    @State private var errorMessage: String? = nil
    @State private var resumeTarget: ProjectRecord? = nil

    enum SortMode: String, CaseIterable {
        case updated = "Recent"
        case created = "Created"
        case name = "Name"
        case inspection = "Inspection Date"
    }

    private var filtered: [ProjectRecord] {
        var projects = allProjects.filter { $0.isArchived == showArchived }
        if let statusFilter {
            projects = projects.filter { $0.status == statusFilter }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            projects = projects.filter {
                $0.name.lowercased().contains(q)
                    || $0.clientName.lowercased().contains(q)
                    || $0.address.lowercased().contains(q)
            }
        }
        switch sortMode {
        case .updated: return projects.sorted { $0.updatedAt > $1.updatedAt }
        case .created: return projects.sorted { $0.createdAt > $1.createdAt }
        case .name: return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .inspection:
            return projects.sorted {
                ($0.inspectionDate ?? .distantPast) > ($1.inspectionDate ?? .distantPast)
            }
        }
    }

    private var lastOpened: ProjectRecord? {
        allProjects
            .filter { !$0.isArchived && $0.lastOpenedAt != nil }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !showArchived {
                    Section {
                        Button {
                            showNewProject = true
                        } label: {
                            Label("New Project", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(BigButtonStyle())
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)

                        if let last = lastOpened {
                            Button {
                                resumeTarget = last
                            } label: {
                                Label("Resume: \(last.name)", systemImage: "arrow.uturn.forward.circle.fill")
                            }
                            .buttonStyle(BigButtonStyle(prominent: false))
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                    }
                }

                Section(showArchived ? "Archived Projects" : "Projects") {
                    if filtered.isEmpty {
                        ContentUnavailableView(
                            showArchived ? "No Archived Projects" : "No Projects Yet",
                            systemImage: "folder.badge.plus",
                            description: Text(showArchived
                                ? "Archived projects appear here."
                                : "Tap New Project to start an inspection, or load the sample project from Settings."))
                    }
                    ForEach(filtered) { project in
                        NavigationLink(value: project.id) {
                            ProjectRow(project: project)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                delete(project)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                project.isArchived.toggle()
                                saveContext()
                            } label: {
                                Label(project.isArchived ? "Unarchive" : "Archive",
                                      systemImage: "archivebox")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button {
                                duplicate(project)
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Button {
                                project.isArchived.toggle()
                                saveContext()
                            } label: {
                                Label(project.isArchived ? "Unarchive" : "Archive",
                                      systemImage: "archivebox")
                            }
                            Button(role: .destructive) {
                                delete(project)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle(AppInfo.appName)
            .navigationDestination(for: UUID.self) { id in
                if let project = allProjects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project)
                } else {
                    ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
                }
            }
            .navigationDestination(item: $resumeTarget) { project in
                ProjectDetailView(project: project)
            }
            .searchable(text: $searchText, prompt: "Search name, client, address")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortMode) {
                            ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Divider()
                        Picker("Status", selection: $statusFilter) {
                            Text("All Statuses").tag(ProjectStatus?.none)
                            ForEach(ProjectStatus.allCases, id: \.self) { status in
                                Text(status.displayName).tag(ProjectStatus?.some(status))
                            }
                        }
                        Divider()
                        Toggle("Show Archived", isOn: $showArchived)
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import .fieldplan…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Filter & Sort", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showNewProject) {
                ProjectFormView()
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType(filenameExtension: "fieldplan") ?? .zip, .zip]
            ) { result in
                switch result {
                case .success(let url):
                    do {
                        try ProjectStore.shared.importPackage(from: url, context: context)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func delete(_ project: ProjectRecord) {
        ProjectStore.shared.deleteProjectFiles(project.id)
        context.delete(project)
        saveContext()
    }

    private func duplicate(_ project: ProjectRecord) {
        do {
            _ = try ProjectStore.shared.duplicateProject(project, context: context)
        } catch {
            errorMessage = "Duplicate failed: \(error.localizedDescription)"
            AppLog.store.error("Duplicate failed: \(error.localizedDescription)")
        }
    }

    private func saveContext() {
        do {
            try context.save()
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
            AppLog.store.error("Save failed: \(error.localizedDescription)")
        }
    }
}

struct ProjectRow: View {
    let project: ProjectRecord

    var body: some View {
        HStack(spacing: 12) {
            CoverThumb(project: project)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                if !project.clientName.isEmpty || !project.address.isEmpty {
                    Text([project.clientName, project.address].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(project.status.displayName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.statusColor(project.status).opacity(0.18)))
                        .foregroundStyle(AppTheme.statusColor(project.status))
                    Text(project.jobType.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CoverThumb: View {
    let project: ProjectRecord

    var body: some View {
        Group {
            if let coverID = project.coverPhotoID,
               let record = project.photos.first(where: { $0.id == coverID }),
               let image = ProjectStore.shared.loadImage(record, projectID: project.id, thumbnail: true) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "house.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Create/edit project form (spec §5, §6).
struct ProjectFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var existing: ProjectRecord? = nil

    @State private var name = ""
    @State private var clientName = ""
    @State private var address = ""
    @State private var unit = ""
    @State private var jobType: JobType = .fullApartment
    @State private var status: ProjectStatus = .lead
    @State private var hasInspectionDate = true
    @State private var inspectionDate = Date()
    @State private var clientPhone = ""
    @State private var clientEmail = ""
    @State private var notes = ""
    @StateObject private var addressService = LocationAddressService()
    @State private var addressError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Project name", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Job type", selection: $jobType) {
                        ForEach(JobType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(ProjectStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Inspection date", isOn: $hasInspectionDate)
                    if hasInspectionDate {
                        DatePicker("Date", selection: $inspectionDate, displayedComponents: .date)
                    }
                }
                Section("Property") {
                    TextField("Address", text: $address)
                        .textContentType(.fullStreetAddress)
                    Button {
                        addressService.requestAddress { result in
                            switch result {
                            case .success(let found):
                                address = found
                                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                    // Street line makes a natural project name.
                                    name = found.components(separatedBy: ",").first ?? found
                                }
                            case .failure(let error):
                                addressError = error.localizedDescription
                            }
                        }
                    } label: {
                        if addressService.isWorking {
                            HStack {
                                ProgressView()
                                Text("Finding address…")
                            }
                        } else {
                            Label("Use Current Address", systemImage: "location.fill")
                        }
                    }
                    .disabled(addressService.isWorking)
                    TextField("Apartment / unit", text: $unit)
                }
                Section("Client") {
                    TextField("Client name", text: $clientName)
                        .textContentType(.name)
                    TextField("Phone (optional)", text: $clientPhone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    TextField("Email (optional)", text: $clientEmail)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
                Section("Notes") {
                    TextField("Project notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(existing == nil ? "New Project" : "Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
            .alert("Address Lookup", isPresented: .constant(addressError != nil)) {
                Button("OK") { addressError = nil }
            } message: {
                Text(addressError ?? "")
            }
        }
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        clientName = existing.clientName
        address = existing.address
        unit = existing.unit
        jobType = existing.jobType
        status = existing.status
        hasInspectionDate = existing.inspectionDate != nil
        inspectionDate = existing.inspectionDate ?? Date()
        clientPhone = existing.clientPhone
        clientEmail = existing.clientEmail
        notes = existing.notes
    }

    private func save() {
        if let existing {
            existing.name = name
            existing.clientName = clientName
            existing.address = address
            existing.unit = unit
            existing.jobType = jobType
            existing.status = status
            existing.inspectionDate = hasInspectionDate ? inspectionDate : nil
            existing.clientPhone = clientPhone
            existing.clientEmail = clientEmail
            existing.notes = notes
            existing.updatedAt = Date()
        } else {
            let project = ProjectRecord(
                name: name, clientName: clientName, address: address, unit: unit,
                jobType: jobType, status: status,
                inspectionDate: hasInspectionDate ? inspectionDate : nil,
                clientPhone: clientPhone, clientEmail: clientEmail, notes: notes)
            context.insert(project)
        }
        do {
            try context.save()
        } catch {
            AppLog.store.error("Project save failed: \(error.localizedDescription)")
        }
        dismiss()
    }
}
