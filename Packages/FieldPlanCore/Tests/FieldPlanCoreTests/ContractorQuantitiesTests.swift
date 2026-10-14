import XCTest
@testable import FieldPlanCore

final class ContractorQuantitiesTests: XCTestCase {

    private let ft = UnitConstants.metersPerFoot
    private let sqft = UnitConstants.squareMetersPerSquareFoot
    private let cuft = UnitConstants.cubicMetersPerCubicFoot

    func testRoomRollupsReadThePaintedFaces() {
        // 10' × 10' × 8' bathroom: a 3' × 6'-8" door and a 3' × 4' window
        // with a 3' sill; toilet and sink staying, tub coming out.
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10, name: "Bath", type: .bathroom)
        level.walls[0].openings = [WallOpening(kind: .door, centerOffset: 1.0, width: 3 * ft, height: 80 * 0.0254)]
        level.walls[1].openings = [WallOpening(kind: .window, centerOffset: 1.5, width: 3 * ft, height: 4 * ft, sillHeight: 3 * ft)]
        level.fixtures = [
            FixtureItem(category: .toilet, center: Vec2(1, 1), size: Vec2(0.5, 0.7)),
            FixtureItem(category: .sink, center: Vec2(2, 1), size: Vec2(0.6, 0.5)),
            FixtureItem(category: .bathtub, center: Vec2(1, 2.5), size: Vec2(1.5, 0.7), changeStatus: .demolish),
        ]
        let q = ContractorQuantities.compute(room: level.rooms[0], in: level)
        XCTAssertEqual(q.floorArea / sqft, 100, accuracy: 0.01)
        XCTAssertEqual(q.paintableWallArea / sqft, 320 - 20 - 12, accuracy: 0.01)
        XCTAssertEqual(q.wallTileArea / sqft, 280 - 20 - 12, accuracy: 0.01, "to 7': the door and the window's 3'–7' band come out")
        XCTAssertEqual(q.wainscotArea / sqft, 160 - 12 - 3, accuracy: 0.01, "to 4': the door's lower 4' and the window's 3'–4' band")
        XCTAssertEqual(q.volume / cuft, 800, accuracy: 0.01)
        XCTAssertEqual(q.fixtureCounts["toilet"], 1)
        XCTAssertEqual(q.fixtureCounts["sink"], 1)
        XCTAssertNil(q.fixtureCounts["bathtub"])
        XCTAssertEqual(q.demolishedFixtureCounts["bathtub"], 1)
        XCTAssertTrue(q.isWetRoom)
        XCTAssertEqual(q.fixtureSummary, "1 toilet, 1 sink")
        XCTAssertEqual(q.doorCount, 1)
        XCTAssertEqual(q.windowCount, 1)
    }

    func testSummaryAddsUpAndTilesOnlyWetRooms() {
        let bath = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10, name: "Bath", type: .bathroom)
        let bed = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 10, name: "Bedroom", type: .bedroom)
        let summary = ContractorSummary.compute(levels: [bath, bed])
        XCTAssertEqual(summary.rooms.count, 2)
        XCTAssertEqual(summary.floorArea / sqft, 220, accuracy: 0.01)
        XCTAssertEqual(summary.paintableWallArea / sqft, 320 + 352, accuracy: 0.01)
        XCTAssertEqual(summary.wetWallTileArea / sqft, 280, accuracy: 0.01, "only the bathroom")
        XCTAssertEqual(summary.volume / cuft, 800 + 960, accuracy: 0.01)
    }

    func testOpeningScheduleMarksHandsAndRooms() {
        // A 4 m × 3 m room. Wall 0 runs along the bottom, left to right, so
        // its positive side is the room. A door hinged at the wall's start
        // that swings into the room: viewed from outside (the push side) the
        // hinges are on the left — a left-hand door.
        let corners = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)]
        var walls = (0..<4).map { Wall(start: corners[$0], end: corners[($0 + 1) % 4], source: .lidarScanned) }
        walls[0].openings = [
            WallOpening(kind: .door, centerOffset: 1.0, width: 0.9, height: 2.0,
                        swing: DoorSwing(hingeAtStart: true, opensPositiveSide: true)),
        ]
        walls[2].openings = [WallOpening(kind: .window, centerOffset: 1.5, width: 1.2, height: 1.2, sillHeight: 0.9)]
        walls[1].openings = [WallOpening(kind: .opening, centerOffset: 1.5, width: 1.0, height: 2.1)]
        let room = RoomShape(name: "Study", type: .office, polygon: corners, wallIDs: walls.map(\.id))
        let level = LevelGeometry(name: "First Floor", walls: walls, rooms: [room])

        let rows = OpeningSchedule.rows(levels: [level])
        XCTAssertEqual(rows.map(\.mark), ["D1", "W1", "O1"])
        XCTAssertEqual(rows[0].hand, "LH")
        XCTAssertEqual(rows[0].swingsInto, "Study")
        XCTAssertEqual(rows[0].rooms.first, "Study")
        XCTAssertEqual(rows[0].style, .hinged)
        XCTAssertEqual(rows[1].sillHeight, 0.9, accuracy: 1e-9)
        XCTAssertNil(rows[1].hand)
        XCTAssertEqual(rows[2].kind, .opening)

        // Hinge at the far jamb: right-hand. A sliding door has no hand.
        walls[0].openings[0].swing = DoorSwing(hingeAtStart: false, opensPositiveSide: true)
        walls[0].openings.append(WallOpening(kind: .door, centerOffset: 3.0, width: 1.5, height: 2.0, style: .sliding))
        let again = OpeningSchedule.rows(levels: [LevelGeometry(name: "L", walls: walls, rooms: [room])])
        XCTAssertEqual(again[0].hand, "RH")
        XCTAssertNil(again[1].hand)
        XCTAssertEqual(again[1].notes, "sliding")
        XCTAssertEqual(again[1].mark, "D2")
    }

    func testCSVSchedulesCarryTheColumns() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10, name: "Bath", type: .bathroom)
        level.walls[0].openings = [WallOpening(kind: .door, centerOffset: 1.0, width: 0.9, height: 2.0)]
        let openings = CSVExporter.openingSchedule(levels: [level])
        XCTAssertTrue(openings.hasPrefix("Mark,Level,Kind,Style,Width,Height,Sill"))
        XCTAssertTrue(openings.contains("D1,Level,Door,Hinged"), openings)
        let quantities = CSVExporter.contractorQuantities(levels: [level])
        XCTAssertTrue(quantities.contains("Bath"))
        XCTAssertTrue(quantities.contains("cu ft"))
    }
}
