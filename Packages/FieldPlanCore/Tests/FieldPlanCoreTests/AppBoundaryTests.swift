import XCTest
@testable import FieldPlanCore

/// A compile fence for the app→core boundary.
///
/// The iOS layer cannot be compiled in this repository's CI environment
/// (no Xcode, no iOS SDK), so a wrong argument label or type in a call from
/// `FieldPlan/` into `FieldPlanCore` used to surface only on the owner's Mac,
/// a build cycle later. This mirrors those calls — the same labels, the same
/// types the app binds them to — so the mistake fails here instead.
///
/// It asserts almost nothing about behaviour on purpose: the other suites do
/// that. When the app starts calling something new, add the call here.
final class AppBoundaryTests: XCTestCase {

    func testCallsTheAppMakes() throws {
        var level = SampleFixtures.apartment()
        level.elevation = 0
        let levels = [level]
        let formatter = UnitFormatter()

        // ProjectStore.loadSnapshot / existingConditions
        let snapshot = PlanSnapshot(
            name: "Existing Conditions", kind: .existingConditions, isLocked: false,
            levels: [LevelGeometry(name: "First Floor", storyIndex: 0)],
            schemaVersion: GeometryMigration.currentSchemaVersion)
        let migrated = GeometryMigration.migrate(snapshot)
        let version: Int = migrated.schemaVersion ?? GeometryMigration.currentSchemaVersion
        XCTAssertEqual(version, GeometryMigration.currentSchemaVersion)

        // ScanFlowView.finishLevel
        let dtos: [ScannedRoomDTO] = []
        let groups = LevelAssignment.groupByFloor(dtos)
        for group in groups {
            let _: Double = group.elevation
            let _: [ScannedRoomDTO] = group.rooms
        }
        if let assignment = LevelAssignment.assign(
            elevation: 0, selectedLevelID: level.id, levels: levels) {
            let _: UUID = assignment.levelID
            let _: LevelGeometry? = assignment.createdLevel
            let _: String? = assignment.message
        }
        let chunks: [MeshChunk] = []
        let poses: [PoseSample] = []
        let grid = CoverageGrid.build(chunks: chunks, poses: poses, floorElevation: 0)
        let scored = EvidenceAttachment.attach(
            to: level, grid: grid, chunks: chunks,
            trackingNormalFraction: 0.9, sessionID: UUID())
        XCTAssertEqual(scored.rooms.count, level.rooms.count)
        let conversion = ScanConversion.convert(rooms: dtos)
        _ = ScanConversion.merge(conversion, into: level)
        _ = NorthEstimator.northAngle(from: [])
        _ = MissingSpaceDetector.findings(for: level, levels: levels)

        // LevelsManagerView: Align Below
        if let aligned = LevelRegistration.alignByStairs(level, to: level)
            ?? LevelRegistration.alignByFootprint(level, to: level) {
            let _: LevelGeometry = aligned.level
            let _: Double = aligned.shift.length
        }

        // PlanEditorScreen: rotate level, wall thickness, door style
        let pivot = level.bounds.isNull ? Vec2.zero : level.bounds.center
        _ = LevelRegistration.rotated(level, by: .pi / 2, about: pivot)
        if let wall = level.walls.first {
            _ = EditorEngine.setWallThickness(in: level, wallID: wall.id, thickness: 0.1524)
            let _: String? = wall.thicknessSource?.displayName
        }
        for style in DoorStyle.allCases { let _: String = style.displayName }
        if let opening = level.walls.first(where: { !$0.openings.isEmpty })?.openings.first {
            let _: DoorStyle = opening.resolvedStyle
        }

        // ManualRoomView: centerlines outside the typed clear size
        _ = GeometryOps.insetPolygon([Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)], by: -0.05715)

        // RoomDetailView / TakeoffScreen: quantities
        let q = ContractorQuantities.compute(room: level.rooms[0], in: level)
        let _: String = formatter.area(q.paintableWallArea)
        let _: String = formatter.area(q.wallTileArea)
        let _: String = formatter.area(q.wainscotArea)
        let _: String = formatter.volume(q.volume)
        let _: Int = q.fixtureTotal
        let _: String = q.fixtureSummary
        let summary = ContractorSummary.compute(levels: levels)
        let _: String = formatter.area(summary.floorArea)
        let _: String = formatter.area(summary.paintableWallArea)
        let _: String = formatter.area(summary.ceilingArea)
        let _: String = formatter.area(summary.wetWallTileArea)
        let _: String = formatter.linearFeet(summary.baseboardLength)
        let _: String = formatter.linearFeet(summary.crownLength)
        let _: String = formatter.volume(summary.volume)
        let _: Int = summary.doorCount
        let _: Int = summary.windowCount
        let _: String = summary.fixtureSummary
        let _: [ContractorQuantities] = summary.rooms

        // ReportBuilder: opening schedule page
        for r in OpeningSchedule.rows(levels: levels) {
            let _: String = r.mark
            let _: String = r.levelName
            let _: [String] = r.rooms
            let _: String = r.kind.displayName
            let _: String? = r.style?.displayName
            let _: String = "\(formatter.length(r.width)) × \(formatter.length(r.height))"
            let _: String = r.kind == .window ? formatter.length(r.sillHeight) : "—"
            let _: String? = r.hand
            let _: String? = r.swingsInto
            let _: String = r.changeStatus == .existing ? "" : r.changeStatus.displayName
            let _: String = r.notes
        }

        // ExportScreen: CSVs and OBJ
        let _: String = CSVExporter.openingSchedule(levels: levels, formatter: formatter)
        let _: String = CSVExporter.contractorQuantities(levels: levels, formatter: formatter)
        var objOptions = OBJExporter.Options()
        objOptions.mode = .existing
        objOptions.includeFixtures = true
        objOptions.includeFurniture = false
        objOptions.materialFileName = "fieldplan.mtl"
        let output = OBJExporter.export(levels: levels, options: objOptions)
        let entries = [
            ZipEntry(path: "Model.obj", data: Data(output.obj.utf8)),
            ZipEntry(path: "fieldplan.mtl", data: Data(output.mtl.utf8)),
        ]
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("m.zip")
        try ZipArchive.write(entries: entries, to: url)
        try? FileManager.default.removeItem(at: url)

        // ThreeDSceneBuilder: measured stacking
        let measured = levels.count > 1 && levels.allSatisfy { $0.elevation != nil }
        let lowest = levels.compactMap(\.elevation).min() ?? 0
        for l in levels.sorted(by: { $0.storyIndex < $1.storyIndex }) {
            let _: Double = measured ? (l.elevation ?? 0) - lowest : Double(l.storyIndex) * 3.4
        }
    }

    // MARK: - Build 15: checkpoints, recovery, validation

    func testCallsTheScanFlowMakes() throws {
        let level = SampleFixtures.apartment()
        let projectID = UUID()
        let roomID = UUID()
        let sessionID = UUID()

        // ScanCheckpointStore.checkpoint — every argument the flow binds.
        let checkpoint = RoomCheckpoint(
            id: roomID,
            projectID: projectID,
            levelID: level.id,
            scanSessionID: sessionID,
            roomName: "Kitchen",
            suggestedType: nil,
            capturedAt: Date(),
            rawDataFileName: "\(roomID.uuidString).json",
            usdzFileName: "\(roomID.uuidString).usdz",
            worldMapCheckpointID: UUID(),
            cameraTransform: [Float](repeating: 0, count: 16),
            floorCoverage: 12.0,
            wallCoverage: nil,
            meshChunkCount: 42)
        let merged = CheckpointStore.merge([], with: [checkpoint])
        let outstanding = CheckpointStore.outstanding(merged)
        XCTAssertEqual(outstanding.count, 1)
        let stamped = CheckpointStore.markMerged(merged, ids: [roomID], snapshotID: UUID())
        XCTAssertTrue(stamped[0].isMerged)

        // ScanFlowView.load → UnfinishedScanSheet
        if let unfinished = CheckpointStore.unfinished(
            projectID: projectID, checkpoints: merged, worldMapAvailable: true) {
            let _: UUID = unfinished.id
            let _: Int = unfinished.roomCount
            let _: String? = unfinished.lastRoomName
            let _: Date? = unfinished.lastCapturedAt
            let _: [UUID] = unfinished.levelIDs
            let _: Bool = unfinished.worldMapAvailable
            for c in unfinished.checkpoints {
                let _: String = c.roomName
                let _: String? = c.rawDataFileName
                let _: UUID? = c.levelID
            }
        } else {
            XCTFail("an unmerged checkpoint is an unfinished walk")
        }

        // SpatialSession: which maps are worth keeping, and whether the
        // restored frame can be trusted.
        XCTAssertTrue(WorldMapPolicy.isWorthSaving(.mapped))
        var identity = [Float](repeating: 0, count: 16)
        identity[0] = 1; identity[5] = 1; identity[10] = 1; identity[15] = 1
        XCTAssertTrue(WorldMapPolicy.coordinatesCompatible(saved: identity, restored: identity))
        let _: String = WorldMapPolicy.originAnchorName
        let map = WorldMapCheckpoint(
            scanSessionID: sessionID, levelID: level.id, fileName: "map.arworldmap",
            savedAt: Date(), mappingStatus: .mapped, trackingState: .normal,
            cameraTransform: identity, referenceKeyframeFileName: nil,
            lastAcceptedRoomID: roomID, acceptedRoomCount: 1,
            originAnchorTransform: identity, originAnchorName: WorldMapPolicy.originAnchorName)
        let _: String = map.fileName
        XCTAssertFalse(WorldMapPolicy.shouldReplace(map, with: .limited),
                       "a good map is never overwritten by a poor one")
        XCTAssertTrue(WorldMapPolicy.shouldReplace(nil, with: .extending))
        for state in [RelocalizationState.idle, .loadingMap, .relocalizing, .succeeded, .failed] {
            let _: String = state.message
        }

        // ScanRecorder.measureStorage → the live overlay's warning.
        let storage = StorageEstimate.estimate(
            sessionBytes: 500_000_000, elapsedSeconds: 600, freeBytes: 1_000_000_000)
        let _: StorageEstimate.Level = storage.level
        let _: Int? = storage.remainingMinutes
        let _: String? = storage.message
        for kind in [SessionEvent.Kind.checkpoint, .worldMapSaved, .relocalizationFailed,
                     .storageWarning, .thermalWarning, .delegateReattached] {
            _ = SessionEvent(time: 0, kind: kind, detail: "detail")
        }
    }

    func testCallsTheValidationScreensMake() throws {
        let level = SampleFixtures.apartment()
        let formatter = UnitFormatter()
        let validationSessionID = UUID()

        // PreflightSheet
        let report = PreflightReport(checks: [
            PreflightCheck(id: "lidar", title: "LiDAR", status: .ready,
                           detail: "Mesh reconstruction available", isCritical: true),
        ])
        let _: Bool = report.canScan
        let _: String = report.summary
        let _: [PreflightCheck] = report.blockers
        let _: [PreflightCheck] = report.warnings
        for status in [PreflightStatus.ready, .warning, .blocked, .unknown] { _ = status }

        // GroundTruthCaptureView: tap → options → one number.
        guard let wall = level.walls.first else { return XCTFail("fixture has walls") }
        let options = ValidationPrefill.options(for: .wall(wall.id), in: level, formatter: formatter)
        guard let option = options.first else { return XCTFail("a wall can be measured") }
        let _: String = option.label
        let _: AccuracyMeasureKind = option.kind
        let _: UUID? = option.elementID
        let _: UUID? = option.roomID
        let _: String = option.roomName
        let _: UUID? = option.scanSessionID
        let _: String = option.suggestedPhysicalKey
        let _: String = option.id
        for method in MeasurementMethod.allCases {
            let _: Double? = option.measurements.value(for: method)
        }
        let _: Double? = option.measurements.meshResidual
        let _: Int? = option.measurements.meshInlierCount
        let _: Double? = option.evidence.confidence
        let _: Double? = option.evidence.coverage
        let _: CaptureConfidence? = option.evidence.captureConfidence
        let _: Double? = option.evidence.trackingQuality
        let _: Int? = option.evidence.observationCount
        let _: ThicknessSource? = option.evidence.thicknessSource

        let sample = ValidationPrefill.sample(
            from: option, groundTruth: 3.05, method: .laser, note: "corner to corner",
            validationSessionID: validationSessionID,
            levelID: level.id, levelName: level.name, physicalElementKey: nil)
        let _: Date = sample.recordedAt
        let _: String = sample.elementLabel
        let _: Double? = sample.error(for: .canonical)
        let samples = [sample]

        // ValidationScreen
        let progress = ValidationProgress.compute(levels: [level], samples: samples, problemMarkers: [])
        for line in progress.lines {
            let _: String = line.displayName
            let _: Int = line.tested
            let _: Int = line.available
        }
        let _: Int = progress.repeatedElementCount
        let _: [UUID: Int] = ValidationProgress.testedElementIDs(samples)

        // MethodComparisonSheet
        for entry in ValidationAnalysis.rankedSources(samples) {
            let _: MeasurementMethod = entry.source
            let _: Int = entry.sampleCount
            let _: Int = entry.missingCount
            let _: Double = entry.statistics.meanAbsoluteError
            let _: Double = entry.statistics.meanSignedError
            let _: Double = entry.statistics.maxAbsoluteError
        }
        if let head = ValidationAnalysis.headToHead(samples, .canonical, .meshFit) {
            let _: Int = head.pairCount
            let _: Int = head.aCloserCount
            let _: Int = head.bCloserCount
            let _: Int = head.tiedCount
            let _: Double = head.meanAbsoluteErrorA
        }
        for spread in ValidationAnalysis.repeatability(samples) {
            let _: String = spread.physicalElementKey
            let _: Int = spread.scanCount
            let _: Double = spread.range
            let _: Double? = spread.standardDeviation
            let _: Double? = spread.bias
        }

        // ProblemMarkerSheet
        let marker = ProblemMarker(
            validationSessionID: validationSessionID, levelID: level.id, roomID: nil,
            elementID: wall.id, kind: .wrongWall, note: "off by an inch",
            planX: 1.0, planY: 2.0)
        let _: Vec2? = marker.planPosition
        for kind in ProblemKind.allCases { _ = kind }
        for method in GroundTruthMethod.allCases { _ = method }

        // FieldVisitChecklistSheet
        let checklist = FieldVisitChecklist.build(.init(
            levels: [level],
            findings: MissingSpaceDetector.findings(for: level, levels: [level]),
            lowCoverageWallCount: 0,
            trackingFailed: false,
            outstandingCheckpoints: 0,
            worldMapSaved: true,
            sensorSessionFinalized: true,
            validationSampleCount: samples.count,
            unsavedValidationEdits: false,
            projectSaved: true,
            bundleAvailable: true))
        XCTAssertTrue(checklist.isReadyToLeave)
        for item in checklist.items {
            let _: String = item.id
            let _: String = item.title
            let _: Bool = item.isSatisfied
            let _: String = item.detail
        }

        // ValidationStore.exportBundle
        let session = ValidationSession(
            projectID: UUID(), name: "Property Scan A", notes: "",
            appVersion: "1.5", buildNumber: "15",
            deviceModel: "iPhone17,2", systemVersion: "26.0")
        let input = FieldValidationBundle.Input(
            project: ProjectMeta(name: "Test"),
            environment: .init(appVersion: "1.5", buildNumber: "15",
                               deviceModel: "iPhone17,2", systemVersion: "26.0",
                               lidarAvailable: true),
            validationSessions: [session],
            samples: samples,
            problemMarkers: [marker],
            snapshot: nil,
            scanSessionSummaries: [],
            worldMapCheckpoints: [],
            roomCheckpoints: [],
            incidents: [.init(at: Date(), kind: "storageWarning", detail: "low")],
            referencedFiles: [.init(role: "capturedRoomJSON", path: "scans/a.json",
                                    byteCount: 1024, scanSessionID: nil)],
            scanEvents: [SessionEvent(time: 0, kind: .checkpoint, detail: "room Kitchen")],
            formatter: formatter)
        let entries = try FieldValidationBundle.entries(for: input)
        XCTAssertFalse(entries.isEmpty)
    }
}
