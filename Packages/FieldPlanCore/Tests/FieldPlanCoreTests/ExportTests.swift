import XCTest
@testable import FieldPlanCore

final class TakeoffTests: XCTestCase {

    let ft = UnitConstants.metersPerFoot
    let sqft = UnitConstants.squareMetersPerSquareFoot

    func testFlooringWithWaste() {
        // 12 × 15 room floor = 180 sq ft; 10% waste → 198.
        let level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 15)
        let room = level.rooms[0]
        let item = TakeoffItem(
            category: .flooring,
            selections: [SurfaceSelection(roomID: room.id, includeFloor: true)],
            wastePercent: 10)
        let line = TakeoffCalculator.line(for: item, levels: [level])
        XCTAssertEqual(line.baseQuantity, 180, accuracy: 1e-6)
        XCTAssertEqual(line.totalQuantity, 198, accuracy: 1e-6)
        XCTAssertEqual(line.unit, .squareFeet)
        XCTAssertEqual(line.wastePercent, 10)
    }

    func testSelectiveWallTile() {
        // Only two of four walls tiled (spec §28).
        let level = SampleFixtures.rectangularRoom(widthFeet: 5, depthFeet: 8)
        let room = level.rooms[0]
        let selected = Set([level.walls[0].id, level.walls[1].id]) // 5' and 8' walls
        let item = TakeoffItem(
            category: .wallTile,
            selections: [SurfaceSelection(roomID: room.id, wallIDs: selected)],
            wastePercent: 0)
        let line = TakeoffCalculator.line(for: item, levels: [level])
        // (5 + 8) × 8 ft high = 104 sq ft.
        XCTAssertEqual(line.baseQuantity, 104, accuracy: 1e-6)
    }

    func testPaintUsesNetWallAreaAndCeiling() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        level.walls[0].openings = [
            WallOpening(kind: .door, centerOffset: 1.5 * ft, width: 2.5 * ft, height: (20.0 / 3) * ft)
        ]
        let room = level.rooms[0]
        let item = TakeoffItem(
            category: .paint,
            selections: [SurfaceSelection(roomID: room.id, includeCeiling: true, includeAllWalls: true)],
            wastePercent: 0)
        let line = TakeoffCalculator.line(for: item, levels: [level])
        // Walls: 40 × 8 = 320 − door 16.667 = 303.333; ceiling 100.
        XCTAssertEqual(line.baseQuantity, 303.333 + 100, accuracy: 0.01)
    }

    func testBaseMoldingSubtractsDoorways() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 12)
        level.walls[0].openings = [
            WallOpening(kind: .door, centerOffset: 1.5 * ft, width: 3 * ft, height: 2.03)
        ]
        let room = level.rooms[0]
        let item = TakeoffItem(
            category: .baseMolding,
            selections: [SurfaceSelection(roomID: room.id, includeAllWalls: true)])
        let line = TakeoffCalculator.line(for: item, levels: [level])
        XCTAssertEqual(line.baseQuantity, 44 - 3, accuracy: 1e-6)
        XCTAssertEqual(line.unit, .linearFeet)
    }

    func testManualOverridePreservesComputation() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        let item = TakeoffItem(
            category: .flooring,
            selections: [SurfaceSelection(roomID: level.rooms[0].id, includeFloor: true)],
            wastePercent: 5,
            manualQuantity: 120)
        let line = TakeoffCalculator.line(for: item, levels: [level])
        XCTAssertEqual(line.baseQuantity, 120, accuracy: 1e-9)
        XCTAssertTrue(line.isManualOverride)
        XCTAssertEqual(line.totalQuantity, 126, accuracy: 1e-9)
    }

    func testCabinetRunManualLinear() {
        let item = TakeoffItem(
            category: .cabinets,
            wastePercent: 0,
            manualLinearMeters: 10 * ft)
        let line = TakeoffCalculator.line(for: item, levels: [])
        XCTAssertEqual(line.baseQuantity, 10, accuracy: 1e-9)
        XCTAssertEqual(line.unit, .linearFeet)
    }

    func testExcludedItemsSkipped() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        let items = [
            TakeoffItem(category: .flooring,
                        selections: [SurfaceSelection(roomID: level.rooms[0].id, includeFloor: true)]),
            TakeoffItem(category: .paint, isExcluded: true),
        ]
        XCTAssertEqual(TakeoffCalculator.lines(for: items, levels: [level]).count, 1)
    }
}

final class PlanGeneratorTests: XCTestCase {

    func testSceneContainsExpectedLayers() {
        let level = SampleFixtures.apartment()
        let scene = PlanGenerator.scene(for: level)
        let kinds = Set(scene.layers.map(\.kind))
        XCTAssertTrue(kinds.contains(.walls))
        XCTAssertTrue(kinds.contains(.openings))
        XCTAssertTrue(kinds.contains(.dimensions))
        XCTAssertTrue(kinds.contains(.labels))
        XCTAssertTrue(kinds.contains(.fixtures))
        XCTAssertFalse(scene.bounds.isNull)
    }

    func testModeFiltering() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        // Mark one wall demolished, add one new wall.
        level.walls[0].changeStatus = .demolish
        level.walls.append(Wall(
            start: Vec2(1, 1), end: Vec2(2, 1), changeStatus: .new))

        var options = PlanGenerator.Options()
        options.mode = .proposed
        let proposed = PlanGenerator.scene(for: level, options: options)
        XCTAssertNil(proposed.layer(.demolition))
        XCTAssertNotNil(proposed.layer(.newConstruction))

        options.mode = .demolition
        let demo = PlanGenerator.scene(for: level, options: options)
        XCTAssertNotNil(demo.layer(.demolition))
        XCTAssertNil(demo.layer(.newConstruction))

        options.mode = .existing
        let existing = PlanGenerator.scene(for: level, options: options)
        XCTAssertNil(existing.layer(.newConstruction))
    }

    func testDimensionTextMatchesWallLength() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        let scene = PlanGenerator.scene(for: level)
        let texts: [String] = scene.layer(.dimensions)!.primitives.compactMap {
            if case .text(let s, _, _, _, _, _) = $0 { return s }
            return nil
        }
        XCTAssertEqual(texts.count, 4)
        XCTAssertTrue(texts.allSatisfy { $0 == "10' 0\"" }, "\(texts)")
    }

    func testDoorSwingEmitted() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        level.walls[0].openings = [
            WallOpening(kind: .door, centerOffset: 1.5, width: 0.9, height: 2, swing: DoorSwing())
        ]
        let scene = PlanGenerator.scene(for: level)
        let arcs = scene.layer(.openings)!.primitives.filter {
            if case .arc = $0 { return true }
            return false
        }
        XCTAssertEqual(arcs.count, 1)
    }
}

final class ExporterTests: XCTestCase {

    func makeScene() -> PlanScene {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10, name: "Bedroom", type: .bedroom)
        level.walls[0].openings = [
            WallOpening(kind: .door, centerOffset: 1.5, width: 0.9, height: 2, swing: DoorSwing()),
            WallOpening(kind: .window, centerOffset: 2.4, width: 0.9, height: 1.2, sillHeight: 0.9),
        ]
        return PlanGenerator.scene(for: level)
    }

    func testSVGStructure() {
        let svg = SVGExporter.svg(for: makeScene())
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("</svg>"))
        XCTAssertTrue(svg.contains("<polygon"))   // wall bodies stay vector
        XCTAssertTrue(svg.contains("<text"))      // labels are text, not paths
        XCTAssertTrue(svg.contains("BEDROOM"))
        XCTAssertTrue(svg.contains("id=\"walls\""))
        XCTAssertTrue(svg.contains("id=\"dimensions\""))
        // No raster imagery.
        XCTAssertFalse(svg.contains("<image"))
    }

    func testSVGEscapesText() {
        XCTAssertEqual(SVGExporter.escapeXML("a<b&c\"d"), "a&lt;b&amp;c&quot;d")
    }

    func testDXFStructure() {
        let dxf = DXFExporter.dxf(for: makeScene())
        XCTAssertTrue(dxf.contains("$ACADVER"))
        XCTAssertTrue(dxf.contains("AC1009"))
        XCTAssertTrue(dxf.contains("ENTITIES"))
        XCTAssertTrue(dxf.hasSuffix("EOF\n"))
        for layer in ["WALLS", "DOORS", "WINDOWS", "DIMENSIONS", "TEXT"] {
            XCTAssertTrue(dxf.contains(layer), "missing layer \(layer)")
        }
        // Balanced group code/value pairs.
        let lines = dxf.split(separator: "\n", omittingEmptySubsequences: false)
        // Trailing newline yields one empty tail element.
        XCTAssertEqual((lines.count - 1) % 2, 0)
    }

    func testDXFGeometryScaledToInches() {
        // A 10' line with bounds at the origin must land at x = 120 inches.
        let tenFeet = 10 * UnitConstants.metersPerFoot
        let scene = PlanScene(
            layers: [PlanLayer(kind: .walls, primitives: [
                .line(a: Vec2(0, 0), b: Vec2(tenFeet, 0), pen: .wallOutline)
            ])],
            bounds: Rect2(minX: 0, minY: 0, maxX: tenFeet, maxY: 1),
            levelName: "Test")
        let dxf = DXFExporter.dxf(for: scene)
        XCTAssertTrue(dxf.contains("120.0000"), "expected 120-inch coordinate in DXF:\n\(dxf)")
    }

    func testCSVSchedules() {
        let level = SampleFixtures.apartment()
        let csv = CSVExporter.roomSchedule(levels: [level])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 8) // header + 7 rooms
        XCTAssertTrue(csv.contains("Living Room"))

        let m = FieldMeasurementModel(name: "Tub, interior", value: 1.524, isCritical: true)
        let mcsv = CSVExporter.measurementSchedule([m])
        XCTAssertTrue(mcsv.contains("\"Tub, interior\"")) // comma escaped
        XCTAssertTrue(mcsv.contains("YES"))
    }

    func testJSONArchiveRoundTrip() throws {
        let archive = SampleFixtures.sampleProject()
        let data = try archive.jsonData()
        let decoded = try ProjectArchive.decode(from: data)
        XCTAssertEqual(decoded.schemaVersion, ProjectArchive.currentSchemaVersion)
        XCTAssertEqual(decoded.meta.name, archive.meta.name)
        XCTAssertEqual(decoded.snapshots.count, 1)
        XCTAssertEqual(decoded.snapshots[0].levels[0].walls.count,
                       archive.snapshots[0].levels[0].walls.count)
        XCTAssertEqual(decoded.measurements.count, 2)
        // Geometry survives byte-exact.
        XCTAssertEqual(decoded.snapshots[0].levels[0], archive.snapshots[0].levels[0])
    }

    func testJSONArchiveRejectsNewerSchema() throws {
        var archive = SampleFixtures.sampleProject()
        archive.schemaVersion = 99
        let data = try archive.jsonData()
        XCTAssertThrowsError(try ProjectArchive.decode(from: data))
    }

    func testZipRoundTrip() throws {
        let entries = [
            ZipEntry(path: "project.json", data: Data("{\"a\":1}".utf8)),
            ZipEntry(path: "photos/room1.jpg", data: Data((0..<1000).map { UInt8($0 % 251) })),
            ZipEntry(path: "empty.txt", data: Data()),
        ]
        let archived = ZipArchive.archiveData(entries: entries)
        let read = try ZipArchive.read(data: archived)
        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(read[0].path, "project.json")
        XCTAssertEqual(read[0].data, entries[0].data)
        XCTAssertEqual(read[1].data, entries[1].data)
        XCTAssertEqual(read[2].data.count, 0)
    }

    func testZipDetectsCorruption() throws {
        let entries = [ZipEntry(path: "a.txt", data: Data("hello world".utf8))]
        var archived = ZipArchive.archiveData(entries: entries)
        archived[35] ^= 0xFF // flip a byte inside the payload
        XCTAssertThrowsError(try ZipArchive.read(data: archived))
    }

    func testZipRejectsGarbage() {
        XCTAssertThrowsError(try ZipArchive.read(data: Data("not a zip".utf8)))
    }

    func testCRC32KnownValue() {
        // CRC32("123456789") = 0xCBF43926 (standard check value).
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}

final class SampleFixturesTests: XCTestCase {

    func testAllFixturesPassQA() {
        let fixtures: [LevelGeometry] = [
            SampleFixtures.simpleBedroom(),
            SampleFixtures.bathroom(),
            SampleFixtures.kitchen(),
            SampleFixtures.irregularRoom(),
            SampleFixtures.apartment(),
            SampleFixtures.apartment(twoBedroom: true),
        ]
        for level in fixtures {
            let findings = QAEngine.evaluate(level: level)
            let failures = findings.filter { $0.severity == .fail }
            XCTAssertTrue(failures.isEmpty, "\(level.name): \(failures.map(\.message))")
        }
    }

    func testFixturesAreMarkedSampleData() {
        let level = SampleFixtures.apartment()
        XCTAssertTrue(level.walls.allSatisfy { $0.source == .sampleData })
        XCTAssertTrue(level.name.contains("SAMPLE"))
        let archive = SampleFixtures.sampleProject()
        XCTAssertTrue(archive.meta.name.contains("SAMPLE"))
    }

    func testApartmentRoomWallsMatchPerimeters() {
        // Each room's referenced wall lengths must sum to its polygon
        // perimeter (walls are segmented at room junctions).
        let level = SampleFixtures.apartment()
        for room in level.rooms {
            let walls = level.walls(for: room)
            let wallSum = walls.reduce(0.0) { $0 + $1.length }
            XCTAssertEqual(wallSum, room.perimeter, accuracy: 1e-6,
                           "\(room.name) walls \(wallSum) vs perimeter \(room.perimeter)")
        }
    }

    func testMultiFloorHouse() {
        let levels = SampleFixtures.multiFloorHouse()
        XCTAssertEqual(levels.count, 2)
        XCTAssertNotEqual(levels[0].id, levels[1].id)
        // No shared element IDs across floors.
        let ids0 = Set(levels[0].walls.map(\.id))
        let ids1 = Set(levels[1].walls.map(\.id))
        XCTAssertTrue(ids0.isDisjoint(with: ids1))
        XCTAssertEqual(levels[1].storyIndex, 1)
    }

    func testRoomLoopReconstruction() {
        // Room polygons can be rebuilt from their wall loops.
        let level = SampleFixtures.apartment()
        for room in level.rooms {
            let walls = level.walls(for: room)
            let loop = GeometryCleaner.loopPolygon(from: walls, tolerance: 0.05)
            XCTAssertNotNil(loop, "\(room.name) loop failed")
            XCTAssertEqual(GeometryOps.area(loop!), room.floorArea, accuracy: 1e-6,
                           "\(room.name) loop area mismatch")
        }
    }
}
