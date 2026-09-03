import XCTest
@testable import FieldPlanCore

/// Missing-space detection reasons about what is absent from a plan. A
/// complete apartment must produce nothing; removing a room must show the
/// hole and the door that leads into it.
final class MissingSpaceTests: XCTestCase {

    let ft = UnitConstants.metersPerFoot

    func testCompleteApartmentHasNoFindings() {
        let level = SampleFixtures.apartment()
        let findings = MissingSpaceDetector.findings(for: level)
        XCTAssertTrue(findings.isEmpty, "\(findings.map { "\($0.kind): \($0.message)" })")
    }

    func testRemovedBathroomLeavesAVoidAndADoorwayToIt() {
        var level = SampleFixtures.apartment()
        let bath = level.rooms.first { $0.type == .bathroom }!
        level.rooms.removeAll { $0.id == bath.id }
        level.fixtures.removeAll { $0.roomID == bath.id }

        let findings = MissingSpaceDetector.findings(for: level)
        let voids = findings.filter { $0.kind == .footprintVoid }
        XCTAssertEqual(voids.count, 1, "\(findings.map(\.kind))")
        let void = voids[0]
        // The bathroom was 5' × 6' = 30 sq ft.
        XCTAssertEqual((void.estimatedArea ?? 0) / UnitConstants.squareMetersPerSquareFoot, 30, accuracy: 4)
        XCTAssertTrue(GeometryOps.polygonContains(bath.polygon, void.location))
        XCTAssertEqual(void.region.count, 4)
        XCTAssertFalse(void.cells.isEmpty)

        let doorways = findings.filter { $0.kind == .doorwayToUnscannedSpace }
        XCTAssertEqual(doorways.count, 1, "only the hall→bath door leads into the void")
        XCTAssertTrue(GeometryOps.polygonContains(bath.polygon, doorways[0].location))
    }

    func testExteriorDoorIsNotAFinding() {
        let level = SampleFixtures.simpleBedroom()
        let findings = MissingSpaceDetector.findings(for: level)
        XCTAssertTrue(findings.filter { $0.kind == .doorwayToUnscannedSpace }.isEmpty)
    }

    func testRoomEdgeWithoutAWallIsFlagged() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 10)
        // Drop the north wall; the room polygon keeps its edge.
        let north = level.walls[2]
        level.walls.removeAll { $0.id == north.id }
        level.rooms[0].wallIDs.removeAll { $0 == north.id }
        let findings = MissingSpaceDetector.findings(for: level)
        let open = findings.filter { $0.kind == .openRoomEdge }
        XCTAssertEqual(open.count, 1, "\(findings.map(\.kind))")
        XCTAssertEqual(open[0].location.y, 10 * ft, accuracy: 1e-6)
        XCTAssertEqual(open[0].region.count, 2)
    }

    func testOpenPlanBoundaryBetweenTwoRoomsIsFine() {
        // Two rooms side by side sharing an edge with no wall between them,
        // walls only around the outside.
        func wall(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Wall {
            Wall(start: Vec2(x1 * ft, y1 * ft), end: Vec2(x2 * ft, y2 * ft), source: .lidarScanned)
        }
        let walls = [wall(0, 0, 20, 0), wall(20, 0, 20, 12), wall(20, 12, 0, 12), wall(0, 12, 0, 0)]
        let living = RoomShape(name: "Living Room", type: .livingRoom,
                               polygon: [Vec2(0, 0), Vec2(10 * ft, 0), Vec2(10 * ft, 12 * ft), Vec2(0, 12 * ft)])
        let dining = RoomShape(name: "Dining Room", type: .diningRoom,
                               polygon: [Vec2(10 * ft, 0), Vec2(20 * ft, 0), Vec2(20 * ft, 12 * ft), Vec2(10 * ft, 12 * ft)])
        let level = LevelGeometry(name: "L1", walls: walls, rooms: [living, dining])
        let findings = MissingSpaceDetector.findings(for: level)
        XCTAssertTrue(findings.isEmpty, "\(findings.map { "\($0.kind): \($0.message)" })")
    }

    func testStairsWithoutAnAdjacentLevelAreFlagged() {
        var level = SampleFixtures.apartment()
        level.fixtures.append(FixtureItem(category: .stairs, center: Vec2(2 * ft, 8 * ft),
                                          size: Vec2(3 * ft, 10 * ft), source: .lidarScanned))
        let alone = MissingSpaceDetector.findings(for: level, levels: [level])
        XCTAssertEqual(alone.filter { $0.kind == .stairsToUnscannedLevel }.count, 1)

        var upper = SampleFixtures.apartment(twoBedroom: true)
        upper.storyIndex = 1
        let paired = MissingSpaceDetector.findings(for: level, levels: [level, upper])
        XCTAssertTrue(paired.filter { $0.kind == .stairsToUnscannedLevel }.isEmpty)
    }

    func testFootprintRasterClassifiesCells() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        let raster = FootprintRaster(level: level)
        XCTAssertEqual(raster.kind(at: Vec2(5 * ft, 5 * ft)), .room)
        XCTAssertEqual(raster.kind(at: Vec2(-0.5, -0.5)), .outside)
        XCTAssertEqual(raster.kind(at: Vec2(5 * ft, 0)), .wall)
        XCTAssertTrue(raster.unexplainedClusters().isEmpty)
    }

    func testFindingsRenderOnThePlan() {
        var level = SampleFixtures.apartment()
        let bath = level.rooms.first { $0.type == .bathroom }!
        level.rooms.removeAll { $0.id == bath.id }
        var options = PlanGenerator.Options()
        options.findings = MissingSpaceDetector.findings(for: level)
        options.photoMarkers = [PlanPhotoMarker(position: Vec2(2, 2), heading: 0.5, label: "1")]
        let scene = PlanGenerator.scene(for: level, options: options)
        XCTAssertNotNil(scene.layer(.findings))
        XCTAssertNotNil(scene.layer(.photos))
        XCTAssertFalse(scene.layer(.findings)!.primitives.isEmpty)
        let svg = SVGExporter.svg(for: scene)
        XCTAssertTrue(svg.contains("id=\"findings\""))
        XCTAssertTrue(svg.contains("UNSCANNED?"))
        let dxf = DXFExporter.dxf(for: scene)
        XCTAssertFalse(dxf.contains("UNSCANNED"), "review aids never reach CAD")
    }
}
