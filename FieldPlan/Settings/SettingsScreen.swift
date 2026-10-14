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

                Section {
                    Toggle("Keep screen awake while scanning", isOn: Binding(
                        get: { settings.keepScreenAwakeDuringScan },
                        set: { settings.keepScreenAwakeDuringScan = $0 }))
                    Toggle("Record sensor data during scans", isOn: Binding(
                        get: { settings.recordSensorData },
                        set: { settings.recordSensorData = $0 }))
                        .disabled(settings.fieldValidationMode)
                    if settings.sensorRecordingIsForced {
                        Text("Field validation mode is on, so sensor recording stays on. Turn validation mode off to change this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Field validation mode", isOn: Binding(
                        get: { settings.fieldValidationMode },
                        set: { settings.fieldValidationMode = $0 }))
                    Toggle("Show confidence on the plan", isOn: Binding(
                        get: { settings.showConfidenceOnPlan },
                        set: { settings.showConfidenceOnPlan = $0 }))
                    LabeledContent("LiDAR scanning",
                                   value: ScanCapability.isRoomPlanSupported ? "Supported" : "Not available on this device")
                } header: {
                    Text("Scanning")
                } footer: {
                    Text("Sensor data is the LiDAR mesh, camera poses, keyframes and any photos you take while scanning. It stays on this device, gives every wall an evidence score, powers the live coverage map and lets a scan be re-processed later without revisiting the property. Roughly 20–60 MB per property.\n\nField validation mode adds a preflight test, live sensor diagnostics on screen, ground-truth recording against a laser, and an export bundle for analysing accuracy afterwards. It forces sensor recording on, because a validation scan without its evidence cannot be re-processed.")
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

                    // Read the logo once: the property loads it from disk on
                    // every access, and the picker's label closure cannot
                    // reach main-actor state, only this plain flag.
                    let logo = settings.companyLogo
                    let hasLogo = logo != nil
                    HStack {
                        if let logo {
                            Image(uiImage: logo)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 44)
                        }
                        PhotosPicker(selection: $logoPickerItem, matching: .images) {
                            Label(hasLogo ? "Change Logo" : "Add Logo",
                                  systemImage: "photo.badge.plus")
                        }
                        if hasLogo {
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

                Section {
                    let installed = FurnitureLibrary.installedCategories
                    LabeledContent("3D furniture models",
                                   value: installed.isEmpty
                                       ? "None — using built-in shapes"
                                       : "\(installed.count) installed")
                    if !installed.isEmpty {
                        Text(installed.map(\.displayName).sorted().joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("3D Model Library")
                } footer: {
                    Text("Anything without a model is drawn with the built-in shapes. Drop model files into the app's Furniture folder to replace them — see Docs/FURNITURE_MODELS.md.")
                }

                Section("Privacy") {
                    Text("\(AppInfo.appName) stores every project, scan and photo on this device only. No analytics, no ads, no cloud uploads. The one network call is Apple's geocoding service, used only when you tap Use Current Address on a project. Sharing happens only when you export a file yourself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("App", value: AppInfo.appName)
                    LabeledContent("Version", value: AppInfo.versionAndBuild)
                    LabeledContent("Updated", value: AppInfo.releaseDate)
                    Text(AppInfo.releaseNotes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                } footer: {
                    Text("The build number changes with every update. If something looks wrong, quote the version above — it says exactly which build you are running.")
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
