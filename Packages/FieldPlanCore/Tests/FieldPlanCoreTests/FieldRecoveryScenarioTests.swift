import XCTest
@testable import FieldPlanCore

// MARK: - Crash-testing the field workflow (build 15, priority 20)
//
// Each test is one thing that will actually happen at a property: a phone
// call, a memory kill, a full disk, a walk resumed an hour later. The claim
// under test is always the same one — no accepted room is ever lost, and no
// two coordinate systems are ever merged as if they were one.
//
// These exercise the pure decision logic. What they cannot cover is whether
// iOS actually restores an ARWorldMap through RoomPlan's own session
// configuration; that is a device question, and the app answers it by
// verifying the origin anchor rather than assuming.

final class FieldRecoveryScenarioTests: XCTestCase {

    private func checkpoint(
        _ name: String,
        at seconds: TimeInterval,
        id: UUID = UUID(),
        projectID: UUID,
        levelID: UUID? = nil,
        raw: String? = "raw.json"
    ) -> RoomCheckpoint {
        RoomCheckpoint(
            id: id, projectID: projectID, levelID: levelID, scanSessionID: UUID(),
            roomName: name, capturedAt: Date(timeIntervalSince1970: seconds),
            rawDataFileName: raw, usdzFileName: "room.usdz")
    }

    // 1. The scenario that motivated the whole build.
    func testTerminationAfterThreeRoomsLosesNothing() {
        let project = UUID()
        var saved: [RoomCheckpoint] = []
        for (index, name) in ["Kitchen", "Living Room", "Hall"].enumerated() {
            saved = CheckpointStore.merge(saved, with: [
                checkpoint(name, at: Double(index) * 300, projectID: project),
            ])
        }
        // iOS kills the app here. Nothing else runs.
        let unfinished = CheckpointStore.unfinished(
            projectID: project, checkpoints: saved, worldMapAvailable: true)
        XCTAssertEqual(unfinished?.roomCount, 3)
        XCTAssertEqual(unfinished?.lastRoomName, "Hall")
    }

    // 2. Reopening twice must not offer the walk twice over.
    func testReopeningTwiceOffersTheSameWalkNotTwoOfThem() {
        let project = UUID()
        let saved = CheckpointStore.merge([], with: [checkpoint("Kitchen", at: 0, projectID: project)])
        let first = CheckpointStore.unfinished(projectID: project, checkpoints: saved, worldMapAvailable: false)
        let second = CheckpointStore.unfinished(projectID: project, checkpoints: saved, worldMapAvailable: false)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.id, project, "one unfinished walk per project")
    }

    // 3. Finish With Saved Rooms, then the app is opened again.
    func testFinishingClearsTheRecoveryPrompt() {
        let project = UUID()
        let kitchen = checkpoint("Kitchen", at: 0, projectID: project)
        let hall = checkpoint("Hall", at: 60, projectID: project)
        var saved = CheckpointStore.merge([], with: [kitchen, hall])
        saved = CheckpointStore.markMerged(saved, ids: [kitchen.id, hall.id], snapshotID: UUID())
        XCTAssertNil(CheckpointStore.unfinished(
            projectID: project, checkpoints: saved, worldMapAvailable: true))
    }

    // 4. Continue, scan two more rooms, then finish: the first three are not
    // imported a second time.
    func testResumingAndFinishingImportsEachRoomExactlyOnce() {
        let project = UUID()
        let first = [checkpoint("A", at: 0, projectID: project),
                     checkpoint("B", at: 10, projectID: project)]
        var saved = CheckpointStore.merge([], with: first)
        // Resumed session re-checkpoints what it adopted, as the flow does.
        saved = CheckpointStore.merge(saved, with: first)
        saved = CheckpointStore.merge(saved, with: [checkpoint("C", at: 20, projectID: project)])
        XCTAssertEqual(saved.count, 3)
        let outstanding = CheckpointStore.outstanding(saved)
        XCTAssertEqual(Set(outstanding.map(\.roomName)), ["A", "B", "C"])
    }

    // 5. A room re-scanned under the same RoomPlan identifier replaces the
    // old capture rather than producing two of the same room.
    func testRescanningARoomReplacesItRatherThanDoublingIt() {
        let project = UUID()
        let id = UUID()
        var saved = CheckpointStore.merge([], with: [
            checkpoint("Bedroom", at: 0, id: id, projectID: project),
        ])
        saved = CheckpointStore.merge(saved, with: [
            checkpoint("Primary Bedroom", at: 500, id: id, projectID: project),
        ])
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].roomName, "Primary Bedroom")
    }

    // 6. A merged room re-checkpointed by a stale flow stays merged.
    func testAStaleFlowCannotUnmergeAnImportedRoom() {
        let project = UUID()
        let id = UUID()
        let snapshot = UUID()
        var saved = CheckpointStore.merge([], with: [checkpoint("Kitchen", at: 0, id: id, projectID: project)])
        saved = CheckpointStore.markMerged(saved, ids: [id], snapshotID: snapshot)
        saved = CheckpointStore.merge(saved, with: [checkpoint("Kitchen", at: 900, id: id, projectID: project)])
        XCTAssertEqual(saved[0].mergedIntoSnapshotID, snapshot)
        XCTAssertTrue(CheckpointStore.outstanding(saved).isEmpty)
    }

    // 7. Interrupted with no map saved: continuing would start a second
    // coordinate space, and the recovery sheet has to say so.
    func testAWalkWithNoSavedMapSaysContinuingStartsANewSpace() {
        let project = UUID()
        let saved = CheckpointStore.merge([], with: [checkpoint("Kitchen", at: 0, projectID: project)])
        let unfinished = CheckpointStore.unfinished(
            projectID: project, checkpoints: saved, worldMapAvailable: false)
        XCTAssertEqual(unfinished?.worldMapAvailable, false)
    }

    // 8. Tracking degrades mid-walk. A limited map must not overwrite the
    // good one taken two rooms ago.
    func testDegradedTrackingNeverOverwritesTheGoodMap() {
        let good = WorldMapCheckpoint(fileName: "good.map", mappingStatus: .mapped)
        XCTAssertFalse(WorldMapPolicy.shouldReplace(good, with: .limited))
        XCTAssertFalse(WorldMapPolicy.shouldReplace(good, with: .notAvailable))
        XCTAssertTrue(WorldMapPolicy.shouldReplace(good, with: .mapped),
                      "an equally good map is more recent, so it is worth taking")
    }

    // 9. Relocalization reports success but the frame moved. That is the
    // dangerous case: merging would silently misplace every later room.
    func testARelocalizationThatMovedTheOriginIsRejected() {
        var saved = [Float](repeating: 0, count: 16)
        saved[0] = 1; saved[5] = 1; saved[10] = 1; saved[15] = 1
        var drifted = saved
        drifted[12] = 1.4   // 1.4 m away
        XCTAssertFalse(WorldMapPolicy.coordinatesCompatible(saved: saved, restored: drifted))

        var settled = saved
        settled[12] = 0.03  // 3 cm — normal relocalization jitter
        XCTAssertTrue(WorldMapPolicy.coordinatesCompatible(saved: saved, restored: settled))
    }

    // 10. The origin anchor never came back at all.
    func testAMissingOriginAnchorIsNotTreatedAsAMatch() {
        var saved = [Float](repeating: 0, count: 16)
        saved[0] = 1; saved[5] = 1; saved[10] = 1; saved[15] = 1
        XCTAssertFalse(WorldMapPolicy.coordinatesCompatible(saved: saved, restored: nil))
        XCTAssertFalse(WorldMapPolicy.coordinatesCompatible(saved: nil, restored: saved))
    }

    // 11. The disk fills while scanning a large house.
    func testAFullDiskIsCriticalBeforeItIsActuallyFull() {
        // 2 MB/s of sensor data, 600 MB free: the 500 MB reserve leaves 100 MB,
        // i.e. under a minute — critical, and said so before writes fail.
        let estimate = StorageEstimate.estimate(
            sessionBytes: 1_200_000_000, elapsedSeconds: 600, freeBytes: 600_000_000)
        XCTAssertEqual(estimate.level, .critical)
        XCTAssertNotNil(estimate.message)
    }

    // 12. Nothing written yet: the app must not invent a time remaining.
    func testTheFirstSecondsOfAScanClaimNoTimeRemaining() {
        let estimate = StorageEstimate.estimate(
            sessionBytes: 0, elapsedSeconds: 0.5, freeBytes: 60_000_000_000)
        XCTAssertNil(estimate.remainingSeconds)
        XCTAssertNil(estimate.remainingMinutes)
        XCTAssertEqual(estimate.level, .ok)
    }

    // 13. A checkpoint whose raw file cannot be read back. The room is still
    // listed, because the owner has to be told rather than have it vanish.
    func testARoomWithNoRawFileIsStillListedAsUnfinished() {
        let project = UUID()
        let saved = CheckpointStore.merge([], with: [
            checkpoint("Kitchen", at: 0, projectID: project, raw: nil),
        ])
        let unfinished = CheckpointStore.unfinished(
            projectID: project, checkpoints: saved, worldMapAvailable: true)
        XCTAssertEqual(unfinished?.roomCount, 1)
        XCTAssertNil(unfinished?.checkpoints.first?.rawDataFileName)
    }

    // 14. Two floors walked in one session, interrupted on the second.
    func testAnInterruptedMultiStoryWalkRemembersBothLevels() {
        let project = UUID()
        let first = UUID()
        let second = UUID()
        let saved = CheckpointStore.merge([], with: [
            checkpoint("Kitchen", at: 0, projectID: project, levelID: first),
            checkpoint("Bedroom", at: 300, projectID: project, levelID: second),
        ])
        let unfinished = CheckpointStore.unfinished(
            projectID: project, checkpoints: saved, worldMapAvailable: true)
        XCTAssertEqual(Set(unfinished?.levelIDs ?? []), [first, second])
    }

    // 15. The checklist must not let a walk end with rooms still unimported.
    func testLeavingWithUnimportedRoomsIsBlocked() {
        let level = SampleFixtures.apartment()
        let checklist = FieldVisitChecklist.build(.init(
            levels: [level], outstandingCheckpoints: 2,
            worldMapSaved: true, sensorSessionFinalized: true,
            validationSampleCount: 5, projectSaved: true, bundleAvailable: true))
        XCTAssertFalse(checklist.isReadyToLeave)
        XCTAssertTrue(checklist.unresolved.contains { $0.id == "checkpoints" })
    }

    // 16. Preflight refuses the walk when the evidence stream is off, since a
    // validation scan without it cannot be re-processed later.
    func testValidationWithoutSensorRecordingIsBlockedNotWarned() {
        let report = PreflightReport(checks: [
            PreflightCheck(id: "recorder", title: "Sensor recording", status: .blocked,
                           detail: "Off — validation needs the evidence stream", isCritical: true),
            PreflightCheck(id: "battery", title: "Battery", status: .warning,
                           detail: "12%", isCritical: false),
        ])
        XCTAssertFalse(report.canScan)
        XCTAssertEqual(report.blockers.map(\.id), ["recorder"])
        XCTAssertEqual(report.warnings.map(\.id), ["battery"])
    }
}
