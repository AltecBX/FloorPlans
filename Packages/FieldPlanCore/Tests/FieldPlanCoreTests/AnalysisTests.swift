import XCTest
@testable import FieldPlanCore

final class RoomCalculationsTests: XCTestCase {

    let ft = UnitConstants.metersPerFoot
    let sqft = UnitConstants.squareMetersPerSquareFoot

    func testRectangularRoomQuantities() {
        // 12' × 15', 8' ceiling, one 2.5' door, one 3'×4' window.
        var level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 15, name: "BR", type: .bedroom)
        level.walls[0].openings = [
            WallOpening(kind: .door, centerOffset: 2 * ft, width: 2.5 * ft, height: 6.6667 * ft)
        ]
        level.walls[2].openings = [
            WallOpening(kind: .window, centerOffset: 6 * ft, width: 3 * ft, height: 4 * ft, sillHeight: 2.5 * ft)
        ]
        let calc = RoomCalculations.compute(room: level.rooms[0], in: level)

        XCTAssertEqual(calc.floorArea / sqft, 180, accuracy: 1e-6)
        XCTAssertEqual(calc.ceilingArea / sqft, 180, accuracy: 1e-6)
        XCTAssertEqual(calc.perimeter / ft, 54, accuracy: 1e-6)
        XCTAssertEqual(calc.ceilingHeight! / ft, 8, accuracy: 1e-6)

        // Gross wall area = perimeter × height = 54 × 8 = 432 sq ft.
        XCTAssertEqual(calc.grossWallArea / sqft, 432, accuracy: 1e-6)
        // Window 12 sq ft; door 2.5 × 6.6667 = 16.667 sq ft.
        XCTAssertEqual(calc.windowArea / sqft, 12, accuracy: 1e-3)
        XCTAssertEqual(calc.doorAndOpeningArea / sqft, 16.667, accuracy: 1e-2)
        XCTAssertEqual(calc.netWallArea / sqft, 432 - 12 - 16.667, accuracy: 1e-2)

        // Base molding = perimeter − door width (window doesn't reach floor).
        XCTAssertEqual(calc.baseMoldingLength / ft, 54 - 2.5, accuracy: 1e-6)
        XCTAssertEqual(calc.crownMoldingLength / ft, 54, accuracy: 1e-6)
        XCTAssertEqual(calc.doorCount, 1)
        XCTAssertEqual(calc.windowCount, 1)
    }

    func testRoomWithoutWallsFallsBackToPerimeter() {
        let room = RoomShape(
            name: "Poly", polygon: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)],
            ceilingHeight: 2.5)
        let level = LevelGeometry(name: "L", rooms: [room])
        let calc = RoomCalculations.compute(room: room, in: level)
        XCTAssertEqual(calc.floorArea, 12, accuracy: 1e-9)
        XCTAssertEqual(calc.grossWallArea, 14 * 2.5, accuracy: 1e-9)
        XCTAssertEqual(calc.netWallArea, 14 * 2.5, accuracy: 1e-9)
    }

    func testProjectSummaryStats() {
        let level = SampleFixtures.apartment()
        let stats = ProjectSummaryStats.compute(levels: [level])
        XCTAssertEqual(stats.totalLevels, 1)
        XCTAssertEqual(stats.totalRooms, 7)
        // Envelope is 20 × 28 = 560 sq ft; interior partitions don't remove
        // floor area in this model, so the sum of room polygons equals it.
        XCTAssertEqual(stats.totalFloorArea / sqft, 560, accuracy: 1.0)
        XCTAssertGreaterThan(stats.totalDoors, 4)
        XCTAssertGreaterThan(stats.totalWindows, 5)
    }
}

final class QAEngineTests: XCTestCase {

    let ft = UnitConstants.metersPerFoot

    func testCleanRoomPasses() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        let findings = QAEngine.evaluate(level: level)
        XCTAssertEqual(QAEngine.overallStatus(findings), .pass, "\(findings.map(\.message))")
    }

    func testApartmentFixturePasses() {
        let findings = QAEngine.evaluate(level: SampleFixtures.apartment())
        let failures = findings.filter { $0.severity == .fail }
        XCTAssertTrue(failures.isEmpty, "\(failures.map(\.message))")
    }

    func testOpeningWiderThanWallFails() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        level.walls[0].openings = [
            WallOpening(kind: .door, centerOffset: 1.5, width: 4.0, height: 2.0)
        ]
        // Wall is 10 ft ≈ 3.048 m; a 4 m door cannot fit.
        let findings = QAEngine.evaluate(level: level)
        XCTAssertTrue(findings.contains { $0.code == .openingWiderThanWall })
        XCTAssertEqual(QAEngine.overallStatus(findings), .fail)
    }

    func testOpeningPastWallEndFlagged() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        level.walls[0].openings = [
            WallOpening(kind: .window, centerOffset: 2.9, width: 0.9, height: 1.2, sillHeight: 0.8)
        ]
        // Window center 2.9 m + 0.45 m half-width > 3.048 m wall end.
        let findings = QAEngine.evaluate(level: level)
        XCTAssertTrue(findings.contains { $0.code == .openingOutsideWall })
    }

    func testEndpointGapReported() {
        // U-shaped walls with a 10 cm gap at the last corner.
        let walls = [
            Wall(start: Vec2(0, 0), end: Vec2(4, 0)),
            Wall(start: Vec2(4, 0), end: Vec2(4, 3)),
            Wall(start: Vec2(4, 3), end: Vec2(0, 3)),
            Wall(start: Vec2(0, 3), end: Vec2(0, 0.10)),
        ]
        let level = LevelGeometry(name: "L", walls: walls)
        let findings = QAEngine.evaluate(level: level)
        XCTAssertTrue(findings.contains { $0.code == .endpointGap }, "\(findings.map(\.message))")
    }

    func testTinyWallFlagged() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        level.walls.append(Wall(start: Vec2(1, 1), end: Vec2(1.04, 1)))
        let findings = QAEngine.evaluate(level: level)
        XCTAssertTrue(findings.contains { $0.code == .tinyWall })
    }

    func testSelfIntersectingRoomFails() {
        let room = RoomShape(
            name: "Bad", polygon: [Vec2(0, 0), Vec2(4, 4), Vec2(4, 0), Vec2(0, 4)])
        let level = LevelGeometry(name: "L", rooms: [room])
        let findings = QAEngine.evaluate(level: level)
        XCTAssertTrue(findings.contains { $0.code == .selfIntersectingRoom })
        XCTAssertEqual(QAEngine.overallStatus(findings), .fail)
    }

    func testDuplicateWallsFlagged() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        var dupe = level.walls[0]
        dupe.id = UUID()
        dupe.start.y += 0.02
        dupe.end.y += 0.02
        level.walls.append(dupe)
        let findings = QAEngine.evaluate(level: level)
        XCTAssertTrue(findings.contains { $0.code == .duplicateWalls || $0.code == .overlappingWalls })
    }

    func testQANeverMutatesGeometry() {
        let level = SampleFixtures.apartment()
        let snapshot = level
        _ = QAEngine.evaluate(level: level)
        XCTAssertEqual(level, snapshot)
    }
}

final class ScanConversionTests: XCTestCase {

    /// Builds a synthetic scanned 4×3 m room, 2.5 m ceiling, door + window.
    /// World space: y up, floor plane XZ; plan y = −world z. To get a plan
    /// rectangle spanning (0,0)–(4,3) we use world z in [−3, 0].
    func syntheticRoom() -> ScannedRoomDTO {
        func wallDTO(center: Vec3, axis: Vec3, width: Double, id: UUID = UUID()) -> ScannedSurfaceDTO {
            ScannedSurfaceDTO(
                id: id, kind: .wall, center: center, xAxis: axis,
                width: width, height: 2.5, confidenceLevel: 2)
        }
        // South wall: plan (0,0)→(4,0) is world z=0, x 0→4.
        let south = wallDTO(center: Vec3(2, 1.25, 0), axis: Vec3(1, 0, 0), width: 4)
        // North wall: plan y=3 → world z=−3.
        let north = wallDTO(center: Vec3(2, 1.25, -3), axis: Vec3(1, 0, 0), width: 4)
        // West wall: x=0, spans plan y 0→3 → world z 0→−3; axis along −z.
        let west = wallDTO(center: Vec3(0, 1.25, -1.5), axis: Vec3(0, 0, -1), width: 3)
        let east = wallDTO(center: Vec3(4, 1.25, -1.5), axis: Vec3(0, 0, -1), width: 3)

        // Door on the south wall at plan x≈1, 0.9 wide, 2.03 high.
        let door = ScannedSurfaceDTO(
            kind: .door, center: Vec3(1, 1.015, 0), xAxis: Vec3(1, 0, 0),
            width: 0.9, height: 2.03, confidenceLevel: 2, parentID: south.id)
        // Window on the north wall at plan x≈2.5, sill 0.9.
        let window = ScannedSurfaceDTO(
            kind: .window, center: Vec3(2.5, 0.9 + 0.6, -3), xAxis: Vec3(1, 0, 0),
            width: 1.2, height: 1.2, confidenceLevel: 1, parentID: north.id)

        // Floor with explicit polygon corners.
        let floor = ScannedSurfaceDTO(
            kind: .floor, center: Vec3(2, 0, -1.5), xAxis: Vec3(1, 0, 0),
            width: 4, height: 3,
            polygonCorners: [Vec3(0, 0, 0), Vec3(4, 0, 0), Vec3(4, 0, -3), Vec3(0, 0, -3)])

        let toilet = ScannedObjectDTO(
            categoryName: "toilet", center: Vec3(0.5, 0.2, -0.5),
            xAxis: Vec3(1, 0, 0), dimensions: Vec3(0.5, 0.4, 0.7), confidenceLevel: 2)

        return ScannedRoomDTO(
            suggestedName: "Bathroom", suggestedType: "bathroom",
            surfaces: [south, north, west, east, door, window, floor],
            objects: [toilet])
    }

    func testConversionProducesClosedRoom() {
        let result = ScanConversion.convert(rooms: [syntheticRoom()])
        XCTAssertEqual(result.rooms.count, 1)
        XCTAssertEqual(result.walls.count, 4)
        let room = result.rooms[0]
        XCTAssertEqual(room.type, .bathroom)
        XCTAssertEqual(room.floorArea, 12, accuracy: 1e-6)
        XCTAssertEqual(room.ceilingHeight!, 2.5, accuracy: 1e-9)
    }

    func testDoorAttachesToParentWallWithSill() {
        let result = ScanConversion.convert(rooms: [syntheticRoom()])
        let allOpenings = result.walls.flatMap(\.openings)
        XCTAssertEqual(allOpenings.count, 2)
        let door = allOpenings.first { $0.kind == .door }!
        XCTAssertEqual(door.width, 0.9, accuracy: 1e-9)
        XCTAssertEqual(door.sillHeight, 0, accuracy: 1e-9)
        let window = allOpenings.first { $0.kind == .window }!
        XCTAssertEqual(window.sillHeight, 0.9, accuracy: 1e-6)
        // Door landed at plan x = 1 on the south wall.
        let host = result.walls.first { $0.openings.contains(where: { $0.kind == .door }) }!
        let doorWorld = host.point(atOffset: door.centerOffset)
        XCTAssertEqual(doorWorld.x, 1.0, accuracy: 1e-6)
    }

    func testFixtureConversion() {
        let result = ScanConversion.convert(rooms: [syntheticRoom()])
        XCTAssertEqual(result.fixtures.count, 1)
        let toilet = result.fixtures[0]
        XCTAssertEqual(toilet.category, .toilet)
        XCTAssertEqual(toilet.center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(toilet.center.y, 0.5, accuracy: 1e-9) // −(−0.5)
        XCTAssertNotNil(toilet.roomID)
        XCTAssertEqual(toilet.source, .lidarScanned)
    }

    func testSharedWallDeduplication() {
        // Two rooms scanned separately; the partition appears in both.
        var roomA = syntheticRoom()
        roomA.suggestedName = "A"
        // Second room to the east: plan x 4→8, sharing wall at x=4.
        func wallDTO(center: Vec3, axis: Vec3, width: Double) -> ScannedSurfaceDTO {
            ScannedSurfaceDTO(kind: .wall, center: center, xAxis: axis, width: width, height: 2.5, confidenceLevel: 1)
        }
        let roomB = ScannedRoomDTO(
            suggestedName: "B",
            surfaces: [
                wallDTO(center: Vec3(6, 1.25, 0), axis: Vec3(1, 0, 0), width: 4),
                wallDTO(center: Vec3(6, 1.25, -3), axis: Vec3(1, 0, 0), width: 4),
                wallDTO(center: Vec3(4, 1.25, -1.5), axis: Vec3(0, 0, -1), width: 3), // duplicate of A's east
                wallDTO(center: Vec3(8, 1.25, -1.5), axis: Vec3(0, 0, -1), width: 3),
            ])
        let result = ScanConversion.convert(rooms: [roomA, roomB])
        // 4 + 4 walls captured, one deduplicated → 7.
        XCTAssertEqual(result.walls.count, 7)
        // Both rooms still reference a wall at x=4.
        for room in result.rooms {
            let walls = room.wallIDs.compactMap { id in result.walls.first { $0.id == id } }
            XCTAssertEqual(walls.count, 4, "\(room.name) lost a wall reference")
        }
    }

    func testMergeReplacesRescannedRoom() {
        let first = ScanConversion.convert(rooms: [syntheticRoom()])
        var level = LevelGeometry(name: "L")
        level = ScanConversion.merge(first, into: level)
        XCTAssertEqual(level.rooms.count, 1)
        let wallCount = level.walls.count

        // Re-scan the same room (same scan/room id).
        var rescanned = syntheticRoom()
        rescanned.id = first.rooms[0].sourceScanID ?? first.rooms[0].id
        let second = ScanConversion.convert(rooms: [rescanned])
        level = ScanConversion.merge(second, into: level)
        XCTAssertEqual(level.rooms.count, 1)
        XCTAssertEqual(level.walls.count, wallCount)
    }
}

final class AutoLabelingTests: XCTestCase {

    func testInferRoomTypeFromFixtures() {
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: ["toilet", "sink", "bathtub"]), .bathroom)
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: ["refrigerator", "stove", "sink"]), .kitchen)
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: ["bed", "storage"]), .bedroom)
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: ["sofa", "table", "television"]), .livingRoom)
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: ["table", "chair"]), .diningRoom)
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: ["washerDryer"]), .laundry)
        XCTAssertNil(ScanConversion.inferRoomType(objectNames: ["chair"]))
        // Tiny room with a toilet but no tub → powder room.
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: ["toilet", "sink"], floorArea: 2.0), .powderRoom)
        // Tiny empty room → closet.
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: [], floorArea: 2.5), .closet)
    }

    func testAutoNameNumbering() {
        XCTAssertEqual(ScanConversion.autoName(for: .bedroom, avoiding: []), "Bedroom")
        XCTAssertEqual(ScanConversion.autoName(for: .bedroom, avoiding: ["Bedroom"]), "Bedroom 2")
        XCTAssertEqual(ScanConversion.autoName(for: .bedroom, avoiding: ["Bedroom", "Bedroom 2"]), "Bedroom 3")
        XCTAssertEqual(ScanConversion.autoName(for: .other, avoiding: ["Room"]), "Room 2")
    }

    /// Unnamed scanned rooms get inferred types and numbered names on merge.
    func testMergeAutoNamesUnnamedRooms() {
        func bedroomDTO(atX x: Double) -> ScannedRoomDTO {
            func wallDTO(center: Vec3, axis: Vec3, width: Double) -> ScannedSurfaceDTO {
                ScannedSurfaceDTO(kind: .wall, center: center, xAxis: axis, width: width, height: 2.5, confidenceLevel: 2)
            }
            return ScannedRoomDTO(
                suggestedName: nil, suggestedType: nil,
                surfaces: [
                    wallDTO(center: Vec3(x + 2, 1.25, 0), axis: Vec3(1, 0, 0), width: 4),
                    wallDTO(center: Vec3(x + 2, 1.25, -3), axis: Vec3(1, 0, 0), width: 4),
                    wallDTO(center: Vec3(x, 1.25, -1.5), axis: Vec3(0, 0, -1), width: 3),
                    wallDTO(center: Vec3(x + 4, 1.25, -1.5), axis: Vec3(0, 0, -1), width: 3),
                ],
                objects: [ScannedObjectDTO(
                    categoryName: "bed", center: Vec3(x + 2, 0.3, -1.5),
                    xAxis: Vec3(1, 0, 0), dimensions: Vec3(1.5, 0.6, 2.0), confidenceLevel: 2)])
        }
        let conversion = ScanConversion.convert(rooms: [bedroomDTO(atX: 0), bedroomDTO(atX: 5)])
        let level = ScanConversion.merge(conversion, into: LevelGeometry(name: "L"))
        let names = level.rooms.map(\.name).sorted()
        XCTAssertEqual(names, ["Bedroom", "Bedroom 2"])
        XCTAssertTrue(level.rooms.allSatisfy { $0.type == .bedroom })
    }

    func testOrientedDimensions() {
        // Axis-aligned rectangle.
        let rect = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)]
        let dims = GeometryOps.orientedDimensions(rect)!
        XCTAssertEqual(dims.width, 4, accuracy: 1e-9)
        XCTAssertEqual(dims.depth, 3, accuracy: 1e-9)
        // Same rectangle rotated 30° — dimensions must not change.
        let rotated = rect.map { $0.rotated(by: .pi / 6) }
        let rotatedDims = GeometryOps.orientedDimensions(rotated)!
        XCTAssertEqual(rotatedDims.width, 4, accuracy: 1e-6)
        XCTAssertEqual(rotatedDims.depth, 3, accuracy: 1e-6)
    }

    func testRoomDimensionLabelOnPlan() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 15, name: "Bedroom", type: .bedroom)
        let scene = PlanGenerator.scene(for: level)
        let labels = texts(in: scene, layer: .labels)
        XCTAssertTrue(labels.contains { $0.contains("×") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("15' 0\"") && $0.contains("12' 0\"") }, "\(labels)")
        // A rectangle really is W × D, so it carries no qualifier.
        XCTAssertFalse(labels.contains { $0.contains("overall") }, "\(labels)")
    }

    func testOrientedExtentsReportHowMuchOfTheBoxTheRoomFills() {
        let rect = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)]
        XCTAssertEqual(GeometryOps.orientedExtents(rect)!.fill, 1.0, accuracy: 1e-9)
        let rotated = rect.map { $0.rotated(by: .pi / 6) }
        XCTAssertEqual(GeometryOps.orientedExtents(rotated)!.fill, 1.0, accuracy: 1e-6)

        // L-shape: a 4×4 box with a 2×2 bite removed fills three quarters of it.
        let ell = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 2), Vec2(2, 2), Vec2(2, 4), Vec2(0, 4)]
        let extents = GeometryOps.orientedExtents(ell)!
        XCTAssertEqual(extents.width, 4, accuracy: 1e-9)
        XCTAssertEqual(extents.depth, 4, accuracy: 1e-9)
        XCTAssertEqual(extents.fill, 0.75, accuracy: 1e-9)
    }

    func testIrregularRoomDimensionsAreLabelledOverall() {
        // The pentagon's bounding box is 14' × 14' = 196 sq ft but the room is
        // only 178 sq ft. Printing a bare "14' × 14'" next to "178 sq ft" would
        // invite the client to multiply and get a different answer, so the
        // extents must be qualified.
        let level = SampleFixtures.irregularRoom()
        let labels = texts(in: PlanGenerator.scene(for: level), layer: .labels)
        XCTAssertTrue(labels.contains { $0.contains("×") && $0.hasSuffix("overall") }, "\(labels)")
        XCTAssertFalse(labels.contains { $0.contains("×") && !$0.hasSuffix("overall") }, "\(labels)")
    }

    func testRoomLabelLinesNeverExceedTheRoomWidth() {
        // A narrow closet can hold its name but not a dimension string; the
        // extra lines must be dropped rather than spill into the next room.
        let level = SampleFixtures.rectangularRoom(widthFeet: 2.5, depthFeet: 6, name: "Closet", type: .closet)
        let room = level.rooms[0]
        let maxWidth = room.bounds.width * 0.82
        for case .text(let string, _, let height, _, _, _) in PlanGenerator.scene(for: level).layer(.labels)!.primitives {
            XCTAssertLessThanOrEqual(PlanTextMetrics.width(string, height: height), maxWidth + 1e-9, "\(string)")
        }
    }

    func testTextMetricsTrackRealFontWidths() {
        // Per-character widths measured in a browser from Helvetica/Arial at
        // 100 pt. Layout decisions are only as good as these numbers, so they
        // must stay within a few percent of what a renderer really draws.
        let measured: [(String, Double)] = [
            ("BATHROOM", 0.713), ("BEDROOM", 0.738), ("LIVING ROOM", 0.606),
            ("HALLWAY", 0.656), ("KITCHEN", 0.627), ("CLOSET", 0.667),
            ("5' 0\" × 6' 0\"", 0.386), ("30.0 sq ft", 0.411),
            ("123 Main Street, Apt 4B, Brooklyn NY 11201", 0.469),
            ("(555) 010-0100 · Lic. #123456", 0.464),
        ]
        for (text, perCharacter) in measured {
            let actual = perCharacter * Double(text.count)
            let estimate = PlanTextMetrics.units(text)
            XCTAssertEqual(estimate, actual, accuracy: actual * 0.05, text)
        }
        XCTAssertNil(PlanTextMetrics.heightToFit("", maxWidth: 1))
    }

    // MARK: - Title block

    func testTitleBlockSitsBelowThePlanAndCarriesTheSheetFacts() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 15, name: "Bedroom", type: .bedroom)
        var options = PlanGenerator.Options()
        let plain = PlanGenerator.scene(for: level, options: options)

        options.titleBlock = PlanTitleBlock(
            style: .sheet,
            projectName: "Maple Street Apartment",
            address: "123 Main St, Apt 4B, Brooklyn NY",
            planTitle: "Existing Conditions — Level 1",
            totalArea: "180 sq ft",
            dateText: "Aug 30, 2026",
            preparedBy: "Jerry's Renovations",
            contact: "(555) 010-0100")
        let titled = PlanGenerator.scene(for: level, options: options)

        // The block extends the sheet downward and never eats into the plan.
        XCTAssertLessThan(titled.bounds.minY, plain.bounds.minY)
        XCTAssertEqual(titled.bounds.maxY, plain.bounds.maxY, accuracy: 1e-9)
        XCTAssertEqual(titled.bounds.minX, plain.bounds.minX, accuracy: 1e-9)
        XCTAssertEqual(titled.bounds.maxX, plain.bounds.maxX, accuracy: 1e-9)

        let decor = texts(in: titled, layer: .decor)
        XCTAssertTrue(decor.contains("MAPLE STREET APARTMENT"), "\(decor)")
        XCTAssertTrue(decor.contains("123 Main St, Apt 4B, Brooklyn NY"), "\(decor)")
        XCTAssertTrue(decor.contains("180 sq ft"), "\(decor)")
        XCTAssertTrue(decor.contains("Jerry's Renovations"), "\(decor)")
        XCTAssertTrue(decor.contains("(555) 010-0100"), "\(decor)")

        // Every block primitive stays below the plan geometry.
        for case .text(_, let position, _, _, _, _) in titled.layer(.decor)!.primitives
        where position.y < plain.bounds.minY {
            XCTAssertGreaterThan(position.y, titled.bounds.minY)
        }
    }

    func testEmptyTitleBlockChangesNothing() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 15, name: "Bedroom", type: .bedroom)
        var options = PlanGenerator.Options()
        let plain = PlanGenerator.scene(for: level, options: options)
        options.titleBlock = PlanTitleBlock(projectName: "   ")
        let blank = PlanGenerator.scene(for: level, options: options)
        XCTAssertEqual(blank.bounds.minY, plain.bounds.minY, accuracy: 1e-9)
        XCTAssertEqual(texts(in: blank, layer: .decor), texts(in: plain, layer: .decor))
    }

    private func texts(in scene: PlanScene, layer: PlanLayerKind) -> [String] {
        (scene.layer(layer)?.primitives ?? []).compactMap {
            if case .text(let string, _, _, _, _, _) = $0 { return string }
            return nil
        }
    }
}
