import XCTest
@testable import FieldPlanCore

final class EditorEngineTests: XCTestCase {

    let ft = UnitConstants.metersPerFoot

    /// 10' × 10' room fixture.
    func room10x10() -> LevelGeometry {
        SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10, name: "Test", type: .other)
    }

    func testSetWallLengthMoveEndStretchesNeighbors() {
        let level = room10x10()
        let south = level.walls[0] // (0,0) -> (10',0)
        let newLength = 12 * ft
        let edited = EditorEngine.setWallLength(
            in: level, wallID: south.id, newLength: newLength, strategy: .moveEnd)

        let editedSouth = edited.wall(withID: south.id)!
        XCTAssertEqual(editedSouth.length, newLength, accuracy: 1e-9)
        // Original length preserved for provenance.
        XCTAssertEqual(editedSouth.originalLength!, 10 * ft, accuracy: 1e-9)
        XCTAssertEqual(editedSouth.source, .edited)

        // East wall's bottom endpoint followed; the room stays closed.
        let east = edited.walls[1]
        XCTAssertEqual(east.start.x, 12 * ft, accuracy: 1e-9)
        // Room polygon rebuilt: area is now 12 × 10.
        let room = edited.rooms[0]
        XCTAssertEqual(room.floorArea, 120 * ft * ft, accuracy: 1e-6)
        // Angles preserved: east wall still vertical.
        XCTAssertEqual(east.start.x, east.end.x, accuracy: 1e-9)
    }

    func testSetWallLengthSymmetric() {
        let level = room10x10()
        let south = level.walls[0]
        let edited = EditorEngine.setWallLength(
            in: level, wallID: south.id, newLength: 8 * ft, strategy: .symmetric)
        let editedSouth = edited.wall(withID: south.id)!
        XCTAssertEqual(editedSouth.length, 8 * ft, accuracy: 1e-9)
        XCTAssertEqual(editedSouth.midpoint.x, 5 * ft, accuracy: 1e-6) // midpoint kept
    }

    func testSetWallLengthPushBeyondEndFallsBackInClosedLoop() {
        // In a closed rectangle everything is connected back to the start, so
        // pushBeyondEnd must degrade to a stretch — and still produce the
        // exact requested length.
        let level = room10x10()
        let south = level.walls[0]
        let edited = EditorEngine.setWallLength(
            in: level, wallID: south.id, newLength: 11 * ft, strategy: .pushBeyondEnd)
        XCTAssertEqual(edited.wall(withID: south.id)!.length, 11 * ft, accuracy: 1e-9)
    }

    func testPushBeyondEndTranslatesOpenRun() {
        // Straight run: A(0,0)-(3,0), B(3,0)-(6,0). Lengthening A pushes B.
        let a = Wall(start: Vec2(0, 0), end: Vec2(3, 0))
        let b = Wall(start: Vec2(3, 0), end: Vec2(6, 0))
        let level = LevelGeometry(name: "L", walls: [a, b])
        let edited = EditorEngine.setWallLength(
            in: level, wallID: a.id, newLength: 4, strategy: .pushBeyondEnd)
        let editedA = edited.wall(withID: a.id)!
        let editedB = edited.wall(withID: b.id)!
        XCTAssertEqual(editedA.length, 4, accuracy: 1e-9)
        XCTAssertEqual(editedB.length, 3, accuracy: 1e-9) // b keeps its length
        XCTAssertEqual(editedB.start.x, 4, accuracy: 1e-9)
        XCTAssertEqual(editedB.end.x, 7, accuracy: 1e-9)
    }

    func testTranslateWallKeepsNeighborsAttached() {
        let level = room10x10()
        let north = level.walls[2] // (10',10') -> (0,10')
        let delta = Vec2(0, 2 * ft)
        let edited = EditorEngine.translateWall(in: level, wallID: north.id, delta: delta)
        // Room grew to 10 × 12.
        XCTAssertEqual(edited.rooms[0].floorArea, 120 * ft * ft, accuracy: 1e-6)
        // Side walls still vertical and attached.
        let east = edited.walls[1]
        XCTAssertEqual(east.end.y, 12 * ft, accuracy: 1e-9)
        XCTAssertEqual(east.start.y, 0, accuracy: 1e-9)
    }

    func testSplitWall() {
        var level = room10x10()
        let south = level.walls[0]
        // Put a door near the start so it stays on the first piece.
        level.walls[0].openings = [WallOpening(kind: .door, centerOffset: 1 * ft, width: 0.8, height: 2)]
        let split = EditorEngine.splitWall(in: level, wallID: south.id, atOffset: 4 * ft)
        XCTAssertNotNil(split)
        let pieces = split!.walls.filter { abs($0.start.y) < 1e-9 && abs($0.end.y) < 1e-9 }
        XCTAssertEqual(pieces.count, 2)
        let first = split!.wall(withID: south.id)!
        XCTAssertEqual(first.length, 4 * ft, accuracy: 1e-9)
        XCTAssertEqual(first.openings.count, 1)
        // Room now references 5 walls.
        XCTAssertEqual(split!.rooms[0].wallIDs.count, 5)
    }

    func testSplitWallRefusesToCutThroughOpening() {
        var level = room10x10()
        let south = level.walls[0]
        level.walls[0].openings = [WallOpening(kind: .door, centerOffset: 4 * ft, width: 0.9, height: 2)]
        XCTAssertNil(EditorEngine.splitWall(in: level, wallID: south.id, atOffset: 4 * ft))
    }

    func testAddOpeningValidatesOverlap() {
        let level = room10x10()
        let south = level.walls[0]
        let first = EditorEngine.addOpening(
            in: level, wallID: south.id, kind: .door,
            centerOffset: 2 * ft, width: 0.9, height: 2.03)
        XCTAssertNotNil(first)
        let second = EditorEngine.addOpening(
            in: first!.0, wallID: south.id, kind: .window,
            centerOffset: 2 * ft, width: 0.9, height: 1.2)
        XCTAssertNil(second) // overlaps the door
    }

    func testAddOpeningRejectsWiderThanWall() {
        let level = room10x10()
        XCTAssertNil(EditorEngine.addOpening(
            in: level, wallID: level.walls[0].id, kind: .door,
            centerOffset: 5 * ft, width: 11 * ft, height: 2.03))
    }

    func testDeleteWallRemovesRoomReference() {
        let level = room10x10()
        let target = level.walls[0]
        let edited = EditorEngine.deleteWall(in: level, wallID: target.id)
        XCTAssertEqual(edited.walls.count, 3)
        XCTAssertFalse(edited.rooms[0].wallIDs.contains(target.id))
    }

    func testMergeRooms() {
        // Two rooms sharing one partition.
        let shared = Wall(start: Vec2(4, 0), end: Vec2(4, 3))
        let a1 = Wall(start: Vec2(0, 0), end: Vec2(4, 0))
        let a2 = Wall(start: Vec2(0, 3), end: Vec2(0, 0))
        let a3 = Wall(start: Vec2(4, 3), end: Vec2(0, 3))
        let b1 = Wall(start: Vec2(4, 0), end: Vec2(8, 0))
        let b2 = Wall(start: Vec2(8, 0), end: Vec2(8, 3))
        let b3 = Wall(start: Vec2(8, 3), end: Vec2(4, 3))
        let roomA = RoomShape(
            name: "A", polygon: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)],
            wallIDs: [a1.id, shared.id, a3.id, a2.id])
        let roomB = RoomShape(
            name: "B", polygon: [Vec2(4, 0), Vec2(8, 0), Vec2(8, 3), Vec2(4, 3)],
            wallIDs: [b1.id, b2.id, b3.id, shared.id])
        let level = LevelGeometry(
            name: "L", walls: [shared, a1, a2, a3, b1, b2, b3], rooms: [roomA, roomB])

        let merged = EditorEngine.mergeRooms(in: level, roomA: roomA.id, roomB: roomB.id)
        XCTAssertNotNil(merged)
        XCTAssertEqual(merged!.rooms.count, 1)
        XCTAssertEqual(merged!.rooms[0].floorArea, 24, accuracy: 1e-6)
    }

    func testSplitRoom() {
        let level = room10x10()
        let room = level.rooms[0]
        // Vertical cut at x = 4'.
        let cut = EditorEngine.splitRoom(
            in: level, roomID: room.id,
            cutA: Vec2(4 * ft, 1 * ft), cutB: Vec2(4 * ft, 9 * ft))
        XCTAssertNotNil(cut)
        XCTAssertEqual(cut!.rooms.count, 2)
        let areas = cut!.rooms.map(\.floorArea).sorted()
        XCTAssertEqual(areas[0], 40 * ft * ft, accuracy: 1e-6)
        XCTAssertEqual(areas[1], 60 * ft * ft, accuracy: 1e-6)
    }

    func testChangeStatusMarkup() {
        var level = room10x10()
        level.walls[0].openings = [WallOpening(kind: .door, centerOffset: 1, width: 0.9, height: 2)]
        let wallID = level.walls[0].id
        let marked = EditorEngine.setWallChangeStatus(in: level, wallID: wallID, status: .demolish)
        XCTAssertEqual(marked.walls[0].changeStatus, .demolish)
        // Openings demolished with their wall.
        XCTAssertEqual(marked.walls[0].openings[0].changeStatus, .demolish)
    }

    func testOrthoSnap() {
        let nearlyHorizontal = Vec2(1, 0.05).normalized
        let snapped = EditorEngine.orthoSnappedDirection(nearlyHorizontal)
        XCTAssertEqual(snapped.y, 0, accuracy: 1e-9)
        // A legitimately angled wall is NOT distorted.
        let angled = Vec2(1, 0.5).normalized
        let kept = EditorEngine.orthoSnappedDirection(angled)
        XCTAssertEqual(kept.x, angled.x, accuracy: 1e-12)
        XCTAssertEqual(kept.y, angled.y, accuracy: 1e-12)
    }

    func testExactDimensionEditWorkflow() {
        // Spec §17: a scanned 12' 6 1/2" wall edited to exactly 12' 7".
        let scanned = 12 * ft + 6.5 * 0.0254
        let target = DimensionParser.parseLength("12' 7\"")!
        let wallA = Wall(start: Vec2(0, 0), end: Vec2(scanned, 0), source: .lidarScanned)
        let wallB = Wall(start: Vec2(scanned, 0), end: Vec2(scanned, 3), source: .lidarScanned)
        let level = LevelGeometry(name: "L", walls: [wallA, wallB])
        let edited = EditorEngine.setWallLength(
            in: level, wallID: wallA.id, newLength: target, strategy: .moveEnd)
        let result = edited.wall(withID: wallA.id)!
        XCTAssertEqual(result.length, target, accuracy: 1e-12)
        XCTAssertEqual(result.originalLength!, scanned, accuracy: 1e-12)
        XCTAssertEqual(UnitFormatter().length(result.length), "12' 7\"")
        // The connected wall followed.
        XCTAssertEqual(edited.wall(withID: wallB.id)!.start.x, target, accuracy: 1e-12)
    }
}
