import XCTest
@testable import FieldPlanCore

// MARK: - Tap an element, type one number (build 15, priority 8)

final class ValidationPrefillTests: XCTestCase {

    private func level() -> LevelGeometry {
        let door = WallOpening(
            kind: .door, centerOffset: 1.0, width: 0.8128, height: 2.032,
            source: .lidarScanned,
            evidence: ElementEvidence(confidence: 0.71, coverage: 0.5))
        let window = WallOpening(
            kind: .window, centerOffset: 3.0, width: 1.22, height: 1.07,
            sillHeight: 0.91, source: .lidarScanned)
        let southWall = Wall(
            start: Vec2(0, 0), end: Vec2(4, 0),
            openings: [door, window],
            source: .lidarScanned,
            confidence: .high,
            originalLength: 3.97,
            thicknessSource: .measured,
            evidence: ElementEvidence(
                confidence: 0.88,
                scannerConfidence: .high,
                coverage: 0.82,
                observationCount: 1400,
                trackingQuality: 0.95,
                alternate: AlternateMeasurement(
                    method: "meshFit", value: 4.02, residual: 0.008, sampleCount: 612)))
        let westWall = Wall(start: Vec2(0, 0), end: Vec2(0, 3), source: .edited, originalLength: 2.94)
        let room = RoomShape(
            name: "Living Room", type: .livingRoom,
            polygon: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)],
            ceilingHeight: 2.44,
            wallIDs: [southWall.id, westWall.id],
            evidence: ElementEvidence(confidence: 0.8, coverage: 0.7))
        let stairs = FixtureItem(
            category: .stairs, center: Vec2(6, 1.5), size: Vec2(1.0, 3.2),
            rotation: 0, roomID: room.id)
        return LevelGeometry(
            name: "First Floor",
            walls: [southWall, westWall],
            rooms: [room],
            fixtures: [stairs])
    }

    // MARK: Walls

    func testWallTapOffersLengthWithEveryMethodSeparately() {
        let level = level()
        let wall = level.walls[0]
        let options = ValidationPrefill.options(for: .wall(wall.id), in: level)

        // Length and thickness — thickness only because the wall says where
        // its thickness came from.
        XCTAssertEqual(options.map(\.kind), [.wallLength, .wallThickness])

        let length = options[0]
        XCTAssertEqual(length.label, "Living Room wall")
        XCTAssertEqual(length.roomName, "Living Room")
        XCTAssertEqual(length.elementID, wall.id)

        // Each method's answer is carried on its own. Nothing is averaged and
        // nothing is dropped just because two methods disagree.
        XCTAssertEqual(length.measurements.canonical ?? 0, 4.0, accuracy: 1e-9)
        XCTAssertEqual(length.measurements.roomPlan ?? 0, 3.97, accuracy: 1e-9)
        XCTAssertEqual(length.measurements.originalScanned ?? 0, 3.97, accuracy: 1e-9)
        XCTAssertEqual(length.measurements.meshFit ?? 0, 4.02, accuracy: 1e-9)
        XCTAssertEqual(length.measurements.meshResidual ?? 0, 0.008, accuracy: 1e-9)
        XCTAssertEqual(length.measurements.meshInlierCount, 612)
        XCTAssertNil(length.measurements.userEdited, "an unedited wall has no edited value")
    }

    func testWallEvidenceIsCarriedIntoTheSample() {
        let level = level()
        let option = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)[0]
        XCTAssertEqual(option.evidence.confidence ?? 0, 0.88, accuracy: 1e-9)
        XCTAssertEqual(option.evidence.coverage ?? 0, 0.82, accuracy: 1e-9)
        XCTAssertEqual(option.evidence.captureConfidence, .high)
        XCTAssertEqual(option.evidence.trackingQuality ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertEqual(option.evidence.observationCount, 1400)
        XCTAssertEqual(option.evidence.thicknessSource, .measured)
    }

    func testEditedWallKeepsBothTheEditedAndTheScannedValue() {
        let level = level()
        let west = level.walls[1]
        let option = ValidationPrefill.options(for: .wall(west.id), in: level)[0]
        XCTAssertEqual(option.measurements.userEdited ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(option.measurements.originalScanned ?? 0, 2.94, accuracy: 1e-9)
        XCTAssertNil(option.measurements.roomPlan, "an edited wall is no longer RoomPlan's answer")
    }

    func testWallWithoutThicknessSourceIsNotAskedAboutThickness() {
        var level = level()
        level.walls[0].thicknessSource = nil
        let options = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)
        XCTAssertEqual(options.map(\.kind), [.wallLength])
    }

    // MARK: Openings

    func testDoorTapOffersWidthAndHeight() {
        let level = level()
        let wall = level.walls[0]
        let door = wall.openings[0]
        let options = ValidationPrefill.options(
            for: .opening(wallID: wall.id, openingID: door.id), in: level)
        XCTAssertEqual(options.map(\.kind), [.doorWidth, .doorHeight])
        XCTAssertEqual(options[0].measurements.canonical ?? 0, 0.8128, accuracy: 1e-9)
        XCTAssertEqual(options[1].measurements.canonical ?? 0, 2.032, accuracy: 1e-9)
        XCTAssertEqual(options[0].label, "Living Room door width")
        XCTAssertEqual(options[0].evidence.confidence ?? 0, 0.71, accuracy: 1e-9)
    }

    func testWindowTapAlsoOffersSillHeight() {
        let level = level()
        let wall = level.walls[0]
        let window = wall.openings[1]
        let options = ValidationPrefill.options(
            for: .opening(wallID: wall.id, openingID: window.id), in: level)
        XCTAssertEqual(options.map(\.kind), [.windowWidth, .windowHeight, .windowSillHeight])
        XCTAssertEqual(options[2].measurements.canonical ?? 0, 0.91, accuracy: 1e-9)
    }

    // MARK: Rooms and stairs

    func testRoomTapOffersWidthDepthAreaAndCeiling() {
        let level = level()
        let options = ValidationPrefill.options(for: .room(level.rooms[0].id), in: level)
        XCTAssertEqual(options.map(\.kind), [.roomWidth, .roomDepth, .roomArea, .ceilingHeight])
        XCTAssertEqual(options[2].measurements.canonical ?? 0, 12.0, accuracy: 1e-6)
        XCTAssertEqual(options[3].measurements.canonical ?? 0, 2.44, accuracy: 1e-9)
    }

    func testStairsTapOffersWidthAndRun() {
        let level = level()
        let options = ValidationPrefill.options(for: .fixture(level.fixtures[0].id), in: level)
        XCTAssertEqual(options.map(\.kind), [.stairWidth, .stairTreadDepth])
        XCTAssertEqual(options[0].measurements.canonical ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(options[1].measurements.canonical ?? 0, 3.2, accuracy: 1e-9)
        XCTAssertEqual(options[0].roomName, "Living Room")
    }

    func testUnknownElementOffersNothingRatherThanGuessing() {
        let level = level()
        XCTAssertTrue(ValidationPrefill.options(for: .wall(UUID()), in: level).isEmpty)
        XCTAssertTrue(ValidationPrefill.options(for: .room(UUID()), in: level).isEmpty)
        XCTAssertTrue(ValidationPrefill.options(for: .fixture(UUID()), in: level).isEmpty)
        XCTAssertTrue(ValidationPrefill.options(
            for: .opening(wallID: level.walls[0].id, openingID: UUID()), in: level).isEmpty)
    }

    // MARK: Recording the laser value

    func testTypingOneNumberProducesACompleteSample() {
        let level = level()
        let option = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)[0]
        let session = UUID()
        let scan = UUID()
        let sample = ValidationPrefill.sample(
            from: option, groundTruth: 4.01, method: .laser, note: "corner to corner",
            validationSessionID: session, scanSessionID: scan,
            levelID: level.id, levelName: level.name, physicalElementKey: nil)

        XCTAssertEqual(sample.validationSessionID, session)
        XCTAssertEqual(sample.scanSessionID, scan)
        XCTAssertEqual(sample.levelName, "First Floor")
        XCTAssertEqual(sample.roomName, "Living Room")
        XCTAssertEqual(sample.kind, .wallLength)
        XCTAssertEqual(sample.groundTruth, 4.01, accuracy: 1e-9)
        XCTAssertEqual(sample.method, .laser)
        XCTAssertEqual(sample.note, "corner to corner")

        // Every method is scored against the same laser value, separately.
        XCTAssertEqual(sample.error(for: .canonical) ?? 0, -0.01, accuracy: 1e-9)
        XCTAssertEqual(sample.error(for: .roomPlan) ?? 0, -0.04, accuracy: 1e-9)
        XCTAssertEqual(sample.error(for: .meshFit) ?? 0, 0.01, accuracy: 1e-9)
        XCTAssertNil(sample.error(for: .userEdited), "no edited value means no error, not zero error")

        // The default link is offered so a rescan can be tied to this wall.
        XCTAssertEqual(sample.physicalElementKey, option.suggestedPhysicalKey)
    }

    func testScanSessionIsCarriedFromTheElementRatherThanTyped() {
        var level = level()
        let scan = UUID()
        level.walls[0].evidence?.sessionID = scan
        let option = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)[0]
        XCTAssertEqual(option.scanSessionID, scan)

        let sample = ValidationPrefill.sample(
            from: option, groundTruth: 4.01, method: .laser, note: "",
            validationSessionID: UUID(),
            levelID: level.id, levelName: level.name, physicalElementKey: nil)
        XCTAssertEqual(sample.scanSessionID, scan, "the walk that produced the element is known already")
    }

    func testScanSessionFallsBackToTheWallsSourceScan() {
        var level = level()
        let scan = UUID()
        level.walls[0].evidence = nil
        level.walls[0].sourceScanID = scan
        let option = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)[0]
        XCTAssertEqual(option.scanSessionID, scan)
    }

    func testAnOwnerSuppliedLinkWinsOverTheSuggestedOne() {
        let level = level()
        let option = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)[0]
        let sample = ValidationPrefill.sample(
            from: option, groundTruth: 4.01, method: .tape, note: "",
            validationSessionID: UUID(), scanSessionID: nil,
            levelID: level.id, levelName: level.name,
            physicalElementKey: "living-south-wall")
        XCTAssertEqual(sample.physicalElementKey, "living-south-wall")

        let blank = ValidationPrefill.sample(
            from: option, groundTruth: 4.01, method: .tape, note: "",
            validationSessionID: UUID(), scanSessionID: nil,
            levelID: level.id, levelName: level.name, physicalElementKey: "")
        XCTAssertEqual(blank.physicalElementKey, option.suggestedPhysicalKey,
                       "an empty box is not a link")
    }

    func testSuggestedKeysAreStableAndDistinctPerMeasurement() {
        let level = level()
        let options = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)
        let again = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)
        XCTAssertEqual(options[0].suggestedPhysicalKey, again[0].suggestedPhysicalKey)
        XCTAssertNotEqual(options[0].suggestedPhysicalKey, options[1].suggestedPhysicalKey)
        XCTAssertTrue(options[0].suggestedPhysicalKey.hasPrefix("living-room-wall-"))
    }

    func testUnassignedWallStillProducesAKeyAndALabel() {
        var level = level()
        level.rooms = []
        let option = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)[0]
        XCTAssertEqual(option.label, "Wall")
        XCTAssertEqual(option.roomName, "")
        XCTAssertNil(option.roomID)
        XCTAssertTrue(option.suggestedPhysicalKey.hasPrefix("unassigned-wall-"))
    }

    // MARK: Repeatability across rescans

    func testTwoScansOfTheSameWallLinkThroughTheKeyNotTheUUID() {
        let first = level()
        var second = level()
        // A rescan produces new element IDs and a slightly different answer.
        second.walls[0].id = UUID()
        second.walls[0].end = Vec2(4.03, 0)
        second.rooms[0].wallIDs = [second.walls[0].id]

        let key = "living-south-wall"
        func sample(_ level: LevelGeometry) -> ValidationSample {
            let option = ValidationPrefill.options(for: .wall(level.walls[0].id), in: level)[0]
            return ValidationPrefill.sample(
                from: option, groundTruth: 4.01, method: .laser, note: "",
                validationSessionID: UUID(), scanSessionID: UUID(),
                levelID: level.id, levelName: level.name, physicalElementKey: key)
        }

        let spreads = ValidationAnalysis.repeatability([sample(first), sample(second)])
        let lengths = spreads.first { $0.source == .canonical && $0.kind == .wallLength }
        XCTAssertEqual(lengths?.physicalElementKey, key)
        XCTAssertEqual(lengths?.scanCount, 2, "different UUIDs must not split the same wall")
        XCTAssertEqual(lengths?.range ?? 0, 0.03, accuracy: 1e-6)
    }
}
