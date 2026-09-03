import XCTest
@testable import FieldPlanCore

final class OBJExporterTests: XCTestCase {

    func testTriangulationCoversTheArea() {
        let l = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 2), Vec2(2, 2), Vec2(2, 3), Vec2(0, 3)]
        let triangles = GeometryOps.triangulate(l)
        XCTAssertEqual(triangles.count, 4)
        let area = triangles.reduce(0.0) { $0 + GeometryOps.area([l[$1.0], l[$1.1], l[$1.2]]) }
        XCTAssertEqual(area, GeometryOps.area(l), accuracy: 1e-9)
        XCTAssertTrue(triangles.allSatisfy { GeometryOps.signedArea([l[$0.0], l[$0.1], l[$0.2]]) > 0 },
                      "every triangle counter-clockwise")

        // Clockwise input is handled the same way.
        XCTAssertEqual(GeometryOps.triangulate(Array(l.reversed())).count, 4)

        // A U shape: deeply concave.
        let u = [Vec2(0, 0), Vec2(6, 0), Vec2(6, 4), Vec2(4, 4), Vec2(4, 1), Vec2(2, 1), Vec2(2, 4), Vec2(0, 4)]
        let uTriangles = GeometryOps.triangulate(u)
        XCTAssertEqual(uTriangles.count, 6)
        let uArea = uTriangles.reduce(0.0) { $0 + GeometryOps.area([u[$1.0], u[$1.1], u[$1.2]]) }
        XCTAssertEqual(uArea, GeometryOps.area(u), accuracy: 1e-9)
    }

    func testOBJHasWallsFloorsFixturesAndValidIndices() {
        let level = SampleFixtures.apartment()
        let out = OBJExporter.export(levels: [level])
        XCTAssertTrue(out.obj.hasPrefix("# Jerry FieldPlans"))
        XCTAssertTrue(out.obj.contains("mtllib fieldplan.mtl"))
        XCTAssertTrue(out.obj.contains("usemtl wall"))
        XCTAssertTrue(out.obj.contains("usemtl floor"))
        XCTAssertTrue(out.obj.contains("usemtl fixture"))
        XCTAssertTrue(out.mtl.contains("newmtl wall"))
        XCTAssertTrue(out.mtl.contains("newmtl floor"))

        let lines = out.obj.split(separator: "\n")
        let vertices = lines.filter { $0.hasPrefix("v ") }
        let faces = lines.filter { $0.hasPrefix("f ") }
        XCTAssertGreaterThan(vertices.count, 100)
        XCTAssertGreaterThan(faces.count, 50)
        let indices = faces.flatMap { $0.dropFirst(2).split(separator: " ").compactMap { Int($0) } }
        XCTAssertEqual(indices.max(), vertices.count, "every face index names a vertex")
        XCTAssertGreaterThanOrEqual(indices.min() ?? 0, 1)

        // Walls reach 8'; nothing floats above the room.
        let ys = vertices.compactMap { Double($0.split(separator: " ")[2]) }
        XCTAssertEqual(ys.max() ?? 0, 8 * UnitConstants.metersPerFoot, accuracy: 0.3)
        XCTAssertEqual(ys.min() ?? 0, -0.08, accuracy: 1e-6, "the slab hangs below the floor")
    }

    func testModeFiltersAndMaterials() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        level.walls[0].changeStatus = .demolish
        level.walls.append(Wall(start: Vec2(1, 1), end: Vec2(2, 1), changeStatus: .new))
        var options = OBJExporter.Options()
        options.mode = .existing
        let existing = OBJExporter.export(levels: [level], options: options).obj
        XCTAssertFalse(existing.contains("usemtl wall_new"))
        XCTAssertFalse(existing.contains("usemtl wall_demolished"), "existing plan draws the wall as it stands")

        options.mode = .proposed
        let proposed = OBJExporter.export(levels: [level], options: options).obj
        XCTAssertTrue(proposed.contains("usemtl wall_new"))
        XCTAssertFalse(proposed.contains("usemtl wall_demolished"))

        options.mode = .demolition
        XCTAssertTrue(OBJExporter.export(levels: [level], options: options).obj.contains("usemtl wall_demolished"))
    }

    func testLevelsStackAtScannedHeights() {
        var lower = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        lower.elevation = 0
        var upper = SampleFixtures.rectangularRoom(widthFeet: 10, depthFeet: 10)
        upper.storyIndex = 1
        upper.elevation = 2.9
        let out = OBJExporter.export(levels: [lower, upper]).obj
        let ys = out.split(separator: "\n").filter { $0.hasPrefix("v ") }.compactMap { Double($0.split(separator: " ")[2]) }
        XCTAssertEqual(ys.max() ?? 0, 2.9 + 8 * UnitConstants.metersPerFoot, accuracy: 1e-3)
    }
}
