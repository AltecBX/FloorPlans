import ARKit
import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import RoomPlan
import UIKit
import FieldPlanCore

// MARK: - Field validation mode (build 15, priorities 4–7 and 15)
//
// Not a normal feature. This exists so the app can be tested scientifically:
// it forces the evidence recording on, checks the phone is actually able to
// do the walk before the walk starts, shows what the sensors are doing while
// it happens, and exports a bundle that lets the visit be reconstructed
// afterwards.

@MainActor
final class ValidationStore: ObservableObject {
    static let shared = ValidationStore()

    private let store = ProjectStore.shared

    // MARK: Persistence

    private struct Payload: Codable {
        var sessions: [ValidationSession] = []
        var samples: [ValidationSample] = []
        var markers: [ProblemMarker] = []
        var incidents: [FieldValidationBundle.Incident] = []
    }

    private func url(_ projectID: UUID) -> URL {
        store.projectDir(projectID).appendingPathComponent("validation.json")
    }

    private func load(_ projectID: UUID) -> Payload {
        guard let data = try? Data(contentsOf: url(projectID)),
              let payload = try? ProjectArchive.decoder().decode(Payload.self, from: data)
        else { return Payload() }
        return payload
    }

    private func save(_ payload: Payload, _ projectID: UUID) {
        do {
            try ProjectArchive.encoder().encode(payload).write(to: url(projectID), options: .atomic)
        } catch {
            AppLog.store.error("Validation save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sessions(for projectID: UUID) -> [ValidationSession] {
        load(projectID).sessions.sorted { $0.startedAt < $1.startedAt }
    }

    func samples(for projectID: UUID, sessionID: UUID? = nil) -> [ValidationSample] {
        let all = load(projectID).samples
        guard let sessionID else { return all }
        return all.filter { $0.validationSessionID == sessionID }
    }

    func markers(for projectID: UUID) -> [ProblemMarker] { load(projectID).markers }
    func incidents(for projectID: UUID) -> [FieldValidationBundle.Incident] { load(projectID).incidents }

    /// Starts a pass over a property. Sessions are named A, B, C… so repeat
    /// scans of the same building can be told apart and compared.
    @discardableResult
    func startSession(projectID: UUID, notes: String = "") -> ValidationSession {
        var payload = load(projectID)
        let letter = String(UnicodeScalar(65 + min(payload.sessions.count, 25))!)
        let session = ValidationSession(
            projectID: projectID,
            name: "Property Scan \(letter)",
            notes: notes,
            appVersion: AppInfo.version,
            buildNumber: AppInfo.build,
            deviceModel: DeviceInfoProvider.model,
            systemVersion: UIDevice.current.systemVersion)
        payload.sessions.append(session)
        save(payload, projectID)
        return session
    }

    func updateSession(_ session: ValidationSession) {
        var payload = load(session.projectID)
        if let index = payload.sessions.firstIndex(where: { $0.id == session.id }) {
            payload.sessions[index] = session
        }
        save(payload, session.projectID)
    }

    func endSession(_ session: ValidationSession) {
        var updated = session
        updated.endedAt = Date()
        updateSession(updated)
    }

    /// Recording ground truth never edits geometry — it is evidence.
    func addSample(_ sample: ValidationSample, projectID: UUID) {
        var payload = load(projectID)
        payload.samples.removeAll { $0.id == sample.id }
        payload.samples.append(sample)
        save(payload, projectID)
    }

    func deleteSample(_ id: UUID, projectID: UUID) {
        var payload = load(projectID)
        payload.samples.removeAll { $0.id == id }
        save(payload, projectID)
    }

    func addMarker(_ marker: ProblemMarker, projectID: UUID) {
        var payload = load(projectID)
        payload.markers.append(marker)
        save(payload, projectID)
    }

    func recordIncident(_ kind: String, _ detail: String, projectID: UUID) {
        var payload = load(projectID)
        payload.incidents.append(.init(at: Date(), kind: kind, detail: detail))
        save(payload, projectID)
    }

    // MARK: Export

    /// The one export the field visit produces.
    func exportBundle(project: ProjectRecord, snapshot: PlanSnapshot?) throws -> URL {
        let payload = load(project.id)
        var referenced: [FieldValidationBundle.ReferencedFile] = []
        let scansDir = store.scansDir(project.id)
        for scan in project.scans {
            if let raw = scan.rawDataFileName {
                referenced.append(.init(role: "capturedRoomJSON", path: "scans/\(raw)",
                                        byteCount: fileSize(scansDir.appendingPathComponent(raw)),
                                        scanSessionID: scan.sessionID))
            }
            if let usdz = scan.usdzFileName {
                referenced.append(.init(role: "capturedRoomUSDZ", path: "scans/\(usdz)",
                                        byteCount: fileSize(scansDir.appendingPathComponent(usdz)),
                                        scanSessionID: scan.sessionID))
            }
        }
        let checkpoints = ScanCheckpointStore.shared.checkpoints(for: project.id)
        let mapsDir = ScanCheckpointStore.shared.worldMapsDir(project.id)
        let maps = (try? Data(contentsOf: mapsDir.appendingPathComponent("checkpoints.json")))
            .flatMap { try? ProjectArchive.decoder().decode([WorldMapCheckpoint].self, from: $0) } ?? []
        for map in maps {
            referenced.append(.init(role: "arWorldMap", path: "worldmaps/\(map.fileName)",
                                    byteCount: fileSize(mapsDir.appendingPathComponent(map.fileName)),
                                    scanSessionID: map.scanSessionID))
        }

        // Sensor sessions: summaries travel in the manifest, the heavy pose
        // and mesh files stay in the package and are referenced.
        var summaries: [SessionSummary] = []
        var events: [SessionEvent] = []
        for scan in project.scans {
            guard let sessionID = scan.sessionID,
                  let log = try? store.loadSessionLog(projectID: project.id, sessionID: sessionID)
            else { continue }
            if let summary = log.summary { summaries.append(summary) }
            events.append(contentsOf: log.events)
            let dir = store.sessionDir(projectID: project.id, sessionID: sessionID)
            referenced.append(.init(role: "sensorSession", path: "sessions/\(sessionID.uuidString)",
                                    byteCount: store.directorySize(dir), scanSessionID: sessionID))
        }

        let input = FieldValidationBundle.Input(
            project: project.meta,
            environment: environment(),
            validationSessions: payload.sessions,
            samples: payload.samples,
            problemMarkers: payload.markers,
            snapshot: snapshot,
            scanSessionSummaries: summaries,
            worldMapCheckpoints: maps,
            roomCheckpoints: checkpoints,
            incidents: payload.incidents,
            referencedFiles: referenced,
            scanEvents: events,
            formatter: SettingsStore.shared.formatter)

        let entries = try FieldValidationBundle.entries(for: input)
        let name = "\(project.name) validation.zip"
            .replacingOccurrences(of: "/", with: "-")
        let url = store.exportsDir(project.id).appendingPathComponent(name)
        try ZipArchive.write(entries: entries, to: url)
        return url
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    func environment() -> FieldValidationBundle.Environment {
        .init(appVersion: AppInfo.version,
              buildNumber: AppInfo.build,
              deviceModel: DeviceInfoProvider.model,
              systemVersion: UIDevice.current.systemVersion,
              lidarAvailable: DeviceInfoProvider.hasLiDAR)
    }
}

// MARK: - Device facts

enum DeviceInfoProvider {
    /// "iPhone17,2" — the identifier, not the marketing name, because that
    /// is what a later analysis can match against reliably.
    static var model: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static var freeBytes: Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
    static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    static var batteryFraction: Double {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? 1.0 : Double(level)
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Preflight

enum Preflight {

    /// Everything checked before the first scan of a validation walk. Only
    /// genuinely disabling problems block; a missing compass warns, because
    /// RoomPlan works without a north arrow and a walk should not be refused
    /// over one.
    static func run(sensorRecordingEnabled: Bool, sessionDirectory: URL?) -> PreflightReport {
        var checks: [PreflightCheck] = []

        checks.append(PreflightCheck(
            id: "roomplan", title: "RoomPlan",
            status: RoomCaptureSession.isSupported ? .ready : .blocked,
            detail: RoomCaptureSession.isSupported ? "Supported" : "This device cannot run RoomPlan",
            isCritical: true))

        checks.append(PreflightCheck(
            id: "lidar", title: "LiDAR",
            status: DeviceInfoProvider.hasLiDAR ? .ready : .blocked,
            detail: DeviceInfoProvider.hasLiDAR ? "Mesh reconstruction available" : "No LiDAR scanner on this device",
            isCritical: true))

        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        checks.append(PreflightCheck(
            id: "camera", title: "Camera",
            status: camera == .authorized ? .ready : (camera == .notDetermined ? .warning : .blocked),
            detail: camera == .authorized ? "Ready"
                : (camera == .notDetermined ? "Permission not asked yet" : "Permission denied in Settings"),
            isCritical: true))

        let motion = CMMotionActivityManager.isActivityAvailable()
        checks.append(PreflightCheck(
            id: "motion", title: "Motion",
            status: motion ? .ready : .warning,
            detail: motion ? "Ready" : "Motion data unavailable; gyro records will be thin",
            isCritical: false))

        let heading = CLLocationManager().authorizationStatus
        let headingReady = heading == .authorizedWhenInUse || heading == .authorizedAlways
        checks.append(PreflightCheck(
            id: "heading", title: "Compass heading",
            status: headingReady ? .ready : .warning,
            detail: headingReady ? "Ready" : "No location permission — plans will have no north arrow",
            isCritical: false))

        checks.append(PreflightCheck(
            id: "recorder", title: "Sensor recording",
            status: sensorRecordingEnabled ? .ready : .blocked,
            detail: sensorRecordingEnabled ? "On" : "Off — validation needs the evidence stream",
            isCritical: true))

        let free = DeviceInfoProvider.freeBytes
        let gigabytes = Double(free) / 1_000_000_000
        checks.append(PreflightCheck(
            id: "storage", title: "Storage",
            status: free < 2_000_000_000 ? .blocked : (free < 8_000_000_000 ? .warning : .ready),
            detail: String(format: "%.1f GB available", gigabytes),
            isCritical: free < 2_000_000_000))

        let battery = DeviceInfoProvider.batteryFraction
        checks.append(PreflightCheck(
            id: "battery", title: "Battery",
            status: battery < 0.20 ? .warning : .ready,
            detail: "\(Int(battery * 100))%"
                + (DeviceInfoProvider.lowPowerMode ? " · Low Power Mode is on and will throttle the scan" : ""),
            isCritical: false))

        let thermal = DeviceInfoProvider.thermalState
        checks.append(PreflightCheck(
            id: "thermal", title: "Thermal",
            status: thermal == .critical ? .blocked : (thermal == .serious ? .warning : .ready),
            detail: DeviceInfoProvider.thermalName(thermal),
            isCritical: thermal == .critical))

        if let sessionDirectory {
            let writable = FileManager.default.isWritableFilePath(sessionDirectory.path)
            checks.append(PreflightCheck(
                id: "sessiondir", title: "Session folder",
                status: writable ? .ready : .blocked,
                detail: writable ? "Writable" : "Cannot write to the project folder",
                isCritical: true))
        }

        return PreflightReport(checks: checks)
    }
}

private extension FileManager {
    func isWritableFilePath(_ path: String) -> Bool {
        if !fileExists(atPath: path) {
            try? createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        return isWritableFile(atPath: path)
    }
}
