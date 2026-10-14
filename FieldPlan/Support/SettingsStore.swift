import SwiftUI
import UIKit
import FieldPlanCore

/// App-wide user settings, persisted in UserDefaults. Company branding for
/// reports is configurable — nothing contractor-specific is hardcoded
/// (spec §35). The logo image lives as a file; only its presence is tracked.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @AppStorage("unitSystem") private var unitSystemRaw = UnitSystem.feetInches.rawValue
    @AppStorage("fractionPrecision") private var precisionRaw = FractionPrecision.eighth.rawValue
    @AppStorage("defaultWastePercent") var defaultWastePercent = 10.0
    @AppStorage("jobsiteModeDefault") var jobsiteModeDefault = false
    @AppStorage("keepScreenAwakeDuringScan") var keepScreenAwakeDuringScan = true
    /// Keep the sensor stream behind each scan (mesh, poses, keyframes,
    /// photos) so it can be re-processed later and scored for confidence.
    @AppStorage("recordSensorData") private var recordSensorDataRaw = true
    /// Draw low-evidence walls in the warning pen on the plan.
    @AppStorage("showConfidenceOnPlan") var showConfidenceOnPlan = false

    /// Field validation mode: every scan is evidence for measuring how
    /// accurate FieldPlan actually is, so sensor recording is not optional
    /// while it is on. A validation scan without its sensor data is a
    /// property visit that cannot be re-processed — which is the whole point
    /// of collecting it.
    @AppStorage("fieldValidationMode") private var fieldValidationModeRaw = false

    var fieldValidationMode: Bool {
        get { fieldValidationModeRaw }
        set {
            objectWillChange.send()
            fieldValidationModeRaw = newValue
        }
    }

    var recordSensorData: Bool {
        get { fieldValidationModeRaw || recordSensorDataRaw }
        set {
            objectWillChange.send()
            recordSensorDataRaw = newValue
        }
    }

    /// True when recording is on only because validation mode forces it —
    /// the settings screen says so rather than letting the switch look broken.
    var sensorRecordingIsForced: Bool { fieldValidationModeRaw && !recordSensorDataRaw }

    // Company branding (spec §35).
    @AppStorage("companyName") var companyName = ""
    @AppStorage("companyPhone") var companyPhone = ""
    @AppStorage("companyEmail") var companyEmail = ""
    @AppStorage("companyWebsite") var companyWebsite = ""
    @AppStorage("companyLicense") var companyLicense = ""
    @AppStorage("reportFooter") var reportFooter = ""
    @AppStorage("reportDisclaimer") var reportDisclaimer =
        "Dimensions shown were captured with field measurement tools and are provided for estimating purposes. Verify critical dimensions before fabrication or ordering."

    var unitSystem: UnitSystem {
        get { UnitSystem(rawValue: unitSystemRaw) ?? .feetInches }
        set {
            objectWillChange.send()
            unitSystemRaw = newValue.rawValue
        }
    }

    var precision: FractionPrecision {
        get { FractionPrecision(rawValue: precisionRaw) ?? .eighth }
        set {
            objectWillChange.send()
            precisionRaw = newValue.rawValue
        }
    }

    var formatter: UnitFormatter {
        UnitFormatter(system: unitSystem, precision: precision)
    }

    // MARK: - Company logo file

    private var logoURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FieldPlan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("company-logo.png")
    }

    var companyLogo: UIImage? {
        UIImage(contentsOfFile: logoURL.path)
    }

    func setCompanyLogo(_ image: UIImage?) {
        objectWillChange.send()
        if let image, let data = image.pngData() {
            do {
                try data.write(to: logoURL, options: .atomic)
            } catch {
                AppLog.store.error("Failed to save company logo: \(error.localizedDescription)")
            }
        } else {
            try? FileManager.default.removeItem(at: logoURL)
        }
    }
}
