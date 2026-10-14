import XCTest
@testable import FieldPlanCore

// Build 15: not losing a scan, recovering an interrupted one, and keeping a
// dataset honest enough to choose an algorithm from later.

final class RoomCheckpointTests: XCTestCase {

    private func checkpoint(_ name: String, id: UUID = UUID(), at seconds: TimeInterval = 0) -> RoomCheckpoint {
        RoomCheckpoint(
            id: id, projectID: UUID(), levelID: nil, scanSessionID: UUID(),
            roomName: name, capturedAt: Date(timeIntervalSince1970: seconds))
    }

    func testAcceptingTheSameRoomTwiceDoesNotDuplicateIt() {
        // Re-accepting a rescanned room keeps one record, the newer one.
        let id = UUID()
        let first = checkpoint("Kitchen", id: id, at: 100)
        var second = checkpoint("Kitchen (rescan)", id: id, at: 200)
        second.floorCoverage = 0.9
        let merged = CheckpointStore.merge([first], with: [second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].roomName, "Kitchen (rescan)")
        XCTAssertEqual(merged[0].floorCoverage, 0.9)
    }

    func testAnOlderReplayNeverUndoesANewerCapture() {
        let id = UUID()
        let newer = checkpoint("Kitchen", id: id, at: 200)
        let older = checkpoint("Kitchen", id: id, at: 100)
        XCTAssertEqual(CheckpointStore.merge([newer], with: [older])[0].capturedAt,
                       Date(timeIntervalSince1970: 200))
    }

    func testReprocessingAMergedCheckpointDoesNotReImportTheRoom() {
        // The duplicate-checkpoint scenario: Finish Level runs twice.
        let id = UUID()
        let snapshot = UUID()
        var stored = [checkpoint("Kitchen", id: id, at: 100)]
        stored = CheckpointStore.markMerged(stored, ids: [id], snapshotID: snapshot)
        XCTAssertTrue(CheckpointStore.outstanding(stored).isEmpty)

        // The same room arrives again from a replayed checkpoint file.
        let replay = checkpoint("Kitchen", id: id, at: 100)
        let merged = CheckpointStore.merge(stored, with: [replay])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].mergedIntoSnapshotID, snapshot, "the merge stamp survives a replay")
        XCTAssertTrue(CheckpointStore.outstanding(merged).isEmpty, "it is not re-imported")
    }

    func testMarkMergedIsIdempotentAndKeepsTheFirstStamp() {
        let id = UUID()
        let first = Date(timeIntervalSince1970: 500)
        var stored = CheckpointStore.markMerged([checkpoint("Bath", id: id)], ids: [id],
                                                snapshotID: UUID(), at: first)
        stored = CheckpointStore.markMerged(stored, ids: [id], snapshotID: UUID(),
                                            at: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(stored[0].mergedAt, first)
    }

    func testFiveAcceptedRoomsSurviveTerminationAsUnfinishedWork() {
        // Accept five rooms, app dies: reopening must know all five are safe.
        let projectID = UUID()
        let saved = (1...5).map { index in
            RoomCheckpoint(id: UUID(), projectID: projectID, roomName: "Room \(index)",
                           capturedAt: Date(timeIntervalSince1970: Double(index) * 60))
        }
        let unfinished = CheckpointStore.unfinished(projectID: projectID, checkpoints: saved,
                                                    worldMapAvailable: true)
        XCTAssertEqual(unfinished?.roomCount, 5)
        XCTAssertEqual(unfinished?.lastRoomName, "Room 5")
        XCTAssertEqual(unfinished?.worldMapAvailable, true)
    }

    func testAFullyMergedProjectHasNothingUnfinished() {
        let id = UUID()
        let merged = CheckpointStore.markMerged([checkpoint("Kitchen", id: id)], ids: [id], snapshotID: UUID())
        XCTAssertNil(CheckpointStore.unfinished(projectID: UUID(), checkpoints: merged))
        XCTAssertNil(CheckpointStore.unfinished(projectID: UUID(), checkpoints: []))
    }
}

final class WorldMapPolicyTests: XCTestCase {

    private func map(_ status: WorldMappingQuality) -> WorldMapCheckpoint {
        WorldMapCheckpoint(fileName: "map.arworldmap", mappingStatus: status)
    }

    func testAGoodMapIsNeverReplacedByAWorseOne() {
        XCTAssertFalse(WorldMapPolicy.shouldReplace(map(.mapped), with: .extending))
        XCTAssertFalse(WorldMapPolicy.shouldReplace(map(.mapped), with: .limited))
        XCTAssertFalse(WorldMapPolicy.shouldReplace(map(.extending), with: .limited))
        // Equal quality is more recent and closer to where the owner stands.
        XCTAssertTrue(WorldMapPolicy.shouldReplace(map(.mapped), with: .mapped))
        XCTAssertTrue(WorldMapPolicy.shouldReplace(map(.extending), with: .mapped))
        XCTAssertTrue(WorldMapPolicy.shouldReplace(nil, with: .mapped))
    }

    func testAPoorMapIsNeverSavedAtAll() {
        XCTAssertFalse(WorldMapPolicy.isWorthSaving(.limited))
        XCTAssertFalse(WorldMapPolicy.isWorthSaving(.notAvailable))
        XCTAssertFalse(WorldMapPolicy.shouldReplace(nil, with: .limited))
        XCTAssertTrue(WorldMapPolicy.isWorthSaving(.mapped))
    }

    func testCoordinateCompatibilityCatchesADriftedRelocalization() {
        var saved = [Float](repeating: 0, count: 16)
        saved[0] = 1; saved[5] = 1; saved[10] = 1; saved[15] = 1
        saved[12] = 2.0; saved[13] = 0.0; saved[14] = -3.0
        var restored = saved
        // A few centimetres of drift is normal and acceptable.
        restored[12] = 2.04
        XCTAssertTrue(WorldMapPolicy.coordinatesCompatible(saved: saved, restored: restored))
        // Half a metre is not: the rooms would not line up.
        restored[12] = 2.5
        XCTAssertFalse(WorldMapPolicy.coordinatesCompatible(saved: saved, restored: restored))
        // No anchor came back at all: never assume compatibility.
        XCTAssertFalse(WorldMapPolicy.coordinatesCompatible(saved: saved, restored: nil))
        XCTAssertFalse(WorldMapPolicy.coordinatesCompatible(saved: nil, restored: restored))
    }

    func testRelocalizationStatesSayOneHonestThing() {
        XCTAssertTrue(RelocalizationState.relocalizing.message.contains("Relocalizing"))
        XCTAssertEqual(RelocalizationState.succeeded.message, "Relocalization successful.")
        XCTAssertEqual(RelocalizationState.failed.message, "Unable to relocalize.")
    }
}

final class PreflightAndStorageTests: XCTestCase {

    func testANonCriticalFailureWarnsButDoesNotBlockTheScan() {
        let report = PreflightReport(checks: [
            PreflightCheck(id: "roomplan", title: "RoomPlan", status: .ready, isCritical: true),
            PreflightCheck(id: "lidar", title: "LiDAR", status: .ready, isCritical: true),
            PreflightCheck(id: "heading", title: "Compass heading", status: .blocked,
                           detail: "Location permission denied", isCritical: false),
        ])
        XCTAssertTrue(report.canScan, "a north arrow is not worth refusing a walk over")
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.summary.hasPrefix("Ready, with one caution"))
    }

    func testACriticalFailureBlocksAndSaysWhat() {
        let report = PreflightReport(checks: [
            PreflightCheck(id: "lidar", title: "LiDAR", status: .blocked,
                           detail: "This device has no LiDAR scanner", isCritical: true),
        ])
        XCTAssertFalse(report.canScan)
        XCTAssertEqual(report.blockers.count, 1)
        XCTAssertTrue(report.summary.contains("no LiDAR scanner"), report.summary)
    }

    func testStorageEstimateUsesTheSessionsOwnDataRate() {
        // 60 MB in 60 s = 1 MB/s; 3 GB free less a 500 MB reserve = 2.5 GB.
        let estimate = StorageEstimate.estimate(
            sessionBytes: 60_000_000, elapsedSeconds: 60, freeBytes: 3_000_000_000)
        XCTAssertEqual(estimate.bytesPerSecond, 1_000_000, accuracy: 1)
        XCTAssertEqual(estimate.remainingSeconds ?? 0, 2500, accuracy: 1)
        XCTAssertEqual(estimate.level, .ok)
        XCTAssertNil(estimate.message)
    }

    func testStorageWarnsWellBeforeItRunsOut() {
        // 1 MB/s with 900 MB usable: 400 s left — low, not yet critical.
        let low = StorageEstimate.estimate(
            sessionBytes: 60_000_000, elapsedSeconds: 60, freeBytes: 900_000_000)
        XCTAssertEqual(low.level, .low)
        XCTAssertEqual(low.remainingMinutes, 6)
        XCTAssertTrue(low.message?.contains("6 minutes") == true, low.message ?? "")

        let critical = StorageEstimate.estimate(
            sessionBytes: 60_000_000, elapsedSeconds: 60, freeBytes: 600_000_000)
        XCTAssertEqual(critical.level, .critical)
        XCTAssertTrue(critical.message?.contains("checkpointed") == true)

        // Below the reserve there is no usable space at all.
        XCTAssertEqual(StorageEstimate.estimate(
            sessionBytes: 0, elapsedSeconds: 0, freeBytes: 100_000_000).level, .critical)
    }

    func testNoRateYetMakesNoClaimAboutRemainingTime() {
        let estimate = StorageEstimate.estimate(
            sessionBytes: 0, elapsedSeconds: 0, freeBytes: 50_000_000_000)
        XCTAssertNil(estimate.remainingSeconds)
        XCTAssertEqual(estimate.level, .ok)
    }
}

final class FieldVisitChecklistTests: XCTestCase {

    func testAnOutstandingCheckpointStopsTheOwnerLeaving() {
        let level = SampleFixtures.apartment()
        let checklist = FieldVisitChecklist.build(.init(
            levels: [level],
            outstandingCheckpoints: 2,
            worldMapSaved: true,
            sensorSessionFinalized: true,
            validationSampleCount: 12,
            projectSaved: true,
            bundleAvailable: true))
        XCTAssertFalse(checklist.isReadyToLeave)
        XCTAssertEqual(checklist.unresolved.map(\.id), ["checkpoints"])
        XCTAssertTrue(checklist.unresolved[0].detail.contains("2 accepted rooms"))
    }

    func testACompleteVisitPasses() {
        let checklist = FieldVisitChecklist.build(.init(
            levels: [SampleFixtures.apartment()],
            worldMapSaved: true,
            sensorSessionFinalized: true,
            validationSampleCount: 40,
            projectSaved: true,
            bundleAvailable: true))
        XCTAssertTrue(checklist.isReadyToLeave, "\(checklist.unresolved.map(\.title))")
    }

    func testAnEmptyProjectIsNotReadyToLeave() {
        let checklist = FieldVisitChecklist.build(.init())
        XCTAssertFalse(checklist.isReadyToLeave)
        XCTAssertTrue(checklist.unresolved.contains { $0.id == "rooms" })
    }
}

final class ValidationDatasetTests: XCTestCase {

    private let sessionID = UUID()

    private func sample(
        canonical: Double?, roomPlan: Double? = nil, meshFit: Double? = nil,
        truth: Double, kind: AccuracyMeasureKind = .wallLength,
        key: String? = nil, confidence: Double? = nil
    ) -> ValidationSample {
        ValidationSample(
            validationSessionID: sessionID,
            kind: kind,
            elementLabel: "wall",
            measurements: CompetingMeasurements(canonical: canonical, roomPlan: roomPlan, meshFit: meshFit),
            groundTruth: truth,
            evidence: SampleEvidence(confidence: confidence),
            physicalElementKey: key)
    }

    func testAMissingMethodIsAbsentNotZero() {
        let s = sample(canonical: 3.05, roomPlan: nil, truth: 3.0)
        XCTAssertEqual(s.error(for: .canonical) ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertNil(s.error(for: .roomPlan), "no answer must never read as a 3 m error")
        XCTAssertNil(s.percentError(for: .meshFit))
    }

    func testErrorIsSignedSoBiasIsVisible() {
        XCTAssertEqual(sample(canonical: 3.05, truth: 3.0).error(for: .canonical) ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(sample(canonical: 2.95, truth: 3.0).error(for: .canonical) ?? 0, -0.05, accuracy: 1e-9)
    }

    func testEachMethodIsScoredOnlyWhereItAnswered() {
        let samples = [
            sample(canonical: 3.02, roomPlan: 3.02, meshFit: 3.00, truth: 3.00),
            sample(canonical: 4.06, roomPlan: 4.06, truth: 4.00),   // mesh had no answer
            sample(canonical: 2.48, roomPlan: 2.48, meshFit: 2.50, truth: 2.50),
        ]
        let compared = ValidationAnalysis.compareSources(samples)
        let mesh = compared.first { $0.source == .meshFit }
        let canonical = compared.first { $0.source == .canonical }
        XCTAssertEqual(mesh?.sampleCount, 2)
        XCTAssertEqual(mesh?.missingCount, 1, "the element it could not measure is recorded, not hidden")
        XCTAssertEqual(canonical?.sampleCount, 3)
        XCTAssertEqual(mesh?.statistics.meanAbsoluteError ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(canonical?.statistics.meanAbsoluteError ?? 0, 0.10 / 3, accuracy: 1e-9)
        // Ordering is reported, never applied.
        XCTAssertEqual(ValidationAnalysis.rankedSources(samples).first?.source, .meshFit)
    }

    func testHeadToHeadOnlyUsesElementsBothMethodsMeasured() {
        let samples = [
            sample(canonical: 3.05, meshFit: 3.01, truth: 3.00),   // mesh closer
            sample(canonical: 4.01, meshFit: 4.09, truth: 4.00),   // canonical closer
            sample(canonical: 2.60, truth: 2.50),                  // mesh silent: excluded
        ]
        let pair = ValidationAnalysis.headToHead(samples, .canonical, .meshFit)
        XCTAssertEqual(pair?.pairCount, 2)
        XCTAssertEqual(pair?.aCloserCount, 1)
        XCTAssertEqual(pair?.bCloserCount, 1)
        XCTAssertNil(ValidationAnalysis.headToHead([sample(canonical: 1, truth: 1)], .roomPlan, .meshFit))
    }

    func testRepeatabilityNeedsAnExplicitPhysicalLinkNotAUUID() {
        // Three scans of the same wall; each scan minted its own element ID.
        let key = "kitchen-north-wall"
        let samples = [
            sample(canonical: 3.02, truth: 3.00, key: key),
            sample(canonical: 3.06, truth: 3.00, key: key),
            sample(canonical: 3.04, truth: 3.00, key: key),
        ]
        let spread = ValidationAnalysis.repeatability(samples)
            .first { $0.source == .canonical }
        XCTAssertEqual(spread?.scanCount, 3)
        XCTAssertEqual(spread?.mean ?? 0, 3.04, accuracy: 1e-9)
        XCTAssertEqual(spread?.standardDeviation ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(spread?.range ?? 0, 0.04, accuracy: 1e-9)
        XCTAssertEqual(spread?.bias ?? 0, 0.04, accuracy: 1e-9)

        // Unlinked samples cannot be compared and are left out rather than
        // guessed at.
        XCTAssertTrue(ValidationAnalysis.repeatability([sample(canonical: 3.0, truth: 3.0)]).isEmpty)
    }

    func testASingleScanHasNoStandardDeviation() {
        let spread = ValidationAnalysis.repeatability([sample(canonical: 3.0, truth: 3.0, key: "w1")])
        XCTAssertEqual(spread.first?.scanCount, 1)
        XCTAssertNil(spread.first?.standardDeviation)
    }

    func testCalibrationShowsWhetherConfidencePredictedError() {
        let samples = [
            sample(canonical: 3.30, truth: 3.00, confidence: 0.2),   // low score, 300 mm out
            sample(canonical: 3.25, truth: 3.00, confidence: 0.3),
            sample(canonical: 3.01, truth: 3.00, confidence: 0.95),  // high score, 10 mm out
            sample(canonical: 3.01, truth: 3.00, confidence: 1.0),   // exactly 1 lands in the top bucket
        ]
        let buckets = ValidationAnalysis.confidenceCalibration(samples, bucketCount: 5)
        let low = buckets.first { $0.lowerBound <= 0.2 && $0.upperBound > 0.2 }
        let high = buckets.first { $0.upperBound >= 1.0 }
        XCTAssertEqual(low?.sampleCount, 2, "0.2 and 0.3 share the 0.2–0.4 bucket")
        XCTAssertEqual(high?.sampleCount, 2, "a score of exactly 1 is not dropped")
        XCTAssertGreaterThan(low?.meanAbsoluteError ?? 0, high?.meanAbsoluteError ?? 1)
    }

    func testProgressCountsElementsCheckedNotSamplesTaken() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 10)
        level.walls[0].openings = [WallOpening(kind: .door, centerOffset: 1, width: 0.9, height: 2.03)]
        let wallID = level.walls[0].id
        let samples = [
            ValidationSample(validationSessionID: sessionID, elementID: wallID, kind: .wallLength,
                             elementLabel: "w", groundTruth: 3.6, physicalElementKey: "w1"),
            ValidationSample(validationSessionID: sessionID, elementID: wallID, kind: .wallLength,
                             elementLabel: "w", groundTruth: 3.6, physicalElementKey: "w1"),
        ]
        let progress = ValidationProgress.compute(levels: [level], samples: samples)
        let walls = progress.lines.first { $0.kind == .wallLength }
        XCTAssertEqual(walls?.tested, 1, "one wall measured twice is one wall checked")
        XCTAssertEqual(walls?.available, 4)
        XCTAssertEqual(progress.totalSamples, 2)
        XCTAssertEqual(progress.repeatedElementCount, 1)
        XCTAssertEqual(progress.lines.first { $0.kind == .doorWidth }?.available, 1)
        XCTAssertEqual(ValidationProgress.testedElementIDs(samples)[wallID], 2)
    }
}

final class FieldValidationBundleTests: XCTestCase {

    private func input() -> FieldValidationBundle.Input {
        let sessionID = UUID()
        let samples = [
            ValidationSample(
                validationSessionID: sessionID, levelName: "First Floor", roomName: "Kitchen",
                kind: .wallLength, elementLabel: "Kitchen north wall",
                measurements: CompetingMeasurements(canonical: 3.05, roomPlan: 3.05, meshFit: 3.01,
                                                    meshResidual: 0.004, meshInlierCount: 812),
                groundTruth: 3.00, method: .laser, note: "Measured jamb to jamb",
                evidence: SampleEvidence(confidence: 0.88, coverage: 0.92),
                physicalElementKey: "kitchen-north"),
            ValidationSample(
                validationSessionID: sessionID, levelName: "First Floor", roomName: "Bath",
                kind: .doorWidth, elementLabel: "Bath door",
                measurements: CompetingMeasurements(canonical: 0.79),
                groundTruth: 0.80, method: .tape),
        ]
        return FieldValidationBundle.Input(
            project: ProjectMeta(name: "12 Elm Street"),
            environment: .init(appVersion: "1.5", buildNumber: "15",
                               deviceModel: "iPhone17,2", systemVersion: "18.0"),
            validationSessions: [ValidationSession(projectID: UUID(), name: "Property Scan A")],
            samples: samples,
            problemMarkers: [ProblemMarker(kind: .missingWall, note: "Wall behind the fridge")],
            snapshot: PlanSnapshot(name: "Existing Conditions", kind: .existingConditions,
                                   levels: [SampleFixtures.apartment()]))
    }

    func testBundleCarriesTheDataAndSaysNothingWasArbitrated() throws {
        let entries = try FieldValidationBundle.entries(for: input())
        let paths = Set(entries.map(\.path))
        for expected in ["manifest.json", "validation-samples.json", "validation-samples.csv",
                         "analysis.json", "problem-markers.json", "canonical-snapshot.json", "README.txt"] {
            XCTAssertTrue(paths.contains(expected), "missing \(expected)")
        }
        let manifest = entries.first { $0.path == "manifest.json" }!
        let text = String(decoding: manifest.data, as: UTF8.self)
        XCTAssertTrue(text.contains("never averaged") || text.contains("arbitrated"), "the manifest states the rule")
        let readme = String(decoding: entries.first { $0.path == "README.txt" }!.data, as: UTF8.self)
        XCTAssertTrue(readme.contains("It is not a zero"))
        XCTAssertTrue(readme.contains("not a decision"))
    }

    func testGroundTruthCSVKeepsEveryMethodSideBySide() {
        let csv = FieldValidationBundle.groundTruthCSV(input().samples)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "a header and two samples")
        XCTAssertTrue(lines[0].contains("canonical_m"))
        XCTAssertTrue(lines[0].contains("roomplan_m"))
        XCTAssertTrue(lines[0].contains("mesh_fit_m"))
        XCTAssertTrue(lines[0].contains("error_mesh_fit_m"))
        XCTAssertTrue(lines[0].contains("ground_truth_m"))

        let wall = lines.first { $0.contains("Kitchen north wall") }!
        XCTAssertTrue(wall.contains("3.050000"))
        XCTAssertTrue(wall.contains("3.010000"))
        XCTAssertTrue(wall.contains("0.050000"), "signed canonical error")
        XCTAssertTrue(wall.contains("812"))

        // The door had no mesh fit: those columns are blank, never 0.
        let door = lines.first { $0.contains("Bath door") }!
        let fields = door.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let meshIndex = header.firstIndex(of: "mesh_fit_m")!
        XCTAssertEqual(fields[meshIndex], "", "an unanswered method is blank, not zero")
    }

    func testBundleZipsAndReadsBack() throws {
        let entries = try FieldValidationBundle.entries(for: input())
        let data = ZipArchive.archiveData(entries: entries)
        let readBack = try ZipArchive.read(data: data)
        XCTAssertEqual(Set(readBack.map(\.path)), Set(entries.map(\.path)))
        let samples = readBack.first { $0.path == "validation-samples.json" }!
        let decoded = try ProjectArchive.decoder().decode([ValidationSample].self, from: samples.data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].measurements.meshInlierCount, 812)
        XCTAssertNil(decoded[1].measurements.meshFit)
    }

    func testAnalysisTravelsWithTheBundle() throws {
        let entries = try FieldValidationBundle.entries(for: input())
        let data = entries.first { $0.path == "analysis.json" }!.data
        let analysis = try ProjectArchive.decoder().decode(FieldValidationBundle.Analysis.self, from: data)
        XCTAssertFalse(analysis.bySource.isEmpty)
        XCTAssertTrue(analysis.bySource.contains { $0.source == .canonical })
        XCTAssertGreaterThan(analysis.progress.totalSamples, 0)
    }
}
