import XCTest
@testable import FieldPlanCore

/// RoomPlan returns a continuous walk as ONE captured room, so a scan of four
/// spaces arrived as a single 400-sq-ft space classified from every object at
/// once — the whole apartment came back labelled "Living Room". These cover
/// recovering the real rooms from the wall graph.
final class RoomSplitTests: XCTestCase {

    let ft = UnitConstants.metersPerFoot

    /// Living room + hallway + bathroom + kitchen, captured as one room, with
    /// the walls that actually divide them.
    private func oneCaptureFourSpaces() -> LevelGeometry {
        func wall(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Wall {
            Wall(start: Vec2(x1 * ft, y1 * ft), end: Vec2(x2 * ft, y2 * ft),
                 height: 2.44, thickness: 0.1, source: .lidarScanned)
        }
        // 20' x 24' envelope, split into four enclosed spaces.
        var walls = [
            wall(0, 0, 20, 0), wall(20, 0, 20, 24), wall(20, 24, 0, 24), wall(0, 24, 0, 0),
            wall(0, 14, 20, 14),          // living room (north) from the rest
            wall(0, 7, 20, 7),            // hallway band between
            wall(10, 0, 10, 7),           // bathroom | kitchen
        ]
        for index in walls.indices { walls[index].source = .lidarScanned }

        func fixture(_ category: FixtureCategory, _ x: Double, _ y: Double) -> FixtureItem {
            FixtureItem(category: category, center: Vec2(x * ft, y * ft),
                        size: Vec2(0.6, 0.6), source: .lidarScanned)
        }
        let fixtures = [
            fixture(.sofa, 10, 19), fixture(.television, 10, 22),   // living room
            fixture(.toilet, 5, 3), fixture(.bathtub, 5, 5),        // bathroom
            fixture(.stove, 15, 3), fixture(.refrigerator, 15, 5),  // kitchen
        ]
        // One scanned room covering everything, as RoomPlan delivers it.
        let whole = RoomShape(
            name: "Living Room", type: .livingRoom,
            polygon: [Vec2(0, 0), Vec2(20 * ft, 0), Vec2(20 * ft, 24 * ft), Vec2(0, 24 * ft)],
            ceilingHeight: 2.44, ceilingHeightSource: .lidarScanned,
            wallIDs: walls.map(\.id))
        return LevelGeometry(name: "Level 1", walls: walls, rooms: [whole], fixtures: fixtures)
    }

    func testOneCaptureBecomesFourTypedRooms() {
        let level = ScanConversion.splitIntoRooms(oneCaptureFourSpaces())
        XCTAssertEqual(level.rooms.count, 4, "expected the enclosed spaces to be recovered")

        let types = Set(level.rooms.map(\.type))
        XCTAssertTrue(types.contains(.bathroom), "a toilet and a tub make a bathroom: \(types)")
        XCTAssertTrue(types.contains(.kitchen), "a range and a refrigerator make a kitchen: \(types)")
        XCTAssertTrue(types.contains(.livingRoom), "a sofa and a television make a living room: \(types)")

        // The whole floor is still accounted for, and no room spans everything.
        let total = level.rooms.reduce(0.0) { $0 + $1.floorArea }
        XCTAssertEqual(total / UnitConstants.squareMetersPerSquareFoot, 480, accuracy: 12)
        XCTAssertTrue(level.rooms.allSatisfy { $0.floorArea < 0.75 * total },
                      "no single room should cover the whole capture")
    }

    func testFixturesAreReassignedToTheirRoom() {
        let level = ScanConversion.splitIntoRooms(oneCaptureFourSpaces())
        let byID = Dictionary(uniqueKeysWithValues: level.rooms.map { ($0.id, $0) })
        for fixture in level.fixtures {
            guard let roomID = fixture.roomID, let room = byID[roomID] else {
                XCTFail("\(fixture.category) was left unassigned")
                continue
            }
            XCTAssertTrue(GeometryOps.polygonContains(room.polygon, fixture.center))
        }
        // The toilet must land in the room typed as a bathroom.
        let toilet = level.fixtures.first { $0.category == .toilet }!
        XCTAssertEqual(byID[toilet.roomID!]?.type, .bathroom)
    }

    func testNamesFollowTheDetectedTypes() {
        let captured = oneCaptureFourSpaces()
        let conversion = ScanConversion.ConversionResult(
            rooms: captured.rooms, walls: captured.walls, fixtures: captured.fixtures)
        let merged = ScanConversion.merge(conversion, into: LevelGeometry(name: "Level 1"))
        let names = Set(merged.rooms.map { $0.name })
        XCTAssertTrue(names.contains("Bathroom"), "\(names)")
        XCTAssertTrue(names.contains("Kitchen"), "\(names)")
        XCTAssertTrue(names.contains("Living Room"), "\(names)")
        XCTAssertFalse(merged.rooms.allSatisfy { $0.name == "Living Room" },
                       "every room named Living Room is the bug being fixed")
    }

    /// A scan whose walls do not close must not lose the rooms it did capture.
    func testIncompleteWallsLeaveRoomsAlone() {
        var level = oneCaptureFourSpaces()
        level.walls.removeLast(4)      // break the enclosures
        let split = ScanConversion.splitIntoRooms(level)
        XCTAssertEqual(split.rooms.count, level.rooms.count)
        XCTAssertEqual(split.rooms.first?.name, "Living Room")
    }

    func testSingleRoomCaptureIsUnchanged() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 15,
                                                   name: "Bedroom", type: .bedroom)
        let split = ScanConversion.splitIntoRooms(level)
        XCTAssertEqual(split.rooms.count, 1)
        XCTAssertEqual(split.rooms[0].name, "Bedroom")
    }
}
