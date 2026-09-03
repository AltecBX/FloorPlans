import Foundation

// MARK: - Field validation bundle (build 15)
//
// One zip that lets a later analysis pass reproduce exactly what the app
// knew while standing in the property: every method's measurement beside the
// laser value, the evidence each element carried, what the sensors and the
// tracker were doing, and what went wrong. Large binaries already inside the
// .fieldplan package are referenced by path rather than copied twice; the
// manifest says where each one lives.

public enum FieldValidationBundle {

    /// Identifies the app and phone that produced the data. Two visits with
    /// different iOS versions are not the same experiment.
    public struct Environment: Codable, Hashable, Sendable {
        public var appVersion: String
        public var buildNumber: String
        public var deviceModel: String
        public var systemVersion: String
        public var lidarAvailable: Bool

        public init(
            appVersion: String = "",
            buildNumber: String = "",
            deviceModel: String = "",
            systemVersion: String = "",
            lidarAvailable: Bool = true
        ) {
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.deviceModel = deviceModel
            self.systemVersion = systemVersion
            self.lidarAvailable = lidarAvailable
        }
    }

    /// A file that lives in the project package rather than in this bundle,
    /// so a multi-gigabyte mesh is not written twice.
    public struct ReferencedFile: Codable, Hashable, Sendable {
        public var role: String
        public var path: String
        public var byteCount: Int64?
        public var scanSessionID: UUID?

        public init(role: String, path: String, byteCount: Int64? = nil, scanSessionID: UUID? = nil) {
            self.role = role
            self.path = path
            self.byteCount = byteCount
            self.scanSessionID = scanSessionID
        }
    }

    /// Something that went wrong during the walk and may explain an error:
    /// a thermal throttle, a storage warning, a tracking loss.
    public struct Incident: Codable, Hashable, Sendable {
        public var at: Date
        public var kind: String
        public var detail: String

        public init(at: Date, kind: String, detail: String) {
            self.at = at
            self.kind = kind
            self.detail = detail
        }
    }

    public struct Manifest: Codable, Sendable {
        public var formatVersion: Int
        public var exportedAt: Date
        public var environment: Environment
        public var project: ProjectMeta
        public var validationSessions: [ValidationSession]
        public var sampleCount: Int
        public var problemMarkerCount: Int
        public var scanSessionSummaries: [SessionSummary]
        public var worldMapCheckpoints: [WorldMapCheckpoint]
        public var roomCheckpoints: [RoomCheckpoint]
        public var incidents: [Incident]
        public var referencedFiles: [ReferencedFile]
        /// Written so a reader knows the numbers were never arbitrated.
        public var notes: [String]
    }

    /// Everything the bundle is built from. The app gathers it; this stays
    /// pure so it can be tested without a device.
    public struct Input: Sendable {
        public var project: ProjectMeta
        public var environment: Environment
        public var validationSessions: [ValidationSession]
        public var samples: [ValidationSample]
        public var problemMarkers: [ProblemMarker]
        public var snapshot: PlanSnapshot?
        public var scanSessionSummaries: [SessionSummary]
        public var worldMapCheckpoints: [WorldMapCheckpoint]
        public var roomCheckpoints: [RoomCheckpoint]
        public var incidents: [Incident]
        public var referencedFiles: [ReferencedFile]
        public var scanEvents: [SessionEvent]
        public var formatter: UnitFormatter

        public init(
            project: ProjectMeta,
            environment: Environment = Environment(),
            validationSessions: [ValidationSession] = [],
            samples: [ValidationSample] = [],
            problemMarkers: [ProblemMarker] = [],
            snapshot: PlanSnapshot? = nil,
            scanSessionSummaries: [SessionSummary] = [],
            worldMapCheckpoints: [WorldMapCheckpoint] = [],
            roomCheckpoints: [RoomCheckpoint] = [],
            incidents: [Incident] = [],
            referencedFiles: [ReferencedFile] = [],
            scanEvents: [SessionEvent] = [],
            formatter: UnitFormatter = UnitFormatter()
        ) {
            self.project = project
            self.environment = environment
            self.validationSessions = validationSessions
            self.samples = samples
            self.problemMarkers = problemMarkers
            self.snapshot = snapshot
            self.scanSessionSummaries = scanSessionSummaries
            self.worldMapCheckpoints = worldMapCheckpoints
            self.roomCheckpoints = roomCheckpoints
            self.incidents = incidents
            self.referencedFiles = referencedFiles
            self.scanEvents = scanEvents
            self.formatter = formatter
        }
    }

    /// What the data says, computed at export so the numbers travel with it.
    public struct Analysis: Codable, Sendable {
        public var bySource: [ValidationAnalysis.SourceAccuracy]
        public var byKind: [String: [ValidationAnalysis.SourceAccuracy]]
        public var headToHead: [ValidationAnalysis.HeadToHead]
        public var repeatability: [ValidationAnalysis.RepeatabilitySpread]
        public var confidenceCalibration: [ValidationAnalysis.CalibrationBucket]
        public var progress: ValidationProgress
    }

    public static func analysis(for input: Input) -> Analysis {
        let samples = input.samples
        var byKind: [String: [ValidationAnalysis.SourceAccuracy]] = [:]
        for kind in AccuracyMeasureKind.allCases {
            let scoped = ValidationAnalysis.compareSources(samples, kind: kind)
            if !scoped.isEmpty { byKind[kind.rawValue] = scoped }
        }
        var pairs: [ValidationAnalysis.HeadToHead] = []
        let methods = MeasurementMethod.allCases
        for i in methods.indices {
            for j in methods.indices where j > i {
                if let pair = ValidationAnalysis.headToHead(samples, methods[i], methods[j]) {
                    pairs.append(pair)
                }
            }
        }
        return Analysis(
            bySource: ValidationAnalysis.compareSources(samples),
            byKind: byKind,
            headToHead: pairs,
            repeatability: ValidationAnalysis.repeatability(samples),
            confidenceCalibration: ValidationAnalysis.confidenceCalibration(samples),
            progress: ValidationProgress.compute(
                levels: input.snapshot?.levels ?? [],
                samples: samples,
                problemMarkers: input.problemMarkers))
    }

    /// The files that make up the bundle, ready for `ZipArchive.write`.
    public static func entries(for input: Input) throws -> [ZipEntry] {
        let encoder = ProjectArchive.encoder()
        var entries: [ZipEntry] = []

        let manifest = Manifest(
            formatVersion: 1,
            exportedAt: Date(),
            environment: input.environment,
            project: input.project,
            validationSessions: input.validationSessions,
            sampleCount: input.samples.count,
            problemMarkerCount: input.problemMarkers.count,
            scanSessionSummaries: input.scanSessionSummaries,
            worldMapCheckpoints: input.worldMapCheckpoints,
            roomCheckpoints: input.roomCheckpoints,
            incidents: input.incidents,
            referencedFiles: input.referencedFiles,
            notes: [
                "Every method's measurement is recorded as captured. Nothing here is averaged, arbitrated or corrected.",
                "An absent measurement means the method produced no answer for that element — it is not a zero.",
                "Ground truth is evidence, not an edit: recording a sample never changed the plan.",
            ])
        entries.append(ZipEntry(path: "manifest.json", data: try encoder.encode(manifest)))
        entries.append(ZipEntry(path: "validation-samples.json", data: try encoder.encode(input.samples)))
        entries.append(ZipEntry(path: "validation-samples.csv", data: Data(groundTruthCSV(input.samples).utf8)))
        entries.append(ZipEntry(path: "analysis.json", data: try encoder.encode(analysis(for: input))))
        if !input.problemMarkers.isEmpty {
            entries.append(ZipEntry(path: "problem-markers.json", data: try encoder.encode(input.problemMarkers)))
        }
        if !input.scanEvents.isEmpty {
            entries.append(ZipEntry(path: "scan-events.json", data: try encoder.encode(input.scanEvents)))
        }
        if let snapshot = input.snapshot {
            entries.append(ZipEntry(path: "canonical-snapshot.json", data: try encoder.encode(snapshot)))
            entries.append(ZipEntry(
                path: "room-schedule.csv",
                data: Data(CSVExporter.roomSchedule(levels: snapshot.levels, formatter: input.formatter).utf8)))
        }
        entries.append(ZipEntry(path: "README.txt", data: Data(readme(input).utf8)))
        return entries
    }

    // MARK: The ground-truth table

    /// One row per sample, every method side by side with its error. This is
    /// the table the algorithm decision will eventually be made from, so it
    /// carries full precision rather than formatted values.
    public static func groundTruthCSV(_ samples: [ValidationSample]) -> String {
        var out = CSVExporter.row([
            "sample_id", "validation_session", "recorded_at", "scan_session",
            "level", "room", "element_id", "kind", "label", "physical_element_key",
            "ground_truth_m", "ground_truth_method", "note",
            "canonical_m", "roomplan_m", "mesh_fit_m", "mesh_residual_m", "mesh_inliers",
            "original_scanned_m", "user_edited_m",
            "error_canonical_m", "error_roomplan_m", "error_mesh_fit_m",
            "percent_error_canonical", "percent_error_roomplan", "percent_error_mesh_fit",
            "evidence_confidence", "coverage", "capture_confidence",
            "tracking_quality", "observations", "thickness_source",
        ])
        let stamp = ISO8601DateFormatter()
        func number(_ value: Double?) -> String {
            guard let value else { return "" }
            return String(format: "%.6f", value)
        }
        for sample in samples.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            out += CSVExporter.row([
                sample.id.uuidString,
                sample.validationSessionID.uuidString,
                stamp.string(from: sample.recordedAt),
                sample.scanSessionID?.uuidString ?? "",
                sample.levelName,
                sample.roomName,
                sample.elementID?.uuidString ?? "",
                sample.kind.rawValue,
                sample.elementLabel,
                sample.physicalElementKey ?? "",
                number(sample.groundTruth),
                sample.method.rawValue,
                sample.note,
                number(sample.measurements.canonical),
                number(sample.measurements.roomPlan),
                number(sample.measurements.meshFit),
                number(sample.measurements.meshResidual),
                sample.measurements.meshInlierCount.map(String.init) ?? "",
                number(sample.measurements.originalScanned),
                number(sample.measurements.userEdited),
                number(sample.error(for: .canonical)),
                number(sample.error(for: .roomPlan)),
                number(sample.error(for: .meshFit)),
                number(sample.percentError(for: .canonical)),
                number(sample.percentError(for: .roomPlan)),
                number(sample.percentError(for: .meshFit)),
                number(sample.evidence.confidence),
                number(sample.evidence.coverage),
                sample.evidence.captureConfidence?.rawValue ?? "",
                number(sample.evidence.trackingQuality),
                sample.evidence.observationCount.map(String.init) ?? "",
                sample.evidence.thicknessSource?.rawValue ?? "",
            ])
        }
        return out
    }

    static func readme(_ input: Input) -> String {
        let analysis = analysis(for: input)
        var lines: [String] = [
            "FieldPlan validation bundle",
            "",
            "Property: \(input.project.name)",
            "Exported: \(ISO8601DateFormatter().string(from: Date()))",
            "App \(input.environment.appVersion) (\(input.environment.buildNumber)) on \(input.environment.deviceModel), iOS \(input.environment.systemVersion)",
            "",
            "Ground-truth samples: \(input.samples.count)",
            "Problem markers: \(input.problemMarkers.count)",
            "Scan sessions: \(input.scanSessionSummaries.count)",
            "World map checkpoints: \(input.worldMapCheckpoints.count)",
            "",
            "Files",
            "  manifest.json             what produced this, and where the large files live",
            "  validation-samples.csv    one row per sample, every method beside the laser value",
            "  validation-samples.json   the same data at full precision",
            "  analysis.json             per-method error, head-to-head, repeatability, calibration",
            "  canonical-snapshot.json   the plan as it stood at export",
            "",
            "How to read it",
            "  A blank measurement column means that method produced no answer for",
            "  that element. It is not a zero and must not be treated as one.",
            "  Errors are signed: positive means the method read longer than the laser.",
            "",
        ]
        if analysis.bySource.isEmpty {
            lines.append("No samples yet, so no method has been measured.")
        } else {
            lines.append("Mean absolute error by method (over the samples each answered):")
            for entry in analysis.bySource.sorted(by: { $0.statistics.meanAbsoluteError < $1.statistics.meanAbsoluteError }) {
                let mm = entry.statistics.meanAbsoluteError * 1000
                lines.append(String(
                    format: "  %-22@ %7.1f mm   n=%d, no answer on %d",
                    entry.source.displayName as NSString, mm,
                    entry.sampleCount, entry.missingCount))
            }
            lines.append("")
            lines.append("This ordering is a reading of the data, not a decision. No method")
            lines.append("has been promoted in the app; the geometry is unchanged.")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
