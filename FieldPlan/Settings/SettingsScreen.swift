import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import FieldPlanCore

/// App settings (spec §13, §35, §47): units & precision, waste defaults,
/// company branding for reports, sample data, and privacy statement.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @StateObject private var settings = SettingsStore.shared

    @State private var logoPickerItem: PhotosPickerItem? = nil
    @State private var sampleMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: Binding(
                        get: { settings.unitSystem },
                        set: { settings.unitSystem = $0 })) {
                        ForEach(UnitSystem.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if settings.unitSystem == .feetInches {
                        Picker("Precision", selection: Binding(
                            get: { settings.precision },
                            set: { settings.precision = $0 })) {
                            ForEach(FractionPrecision.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                    LabeledContent("Example", value: settings.formatter.length(3.8465))
                } header: {
                    Text("Measurement Display")
                } footer: {
                    Text("Display rounding only — stored geometry always keeps full precision.")
                }

                Section("Takeoff Defaults") {
                    Picker("Default waste factor", selection: Binding(
                        get: { settings.defaultWastePercent },
                        set: { settings.defaultWastePercent = $0 })) {
                        ForEach(WasteFactor.standardChoices, id: \.self) { Text("\(Int($0))%").tag($0) }
                    }
                }

                Section("Scanning") {
                    Toggle("Keep screen awake while scanning", isOn: Binding(
                        get: { settings.keepScreenAwakeDuringScan },
                        set: { settings.keepScreenAwakeDuringScan = $0 }))
                    LabeledContent("LiDAR scanning",
                                   value: ScanCapability.isRoomPlanSupported ? "Supported" : "Not available on this device")
                }

                Section("Company Branding (Reports)") {
                    TextField("Company name", text: Binding(
                        get: { settings.companyName }, set: { settings.companyName = $0 }))
                    TextField("Phone", text: Binding(
                        get: { settings.companyPhone }, set: { settings.companyPhone = $0 }))
                        .keyboardType(.phonePad)
                    TextField("Email", text: Binding(
                        get: { settings.companyEmail }, set: { settings.companyEmail = $0 }))
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Website", text: Binding(
                        get: { settings.companyWebsite }, set: { settings.companyWebsite = $0 }))
                        .textInputAutocapitalization(.never)
                    TextField("License #", text: Binding(
                        get: { settings.companyLicense }, set: { settings.companyLicense = $0 }))
                    TextField("Report footer", text: Binding(
                        get: { settings.reportFooter }, set: { settings.reportFooter = $0 }))

                    HStack {
                        if let logo = settings.companyLogo {
                            Image(uiImage: logo)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 44)
                        }
                        PhotosPicker(selection: $logoPickerItem, matching: .images) {
                            Label(settings.companyLogo == nil ? "Add Logo" : "Change Logo",
                                  systemImage: "photo.badge.plus")
                        }
                        if settings.companyLogo != nil {
                            Spacer()
                            Button("Remove", role: .destructive) {
                                settings.setCompanyLogo(nil)
                            }
                        }
                    }
                }

                Section("Report Disclaimer") {
                    TextField("Disclaimer text", text: Binding(
                        get: { settings.reportDisclaimer }, set: { settings.reportDisclaimer = $0 }),
                        axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Button {
                        loadSample()
                    } label: {
                        Label("Load SAMPLE Project", systemImage: "square.grid.3x3.middle.filled")
                    }
                    if let sampleMessage {
                        Text(sampleMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Sample Data")
                } footer: {
                    Text("Creates a clearly-labeled sample one-bedroom apartment so you can explore plans, takeoff and reports without scanning. Sample geometry is never mixed with field measurements.")
                }

                Section("Privacy") {
                    Text("\(AppInfo.appName) stores every project, scan and photo on this device only. No analytics, no ads, no cloud uploads. The one network call is Apple's geocoding service, used only when you tap Use Current Address on a project. Sharing happens only when you export a file yourself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("App", value: AppInfo.appName)
                    LabeledContent("Version", value: AppInfo.version)
                }
            }
            .navigationTitle("Settings")
            .onChange(of: logoPickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        settings.setCompanyLogo(image)
                    }
                    logoPickerItem = nil
                }
            }
        }
    }

    private func loadSample() {
        do {
            let project = try ProjectStore.shared.createSampleProject(context: context)
            sampleMessage = "Created “\(project.name)” — open it from the Projects tab."
        } catch {
            sampleMessage = "Sample creation failed: \(error.localizedDescription)"
            AppLog.store.error("Sample creation failed: \(error.localizedDescription)")
        }
    }
}
