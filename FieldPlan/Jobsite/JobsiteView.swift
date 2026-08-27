import SwiftUI
import SwiftData
import UIKit
import FieldPlanCore

/// Jobsite Mode (spec §45): oversized controls for dusty-glove use — quick
/// photo, quick note, quick measurement, scan, battery and save status.
/// The screen stays awake while open; system settings are restored on exit.
struct JobsiteView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord

    @State private var showCamera = false
    @State private var showNote = false
    @State private var showMeasurement = false
    @State private var showScan = false
    @State private var noteDraft = ""
    @State private var lastAction: String? = nil
    @State private var batteryLevel: Float = -1

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack {
                    Label(batteryText, systemImage: batteryIcon)
                        .font(.subheadline)
                        .foregroundStyle(batteryLevel >= 0 && batteryLevel < 0.2 ? .red : .secondary)
                    Spacer()
                    Label("Saved \(project.updatedAt.formatted(date: .omitted, time: .shortened))",
                          systemImage: "checkmark.icloud")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                if let lastAction {
                    Text(lastAction)
                        .font(.callout)
                        .foregroundStyle(.green)
                }

                Spacer()

                VStack(spacing: 14) {
                    jobsiteButton("Scan Room", icon: "camera.metering.matrix", color: .blue) {
                        showScan = true
                    }
                    jobsiteButton("Quick Photo", icon: "camera.fill", color: .indigo) {
                        showCamera = true
                    }
                    jobsiteButton("Quick Note", icon: "note.text.badge.plus", color: .orange) {
                        showNote = true
                    }
                    jobsiteButton("Quick Measurement", icon: "ruler.fill", color: .teal) {
                        showMeasurement = true
                    }
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Label("Exit Jobsite Mode", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView { image in
                    do {
                        _ = try ProjectStore.shared.savePhoto(image, project: project, context: context)
                        lastAction = "Photo saved"
                    } catch {
                        lastAction = "Photo save failed"
                        AppLog.store.error("Jobsite photo failed: \(error.localizedDescription)")
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showMeasurement) {
                MeasurementFormView(project: project) {
                    lastAction = "Measurement saved"
                }
            }
            .navigationDestination(isPresented: $showScan) {
                ScanFlowView(project: project)
            }
            .alert("Quick Note", isPresented: $showNote) {
                TextField("Note", text: $noteDraft)
                Button("Save") {
                    let trimmed = noteDraft.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        let note = NoteRecord(text: trimmed)
                        note.project = project
                        context.insert(note)
                        try? context.save()
                        lastAction = "Note saved"
                    }
                    noteDraft = ""
                }
                Button("Cancel", role: .cancel) { noteDraft = "" }
            }
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = true
                batteryLevel = UIDevice.current.batteryLevel
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private func jobsiteButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title)
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(RoundedRectangle(cornerRadius: 18).fill(color.opacity(0.16)))
            .foregroundStyle(color)
        }
        .accessibilityLabel(title)
    }

    private var batteryText: String {
        batteryLevel < 0 ? "Battery —" : "Battery \(Int(batteryLevel * 100))%"
    }

    private var batteryIcon: String {
        if batteryLevel < 0 { return "battery.50percent" }
        if batteryLevel < 0.2 { return "battery.25percent" }
        if batteryLevel < 0.6 { return "battery.50percent" }
        return "battery.100percent"
    }
}
