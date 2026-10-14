import XCTest
@testable import FieldPlanCore

/// Walls are centerlines with a thickness; rooms are the space between faces.
final class PolygonOffsetTests: XCTestCase {

    func testUniformInsetAndOutset() {
        let square = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 4), Vec2(0, 4)]
        let inset = GeometryOps.insetPolygon(square, by: 0.1)!
        XCTAssertEqual(GeometryOps.area(inset), 3.8 * 3.8, accuracy: 1e-9)
        let outset = GeometryOps.insetPolygon(square, by: -0.1)!
        XCTAssertEqual(GeometryOps.area(outset), 4.2 * 4.2, accuracy: 1e-9)
        XCTAssertGreaterThan(GeometryOps.signedArea(outset), 0)
    }

    func testPerEdgeDistances() {
        let rect = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)]
        // Only the bottom edge moves in.
        let result = GeometryOps.insetPolygon(rect, distances: [0.5, 0, 0, 0])!
        let bounds = Rect2(containing: result)
        XCTAssertEqual(bounds.minY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(bounds.maxY, 3, accuracy: 1e-9)
        XCTAssertEqual(bounds.width, 4, accuracy: 1e-9)
    }

    func testClockwiseInputMapsDistancesToTheRightEdges() {
        // Clockwise square; edge 0 is the left side (0,0)→(0,3).
        let cw = [Vec2(0, 0), Vec2(0, 3), Vec2(4, 3), Vec2(4, 0)]
        let result = GeometryOps.insetPolygon(cw, distances: [0.5, 0, 0, 0])!
        let bounds = Rect2(containing: result)
        XCTAssertEqual(bounds.minX, 0.5, accuracy: 1e-9, "the left edge moved in")
        XCTAssertEqual(bounds.width, 3.5, accuracy: 1e-9)
        XCTAssertGreaterThan(GeometryOps.signedArea(result), 0, "result is counter-clockwise")
    }

    func testLShapeKeepsItsCorners() {
        let l = [Vec2(0, 0), Vec2(12, 0), Vec2(12, 9), Vec2(7, 9), Vec2(7, 15), Vec2(0, 15)]
        let inset = GeometryOps.insetPolygon(l, by: 0.1)!
        XCTAssertEqual(inset.count, 6)
        XCTAssertLessThan(GeometryOps.area(inset), GeometryOps.area(l))
        for p in inset { XCTAssertTrue(GeometryOps.polygonContains(l, p)) }
    }

    func testCollapseGivesNil() {
        let thin = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 0.1), Vec2(0, 0.1)]
        XCTAssertNil(GeometryOps.insetPolygon(thin, by: 0.2))
    }

    func testInteriorPolygonHonoursOnlyPlacedWalls() {
        let loop = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)]
        var walls = [
            Wall(start: Vec2(0, 0), end: Vec2(4, 0), thickness: 0.2),
            Wall(start: Vec2(4, 0), end: Vec2(4, 3), thickness: 0.2),
            Wall(start: Vec2(4, 3), end: Vec2(0, 3), thickness: 0.2),
            Wall(start: Vec2(0, 3), end: Vec2(0, 0), thickness: 0.2),
        ]
        // Legacy / sample walls: no inset at all.
        XCTAssertEqual(GeometryOps.area(GeometryCleaner.interiorPolygon(fromCenterlineLoop: loop, walls: walls)), 12, accuracy: 1e-9)
        // Placed walls: each face moves in by half the thickness.
        for i in walls.indices { walls[i].thicknessSource = .assumed }
        let interior = GeometryCleaner.interiorPolygon(fromCenterlineLoop: loop, walls: walls)
        XCTAssertEqual(GeometryOps.area(interior), 3.8 * 2.8, accuracy: 1e-9)
        let outside = GeometryCleaner.outsidePolygon(fromCenterlineLoop: loop, walls: walls)
        XCTAssertEqual(GeometryOps.area(outside), 4.2 * 3.2, accuracy: 1e-9)
    }
}

final class WallAssemblyTests: XCTestCase {

    private func face(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                      confidence: CaptureConfidence = .high, openings: [WallOpening] = []) -> Wall {
        Wall(start: Vec2(x1, y1), end: Vec2(x2, y2), height: 2.4, thickness: 0.1143,
             openings: openings, source: .lidarScanned, confidence: confidence)
    }

    private func room(_ name: String, _ polygon: [Vec2]) -> RoomShape {
        RoomShape(name: name, polygon: polygon)
    }

    func testFacingSurfacesBecomeOneMeasuredWall() {
        let a = face(0, 3, 4, 3, openings: [WallOpening(kind: .door, centerOffset: 1.0, width: 0.8, height: 2.0)])
        let b = face(4.5, 3.12, 0.2, 3.12, confidence: .medium)
        let result = WallAssembly.assemble(walls: [a, b], rooms: [])
        XCTAssertEqual(result.walls.count, 1)
        let wall = result.walls[0]
        XCTAssertEqual(wall.thickness, 0.12, accuracy: 1e-6)
        XCTAssertEqual(wall.thicknessSource, .measured)
        XCTAssertEqual(wall.start.y, 3.06, accuracy: 1e-6, "midway between the faces")
        XCTAssertEqual(wall.length, 4.5, accuracy: 1e-6, "spans both faces")
        XCTAssertEqual(wall.id, a.id, "the higher-confidence face keeps its identity")
        XCTAssertEqual(result.replaced[b.id], a.id)
        XCTAssertEqual(wall.openings.count, 1)
        XCTAssertEqual(wall.openings[0].centerOffset, 1.0, accuracy: 1e-6, "the door stays where it was in the world")
    }

    func testLoneExteriorFaceIsOffsetOutward() {
        let living = room("Living", [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)])
        let south = face(0, 0, 4, 0)
        let result = WallAssembly.assemble(walls: [south], rooms: [living])
        let wall = result.walls[0]
        XCTAssertEqual(wall.thicknessSource, .assumed)
        XCTAssertEqual(wall.thickness, 0.1524, accuracy: 1e-9, "nothing behind it: exterior default")
        XCTAssertEqual(wall.start.y, -0.0762, accuracy: 1e-9, "moved away from the room by half a wall")
        XCTAssertEqual(wall.length, 4, accuracy: 1e-9)
    }

    func testLonePartitionFaceMeasuresToTheNeighboursFloor() {
        // Only one face of the partition was captured, but the room behind
        // it was: its floor edge is the far face, 0.10 m back.
        let living = room("Living", [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)])
        let bedroom = room("Bedroom", [Vec2(0, 3.1), Vec2(4, 3.1), Vec2(4, 6), Vec2(0, 6)])
        let north = face(0, 3, 4, 3)
        let wall = WallAssembly.assemble(walls: [north], rooms: [living, bedroom]).walls[0]
        XCTAssertEqual(wall.thicknessSource, .measured)
        XCTAssertEqual(wall.thickness, 0.10, accuracy: 1e-9)
        XCTAssertEqual(wall.start.y, 3.05, accuracy: 1e-9, "centerline midway between the faces")
    }

    func testLonePartitionWithADistantNeighbourUsesTheInteriorDefault() {
        // A room 0.6 m behind the face: too far to be the far face of this
        // wall, close enough that this is not the outside of the house.
        let living = room("Living", [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)])
        let bedroom = room("Bedroom", [Vec2(0, 3.6), Vec2(4, 3.6), Vec2(4, 6), Vec2(0, 6)])
        let north = face(0, 3, 4, 3)
        let wall = WallAssembly.assemble(walls: [north], rooms: [living, bedroom]).walls[0]
        XCTAssertEqual(wall.thicknessSource, .assumed)
        XCTAssertEqual(wall.thickness, 0.1143, accuracy: 1e-9)
        XCTAssertEqual(wall.start.y, 3 + 0.1143 / 2, accuracy: 1e-9)
    }

    func testFaceInsideOneFloorPolygonIsLeftUnplaced() {
        // One capture, one floor polygon spanning both rooms, one face for
        // the partition: nothing says which side it bounds.
        let whole = room("Whole", [Vec2(0, 0), Vec2(4, 0), Vec2(4, 6), Vec2(0, 6)])
        let wall = WallAssembly.assemble(walls: [face(0, 3, 4, 3)], rooms: [whole]).walls[0]
        XCTAssertNil(wall.thicknessSource)
        XCTAssertEqual(wall.start.y, 3, accuracy: 1e-9)
    }

    func testFaceSlightlyOffItsFloorEdgeStillFindsItsRoom() {
        // The floor polygon stops 5 cm short of the wall face (typical
        // scanner disagreement); the longer probe still finds the room.
        let living = room("Living", [Vec2(0, 0), Vec2(4, 0), Vec2(4, 2.95), Vec2(0, 2.95)])
        let wall = WallAssembly.assemble(walls: [face(0, 3, 4, 3)], rooms: [living]).walls[0]
        XCTAssertEqual(wall.thicknessSource, .assumed)
        XCTAssertEqual(wall.thickness, 0.1524, accuracy: 1e-9)
        XCTAssertEqual(wall.start.y, 3.0762, accuracy: 1e-9)
    }

    func testUnplaceableFaceIsLeftAndMarked() {
        let wall = WallAssembly.assemble(walls: [face(0, 0, 4, 0)], rooms: []).walls[0]
        XCTAssertNil(wall.thicknessSource)
        XCTAssertEqual(wall.start.y, 0, accuracy: 1e-9)
    }

    func testSameSideDuplicateIsFolded() {
        let a = face(0, 0, 4, 0)
        let b = face(0.1, 0.02, 3.9, 0.02, confidence: .low)
        let result = WallAssembly.assemble(walls: [a, b], rooms: [])
        XCTAssertEqual(result.walls.count, 1)
        XCTAssertEqual(result.replaced[b.id], a.id)
    }

    func testConversionOfTwoRoomsSharingAPartition() {
        // Two 4 m × 3 m rooms side by side; the partition is 0.12 m thick and
        // each room reports its own face of it. World: plan y = -z.
        func surface(_ kind: ScannedSurfaceKind, cx: Double, cz: Double, ax: Double, az: Double, width: Double) -> ScannedSurfaceDTO {
            ScannedSurfaceDTO(kind: kind, center: Vec3(cx, 1.2, cz), xAxis: Vec3(ax, 0, az),
                              width: width, height: 2.4, confidenceLevel: 2)
        }
        func floor(_ corners: [(Double, Double)]) -> ScannedSurfaceDTO {
            let cx = corners.map(\.0).reduce(0, +) / Double(corners.count)
            let cz = corners.map(\.1).reduce(0, +) / Double(corners.count)
            var f = surface(.floor, cx: cx, cz: cz, ax: 1, az: 0, width: 4)
            f.polygonCorners = corners.map { Vec3($0.0, 0, $0.1) }
            f.center = Vec3(cx, 0, cz)
            return f
        }
        // Room A: plan x 0…4, y 0…3 (z 0…-3). Its east face at x = 4.
        let roomA = ScannedRoomDTO(suggestedName: "A", surfaces: [
            surface(.wall, cx: 2, cz: 0, ax: 1, az: 0, width: 4),       // south
            surface(.wall, cx: 4, cz: -1.5, ax: 0, az: -1, width: 3),   // east face
            surface(.wall, cx: 2, cz: -3, ax: 1, az: 0, width: 4),      // north
            surface(.wall, cx: 0, cz: -1.5, ax: 0, az: -1, width: 3),   // west
            floor([(0, 0), (4, 0), (4, -3), (0, -3)]),
        ])
        // Room B: plan x 4.12…8.12. Its west face at x = 4.12.
        let roomB = ScannedRoomDTO(suggestedName: "B", surfaces: [
            surface(.wall, cx: 6.12, cz: 0, ax: 1, az: 0, width: 4),
            surface(.wall, cx: 8.12, cz: -1.5, ax: 0, az: -1, width: 3),
            surface(.wall, cx: 6.12, cz: -3, ax: 1, az: 0, width: 4),
            surface(.wall, cx: 4.12, cz: -1.5, ax: 0, az: -1, width: 3),
            floor([(4.12, 0), (8.12, 0), (8.12, -3), (4.12, -3)]),
        ])
        let result = ScanConversion.convert(rooms: [roomA, roomB])
        XCTAssertEqual(result.walls.count, 7, "eight faces, one shared wall")
        let partition = result.walls.first { $0.thicknessSource == .measured }
        XCTAssertNotNil(partition)
        XCTAssertEqual(partition!.thickness, 0.12, accuracy: 1e-6)
        XCTAssertEqual(partition!.start.x, 4.06, accuracy: 1e-6)
        let exterior = result.walls.filter { $0.thicknessSource == .assumed }
        XCTAssertEqual(exterior.count, 6)
        XCTAssertTrue(exterior.allSatisfy { $0.thickness == 0.1524 })
        // Room polygons come from the floors and stay interior.
        XCTAssertEqual(result.rooms[0].floorArea, 12, accuracy: 1e-6)
        XCTAssertEqual(result.rooms[1].floorArea, 12, accuracy: 1e-6)
        // The south wall of room A was offset outward (plan -y).
        let southA = result.walls.first { abs($0.midpoint.x - 2) < 0.01 && $0.midpoint.y < 0.5 }!
        XCTAssertEqual(southA.start.y, -0.0762, accuracy: 1e-6)
        // Both rooms reference the surviving partition.
        XCTAssertTrue(result.rooms[0].wallIDs.contains(partition!.id))
        XCTAssertTrue(result.rooms[1].wallIDs.contains(partition!.id))
        // Offsetting pulled the corners apart; they were put back, so the
        // walls still close into one footprint. Outside face to outside face
        // that is the 8.12 × 3 clear span plus a 6" wall each side.
        let planar = GeometryCleaner.splitAtJunctions(result.walls)
        let boundary = WallGraph(walls: planar, tolerance: 0.1).exteriorBoundary()
        XCTAssertNotNil(boundary, "the offset walls no longer met at their corners")
        if let boundary {
            let outside = GeometryCleaner.outsidePolygon(fromCenterlineLoop: boundary, walls: planar)
            XCTAssertEqual(GeometryOps.area(outside), (8.12 + 0.3048) * (3 + 0.3048), accuracy: 1e-3)
        }
        // The partition runs on to both exterior centerlines.
        XCTAssertEqual(min(partition!.start.y, partition!.end.y), -0.0762, accuracy: 1e-6)
        XCTAssertEqual(max(partition!.start.y, partition!.end.y), 3.0762, accuracy: 1e-6)
    }

    func testCornersCloseAfterOffsetting() {
        // Three walls of a room offset outward by 3": the two corners open by
        // 0.108 m, the west wall's far end stops 3" short of a partition.
        func wall(_ a: Vec2, _ b: Vec2, openings: [WallOpening] = []) -> Wall {
            Wall(start: a, end: b, height: 2.4, thickness: 0.1524, openings: openings,
                 source: .lidarScanned, confidence: .high, thicknessSource: .assumed)
        }
        let door = WallOpening(kind: .door, centerOffset: 1.0, width: 0.9, height: 2.0)
        let south = wall(Vec2(0, -0.0762), Vec2(4, -0.0762), openings: [door])
        let west = wall(Vec2(-0.0762, 0), Vec2(-0.0762, 3))
        let east = wall(Vec2(4.0762, 0), Vec2(4.0762, 3))
        let partition = wall(Vec2(-1, 3.0762), Vec2(5, 3.0762))
        let closed = WallAssembly.closeCorners([south, west, east, partition])

        XCTAssertEqual(closed[0].start, Vec2(-0.0762, -0.0762), "south-west corner")
        XCTAssertEqual(closed[0].end, Vec2(4.0762, -0.0762), "south-east corner")
        XCTAssertEqual(closed[1].start, Vec2(-0.0762, -0.0762))
        XCTAssertEqual(closed[1].end.y, 3.0762, accuracy: 1e-9, "west wall runs on to the partition centerline")
        XCTAssertEqual(closed[2].end.y, 3.0762, accuracy: 1e-9)
        XCTAssertEqual(closed[3], partition, "the partition itself did not move")
        // The door stayed where it was in the world.
        XCTAssertEqual(closed[0].point(atOffset: closed[0].openings[0].centerOffset).x, 1.0, accuracy: 1e-9)
    }

    func testCollinearNeighboursJoinAndDoorGapsStayOpen() {
        // A's south wall and B's, on the same line 0.12 m apart, join; two
        // walls with a 0.9 m doorway between them are left alone.
        let a = Wall(start: Vec2(0, 0), end: Vec2(4, 0), source: .lidarScanned, thicknessSource: .assumed)
        let b = Wall(start: Vec2(4.12, 0), end: Vec2(8, 0), source: .lidarScanned, thicknessSource: .assumed)
        let joined = WallAssembly.closeCorners([a, b])
        XCTAssertEqual(joined[0].end, joined[1].start)
        XCTAssertEqual(joined[0].end.x, 4.06, accuracy: 1e-9)

        let c = Wall(start: Vec2(0, 0), end: Vec2(4, 0), source: .lidarScanned, thicknessSource: .assumed)
        let d = Wall(start: Vec2(4.9, 0), end: Vec2(8, 0), source: .lidarScanned, thicknessSource: .assumed)
        let apart = WallAssembly.closeCorners([c, d])
        XCTAssertEqual(apart[0].end.x, 4, accuracy: 1e-9)
        XCTAssertEqual(apart[1].start.x, 4.9, accuracy: 1e-9)
    }

    func testSplitRoomsAreInsetFromCenterlines() {
        // A continuous capture: one envelope with a partition, walls already
        // placed as centerlines 0.1 m thick.
        func wall(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Wall {
            Wall(start: Vec2(x1, y1), end: Vec2(x2, y2), height: 2.4, thickness: 0.1,
                 source: .lidarScanned, thicknessSource: .assumed)
        }
        let walls = [wall(0, 0, 8, 0), wall(8, 0, 8, 3), wall(8, 3, 0, 3), wall(0, 3, 0, 0), wall(4, 0, 4, 3)]
        let whole = RoomShape(name: "Living Room", type: .livingRoom,
                              polygon: [Vec2(0, 0), Vec2(8, 0), Vec2(8, 3), Vec2(0, 3)],
                              wallIDs: walls.map(\.id))
        let fixtures = [
            FixtureItem(category: .toilet, center: Vec2(1, 1), size: Vec2(0.5, 0.7), source: .lidarScanned),
            FixtureItem(category: .stove, center: Vec2(6, 1), size: Vec2(0.7, 0.7), source: .lidarScanned),
        ]
        let level = LevelGeometry(name: "L", walls: walls, rooms: [whole], fixtures: fixtures)
        let split = ScanConversion.splitIntoRooms(level)
        XCTAssertEqual(split.rooms.count, 2)
        for room in split.rooms {
            // 4 × 3 between centerlines; 3.9 × 2.9 between faces.
            XCTAssertEqual(room.floorArea, 3.9 * 2.9, accuracy: 1e-6, room.name)
        }
        XCTAssertEqual(Set(split.rooms.map(\.type)), [.bathroom, .kitchen])
    }
}

final class LevelAssignmentTests: XCTestCase {

    func testRoomsAreGroupedByFloorHeight() {
        func room(_ floorY: Double) -> ScannedRoomDTO {
            let floor = ScannedSurfaceDTO(kind: .floor, center: Vec3(0, floorY, 0), xAxis: Vec3(1, 0, 0),
                                          width: 4, height: 3, confidenceLevel: 2)
            return ScannedRoomDTO(suggestedName: nil, surfaces: [floor])
        }
        // Two rooms downstairs, two up, listed out of order, plus one with no
        // floor at all (joins the first group).
        let stray = ScannedRoomDTO(suggestedName: "Closet", surfaces: [])
        let groups = LevelAssignment.groupByFloor([room(-1.4), room(1.6), room(-1.35), room(1.7), stray])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].elevation, -1.35, accuracy: 1e-9)
        XCTAssertEqual(groups[0].rooms.count, 3)
        XCTAssertEqual(groups[1].elevation, 1.7, accuracy: 1e-9)
        XCTAssertEqual(groups[1].rooms.count, 2)
        XCTAssertTrue(LevelAssignment.groupByFloor([]).isEmpty)
    }

    func testFloorElevationIsTheMedianOfFloors() {
        func room(floorY: Double) -> ScannedRoomDTO {
            ScannedRoomDTO(surfaces: [ScannedSurfaceDTO(kind: .floor, center: Vec3(0, floorY, 0), xAxis: Vec3(1, 0, 0), width: 3, height: 0)])
        }
        XCTAssertEqual(LevelAssignment.floorElevation(of: [room(floorY: -1.4), room(floorY: -1.5), room(floorY: 1.7)]) ?? 9, -1.4, accuracy: 1e-9)
        XCTAssertNil(LevelAssignment.floorElevation(of: []))
    }

    func testAssignmentRules() {
        var first = LevelGeometry(name: "First Floor", storyIndex: 0)
        let selectedWithoutElevation = LevelAssignment.assign(elevation: -1.4, selectedLevelID: first.id, levels: [first])!
        XCTAssertEqual(selectedWithoutElevation.levelID, first.id)
        XCTAssertNil(selectedWithoutElevation.createdLevel)

        first.elevation = -1.4
        let same = LevelAssignment.assign(elevation: -1.1, selectedLevelID: first.id, levels: [first])!
        XCTAssertEqual(same.levelID, first.id)
        XCTAssertNil(same.message)

        let upstairs = LevelAssignment.assign(elevation: 1.6, selectedLevelID: first.id, levels: [first])!
        XCTAssertNotNil(upstairs.createdLevel)
        XCTAssertEqual(upstairs.createdLevel?.name, "Second Floor")
        XCTAssertEqual(upstairs.createdLevel?.storyIndex, 1)
        XCTAssertEqual(upstairs.createdLevel?.elevation ?? 0, 1.6, accuracy: 1e-9)
        XCTAssertNotNil(upstairs.message)

        let basement = LevelAssignment.assign(elevation: -4.2, selectedLevelID: first.id, levels: [first])!
        XCTAssertEqual(basement.createdLevel?.name, "Basement")
        XCTAssertEqual(basement.createdLevel?.storyIndex, -1)

        var second = LevelGeometry(name: "Second Floor", storyIndex: 1)
        second.elevation = 1.5
        let existing = LevelAssignment.assign(elevation: 1.7, selectedLevelID: first.id, levels: [first, second])!
        XCTAssertEqual(existing.levelID, second.id)
        XCTAssertNil(existing.createdLevel)
        XCTAssertNotNil(existing.message)
    }
}

final class LevelRegistrationTests: XCTestCase {

    func testTranslationAndRotationPreserveGeometry() {
        var level = SampleFixtures.apartment()
        level.northAngle = 0.2
        let moved = LevelRegistration.translated(level, by: Vec2(3, -2))
        XCTAssertEqual(moved.rooms[0].floorArea, level.rooms[0].floorArea, accuracy: 1e-9)
        XCTAssertEqual(moved.walls[0].length, level.walls[0].length, accuracy: 1e-9)
        XCTAssertEqual(moved.walls[0].start.x, level.walls[0].start.x + 3, accuracy: 1e-9)

        let turned = LevelRegistration.rotated(level, by: .pi / 2, about: .zero)
        XCTAssertEqual(turned.rooms[0].floorArea, level.rooms[0].floorArea, accuracy: 1e-9)
        let corner = level.walls[0].end
        let turnedCorner = turned.walls[0].end
        XCTAssertEqual(turnedCorner.x, -corner.y, accuracy: 1e-9)
        XCTAssertEqual(turnedCorner.y, corner.x, accuracy: 1e-9)
        XCTAssertEqual(turned.northAngle ?? 0, 0.2 + .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(turned.fixtures[0].rotation, level.fixtures[0].rotation + .pi / 2, accuracy: 1e-9)
    }

    func testStairsAlignFloors() {
        let ft = UnitConstants.metersPerFoot
        var lower = SampleFixtures.apartment()
        lower.fixtures.append(FixtureItem(category: .stairs, center: Vec2(2 * ft, 14 * ft), size: Vec2(1, 3)))
        var upper = SampleFixtures.reidentified(SampleFixtures.apartment(twoBedroom: true))
        upper = LevelRegistration.translated(upper, by: Vec2(1.5, -0.7))   // scanned in another session
        upper.fixtures.append(FixtureItem(category: .stairs, center: Vec2(2 * ft + 1.5, 14 * ft - 0.7), size: Vec2(1, 3)))

        let aligned = LevelRegistration.alignByStairs(upper, to: lower)!
        XCTAssertEqual(aligned.shift.x, -1.5, accuracy: 1e-9)
        XCTAssertEqual(aligned.shift.y, 0.7, accuracy: 1e-9)
        XCTAssertEqual(aligned.level.walls[0].start.x, lower.walls[0].start.x, accuracy: 1e-9)

        XCTAssertNil(LevelRegistration.alignByStairs(SampleFixtures.apartment(), to: lower))
        let footprint = LevelRegistration.alignByFootprint(upper, to: lower)!
        XCTAssertEqual(footprint.shift.x, -1.5, accuracy: 1e-9)
    }
}

final class WallFitterTests: XCTestCase {

    /// A noisy vertical wall face along plan y = `y` from x0 to x1.
    private func wallMesh(y: Double, x0: Double, x1: Double, noise: Double = 0.01) -> MeshChunk {
        var vertices: [Float] = []
        var faces: [UInt32] = []
        var seed: UInt64 = 42
        func jitter() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double((seed >> 33) % 1000) / 1000 - 0.5) * 2 * noise
        }
        let columns = Int((x1 - x0) / 0.1)
        for c in 0...columns {
            let x = x0 + Double(c) * 0.1
            for r in 0...20 {
                let h = Double(r) * 0.12
                vertices.append(contentsOf: [Float(x), Float(h), Float(-(y + jitter()))])
            }
        }
        for c in 0..<columns {
            for r in 0..<20 {
                let a = UInt32(c * 21 + r)
                let b = a + 21
                faces.append(contentsOf: [a, a + 1, b, a + 1, b + 1, b])
            }
        }
        return MeshChunk(anchorID: UUID(), transform: PoseSample.identity, vertices: vertices, faces: faces,
                         classification: Array(repeating: MeshFaceClass.wall.rawValue, count: faces.count / 3))
    }

    func testFitRecoversTheWallFromNoisyMesh() {
        let chunk = wallMesh(y: 3, x0: 0, x1: 4)
        let wall = Wall(start: Vec2(0.02, 3.03), end: Vec2(3.97, 3.03), source: .lidarScanned)
        let fit = WallFitter.fit(wall: wall, chunks: [chunk], floorElevation: 0)!
        XCTAssertEqual(fit.length, 4, accuracy: 0.15)
        XCTAssertLessThan(fit.residual, 0.02)
        XCTAssertEqual(fit.start.y, 3, accuracy: 0.01)
        XCTAssertGreaterThan(fit.inlierCount, 200)
        XCTAssertEqual(fit.alternate.method, "meshLineFit")
    }

    func testNoMeshMeansNoFit() {
        let wall = Wall(start: Vec2(0, 0), end: Vec2(4, 0), source: .lidarScanned)
        XCTAssertNil(WallFitter.fit(wall: wall, chunks: [wallMesh(y: 5, x0: 0, x1: 4)], floorElevation: 0))
    }

    func testEvidenceCarriesTheAlternate() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 4 / UnitConstants.metersPerFoot,
                                                   depthFeet: 3 / UnitConstants.metersPerFoot)
        for i in level.walls.indices { level.walls[i].source = .lidarScanned }
        let scored = EvidenceAttachment.attach(to: level, grid: nil, chunks: [wallMesh(y: 3, x0: 0, x1: 4)],
                                               trackingNormalFraction: 1, sessionID: nil)
        let north = scored.walls.first { abs($0.midpoint.y - 3) < 0.01 }!
        XCTAssertNotNil(north.evidence?.alternate)
        XCTAssertEqual(north.evidence?.alternate?.value ?? 0, 4, accuracy: 0.15)
        let south = scored.walls.first { abs($0.midpoint.y) < 0.01 }!
        XCTAssertNil(south.evidence?.alternate)
    }
}

final class MigrationTests: XCTestCase {

    func testLegacyScannedWallsMoveToCenterlines() {
        let living = RoomShape(name: "Living", polygon: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)])
        let bedroom = RoomShape(name: "Bedroom", polygon: [Vec2(0, 3.12), Vec2(4, 3.12), Vec2(4, 6), Vec2(0, 6)])
        let south = Wall(start: Vec2(0, 0), end: Vec2(4, 0), thickness: 0.15, source: .lidarScanned)
        let partition = Wall(start: Vec2(0, 3), end: Vec2(4, 3), thickness: 0.1143, source: .lidarScanned)
        let sample = Wall(start: Vec2(4, 0), end: Vec2(4, 3), source: .sampleData)
        let level = LevelGeometry(name: "L", walls: [south, partition, sample], rooms: [living, bedroom])
        let snapshot = PlanSnapshot(name: "Existing", kind: .existingConditions, levels: [level])

        let migrated = GeometryMigration.migrate(snapshot)
        XCTAssertEqual(migrated.schemaVersion, 2)
        let walls = migrated.levels[0].walls
        XCTAssertEqual(walls[0].start.y, -0.075, accuracy: 1e-9, "exterior face moves away from the room")
        XCTAssertEqual(walls[0].thicknessSource, .assumed)
        XCTAssertEqual(walls[1].start.y, 3.06, accuracy: 1e-9, "partition moves midway between the two faces")
        XCTAssertEqual(walls[1].thickness, 0.12, accuracy: 1e-9)
        XCTAssertEqual(walls[1].thicknessSource, .measured)
        XCTAssertEqual(walls[2].start.x, 4, accuracy: 1e-9, "sample data is untouched")
        XCTAssertNil(walls[2].thicknessSource)

        XCTAssertEqual(GeometryMigration.migrate(migrated), migrated, "idempotent")
    }

    func testTouchingRoomsLeaveTheWallAlone() {
        let a = RoomShape(name: "A", polygon: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)])
        let b = RoomShape(name: "B", polygon: [Vec2(0, 3), Vec2(4, 3), Vec2(4, 6), Vec2(0, 6)])
        let wall = Wall(start: Vec2(0, 3), end: Vec2(4, 3), source: .lidarScanned)
        let level = LevelGeometry(name: "L", walls: [wall], rooms: [a, b])
        let migrated = GeometryMigration.surfaceLinesToCenterlines(level)
        XCTAssertEqual(migrated.walls[0].start.y, 3, accuracy: 1e-9)
        XCTAssertNil(migrated.walls[0].thicknessSource)
    }

    func testArchiveDecodeMigrates() throws {
        var archive = SampleFixtures.sampleProject()
        archive.snapshots[0].schemaVersion = nil
        let data = try archive.jsonData()
        let decoded = try ProjectArchive.decode(from: data)
        XCTAssertEqual(decoded.snapshots[0].schemaVersion, GeometryMigration.currentSchemaVersion)
    }
}

final class DimensionTests: XCTestCase {

    private func texts(in scene: PlanScene) -> [String] {
        scene.layer(.dimensions)?.primitives.compactMap { primitive -> String? in
            if case .text(let string, _, _, _, _, _) = primitive { return string }
            return nil
        } ?? []
    }

    func testRectangleReadsOutsideFacesNotCenterlines() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 10)
        // Real walls: 6" thick, centerlines 3" outside the room polygon.
        let outside = GeometryOps.insetPolygon(level.rooms[0].polygon, by: -0.0762)!
        for i in level.walls.indices {
            level.walls[i].start = outside[i]
            level.walls[i].end = outside[(i + 1) % 4]
            level.walls[i].thickness = 0.1524
            level.walls[i].thicknessSource = .assumed
        }
        var options = PlanGenerator.Options()
        options.showDimensions = true
        options.showRoomDimensions = false   // chains instead of a label size
        let labels = texts(in: PlanGenerator.scene(for: level, options: options))
        // The room's 12' × 10' is on its label; outside, the overall width
        // and depth are outside-face to outside-face — 13' 0" and 11' 0",
        // never the 12' 6" × 10' 6" between centerlines.
        XCTAssertEqual(Set(labels), ["13' 0\"", "11' 0\""], "\(labels)")
        XCTAssertEqual(labels.count, 2, "\(labels)")

        options.interiorDimensions = .all
        let every = texts(in: PlanGenerator.scene(for: level, options: options))
        XCTAssertEqual(every.filter { $0 == "12' 0\"" }.count, 2, "\(every)")
        XCTAssertEqual(every.filter { $0 == "10' 0\"" }.count, 2, "\(every)")
    }

    func testJoggedRoomIsDimensionedFaceToFace() {
        // An L-shaped room, 4 m × 3 m less a 2 m × 1 m bite at the top right.
        let polygon = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 2), Vec2(2, 2), Vec2(2, 3), Vec2(0, 3)]
        var walls: [Wall] = []
        for i in 0..<polygon.count {
            walls.append(Wall(start: polygon[i], end: polygon[(i + 1) % polygon.count], source: .lidarScanned))
        }
        let room = RoomShape(name: "Family Room", type: .livingRoom, polygon: polygon, wallIDs: walls.map(\.id))
        let level = LevelGeometry(name: "L", walls: walls, rooms: [room])
        var options = PlanGenerator.Options()
        options.showDimensions = true
        options.showRoomDimensions = false   // chains instead of a label size
        let labels = texts(in: PlanGenerator.scene(for: level, options: options))
        // Inside: every edge (all ≥ 1 m). Outside: the four faces that jog
        // plus the overall 4 m width and 3 m depth; the full-span bottom and
        // left faces are read from the overalls.
        XCTAssertEqual(labels.filter { $0 == "13' 1 1/2\"" }.count, 2, "4 m: inside bottom edge + overall width: \(labels)")
        XCTAssertEqual(labels.filter { $0 == "9' 10 1/8\"" }.count, 2, "3 m: inside left edge + overall depth: \(labels)")
        XCTAssertEqual(labels.filter { $0 == "6' 6 3/4\"" }.count, 6, "2 m: three edges inside, three faces outside: \(labels)")
        XCTAssertEqual(labels.filter { $0 == "3' 3 3/8\"" }.count, 2, "1 m: the jog inside and out: \(labels)")
        XCTAssertEqual(labels.count, 12, "\(labels)")
    }

    func testSmallRoomsKeepTheirInteriorDimensionsOffThePlan() {
        let level = SampleFixtures.bathroom()   // 5' × 8'
        var options = PlanGenerator.Options()
        options.showDimensions = true
        let scene = PlanGenerator.scene(for: level, options: options)
        let labels = texts(in: scene)
        // Only the overall extents: 5' and 8' once each, outside the room.
        XCTAssertEqual(labels.filter { $0 == "5' 0\"" }.count, 1, "\(labels)")
        XCTAssertEqual(labels.filter { $0 == "8' 0\"" }.count, 1, "\(labels)")
        XCTAssertEqual(labels.count, 2, "\(labels)")
    }

    func testPolygonBasedWallAreaIgnoresCenterlineGrowth() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 10)
        let ft = UnitConstants.metersPerFoot
        let before = RoomCalculations.compute(room: level.rooms[0], in: level)
        XCTAssertEqual(before.grossWallArea, 44 * ft * 8 * ft, accuracy: 1e-9)
        let outside = GeometryOps.insetPolygon(level.rooms[0].polygon, by: -0.0762)!
        for i in level.walls.indices {
            level.walls[i].start = outside[i]
            level.walls[i].end = outside[(i + 1) % 4]
            level.walls[i].thicknessSource = .assumed
        }
        let after = RoomCalculations.compute(room: level.rooms[0], in: level)
        XCTAssertEqual(after.grossWallArea, before.grossWallArea, accuracy: 1e-9,
                       "the painted faces did not change when the centerlines moved")
        XCTAssertEqual(after.wallLengths.reduce(0, +), 44 * ft, accuracy: 1e-9)
    }
}
