import SwiftUI
import SwiftData
import FieldPlanCore

/// Report configuration + generation + share (spec §35).
struct ReportScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord

    @State private var options = ReportOptions()
    @State private var generating = false
    @State private var reportURL: URL? = nil
    @State private var showPreview = false
    @State private var errorMessage: String? = nil

    var body: some View {
        Form {
            Section("Sections") {
                Toggle("Cover Page", isOn: $options.includeCover)
                Toggle("Project Information", isOn: $options.includeProjectInfo)
                Toggle("Existing Conditions Plan", isOn: $options.includeExistingPlan)
                Toggle("Proposed Plan", isOn: $options.includeProposedPlan)
                Toggle("Demolition Plan", isOn: $options.includeDemolitionPlan)
                Toggle("Room Schedule", isOn: $options.includeRoomSchedule)
                Toggle("Measurement Schedule", isOn: $options.includeMeasurements)
                Toggle("Quantity Takeoff", isOn: $options.includeTakeoff)
                Toggle("Photos", isOn: $options.includePhotos)
                Toggle("Field Notes", isOn: $options.includeNotes)
                Toggle("Verification Summary", isOn: $options.includeVerification)
                Toggle("Disclaimer", isOn: $options.includeDisclaimer)
            }
            Section("Plan Options") {
                Toggle("Dimensions on plans", isOn: $options.planDimensions)
                Toggle("Furniture on plans", isOn: $options.planFurniture)
                Toggle("3D dollhouse with each plan", isOn: $options.include3D)
            }
            Section {
                Button {
                    generate()
                } label: {
                    if generating {
                        HStack {
                            ProgressView()
                            Text("Generating…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Generate PDF Report", systemImage: "doc.richtext")
                            .frame(maxWidth: .infinity)
                    }
                }
                .font(.headline)
                .disabled(generating)

                if let reportURL {
                    Button {
                        showPreview = true
                    } label: {
                        Label("Preview Report", systemImage: "eye")
                    }
                    ShareLink(item: reportURL) {
                        Label("Share Report", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("Company branding on the report is configured in Settings.")
            }
        }
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPreview) {
            if let reportURL {
                QuickLookPreview(url: reportURL)
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func generate() {
        generating = true
        do {
            let snapshot = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            let safeName = project.name.replacingOccurrences(of: "/", with: "-")
            let url = ProjectStore.shared.exportsDir(project.id)
                .appendingPathComponent("\(safeName) Report.pdf")
            _ = try ReportBuilder.generate(
                project: project, snapshot: snapshot, options: options, outputURL: url)
            reportURL = url
            showPreview = true
        } catch {
            errorMessage = "Report generation failed: \(error.localizedDescription)"
            AppLog.export.error("Report failed: \(error.localizedDescription)")
        }
        generating = false
    }
}
