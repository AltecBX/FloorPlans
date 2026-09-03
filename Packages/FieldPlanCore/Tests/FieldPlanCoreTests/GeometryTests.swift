import XCTest
@testable import FieldPlanCore

final class GeometryOpsTests: XCTestCase {

    let ft = UnitConstants.metersPerFoot

    func testRectangleAreaAndPerimeter() {
        // 10' × 10' room (spec §50).
        let square = [Vec2(0, 0), Vec2(10 * ft, 0), Vec2(10 * ft, 10 * ft), Vec2(0, 10 * ft)]
        XCTAssertEqual(GeometryOps.area(square), 100 * ft * ft, accuracy: 1e-9)
        XCTAssertEqual(GeometryOps.perimeter(square), 40 * ft, accuracy: 1e-9)

        // 12' × 15' rectangle.
        let rect = [Vec2(0, 0), Vec2(12 * ft, 0), Vec2(12 * ft, 15 * ft), Vec2(0, 15 * ft)]
        XCTAssertEqual(GeometryOps.area(rect), 180 * ft * ft, accuracy: 1e-9)
        XCTAssertEqual(GeometryOps.perimeter(rect), 54 * ft, accuracy: 1e-9)
    }

    func testLShapeArea() {
        // 12×15 minus a 5×6 corner notch = 180 - 30 = 150 sq ft.
        let l = [
            Vec2(0, 0), Vec2(12 * ft, 0), Vec2(12 * ft, 9 * ft),
            Vec2(7 * ft, 9 * ft), Vec2(7 * ft, 15 * ft), Vec2(0, 15 * ft),
        ]
        XCTAssertEqual(GeometryOps.area(l), 150 * ft * ft, accuracy: 1e-9)
        XCTAssertEqual(GeometryOps.perimeter(l), (12 + 9 + 5 + 6 + 7 + 15) * ft, accuracy: 1e-9)
    }

    func testAngledWallRoomArea() {
        // Right triangle 6×8: area 24.
        let tri = [Vec2(0, 0), Vec2(6, 0), Vec2(0, 8)]
        XCTAssertEqual(GeometryOps.area(tri), 24, accuracy: 1e-9)
        // Signed area is negative for this clockwise winding? (0,0)->(6,0)->(0,8) is CCW.
        XCTAssertGreaterThan(GeometryOps.signedArea(tri), 0)
        XCTAssertLessThan(GeometryOps.signedArea(tri.reversed()), 0)
    }

    func testCentroidOfSquare() {
        let square = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 4), Vec2(0, 4)]
        let c = GeometryOps.centroid(square)
        XCTAssertEqual(c.x, 2, accuracy: 1e-9)
        XCTAssertEqual(c.y, 2, accuracy: 1e-9)
    }

    func testPolygonContains() {
        let square = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 4), Vec2(0, 4)]
        XCTAssertTrue(GeometryOps.polygonContains(square, Vec2(2, 2)))
        XCTAssertTrue(GeometryOps.polygonContains(square, Vec2(0, 2)))  // boundary
        XCTAssertFalse(GeometryOps.polygonContains(square, Vec2(5, 2)))
        XCTAssertFalse(GeometryOps.polygonContains(square, Vec2(-1, -1)))
    }

    func testInteriorLabelPointForLShape() {
        // Centroid of a thin L can fall outside; label point must be inside.
        let l = [
            Vec2(0, 0), Vec2(10, 0), Vec2(10, 2),
            Vec2(2, 2), Vec2(2, 10), Vec2(0, 10),
        ]
        let p = GeometryOps.interiorLabelPoint(l)
        XCTAssertTrue(GeometryOps.polygonContains(l, p))
    }

    func testSegmentIntersection() {
        let hit = GeometryOps.segmentIntersection(Vec2(0, 0), Vec2(4, 4), Vec2(0, 4), Vec2(4, 0))
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!.point.x, 2, accuracy: 1e-9)
        XCTAssertEqual(hit!.point.y, 2, accuracy: 1e-9)

        XCTAssertNil(GeometryOps.segmentIntersection(Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 1)))
        XCTAssertNil(GeometryOps.segmentIntersection(Vec2(0, 0), Vec2(1, 1), Vec2(3, 3), Vec2(4, 4)))
    }

    func testCollinearOverlap() {
        XCTAssertTrue(GeometryOps.collinearOverlap(
            Vec2(0, 0), Vec2(4, 0), Vec2(2, 0.01), Vec2(6, 0.01)))
        XCTAssertFalse(GeometryOps.collinearOverlap(
            Vec2(0, 0), Vec2(4, 0), Vec2(5, 0), Vec2(9, 0)))       // no overlap
        XCTAssertFalse(GeometryOps.collinearOverlap(
            Vec2(0, 0), Vec2(4, 0), Vec2(2, 1), Vec2(6, 1)))       // laterally distant
        XCTAssertFalse(GeometryOps.collinearOverlap(
            Vec2(0, 0), Vec2(4, 0), Vec2(2, 0), Vec2(2, 4)))       // perpendicular
    }

    func testSelfIntersection() {
        let bowtie = [Vec2(0, 0), Vec2(4, 4), Vec2(4, 0), Vec2(0, 4)]
        XCTAssertTrue(GeometryOps.polygonSelfIntersects(bowtie))
        let square = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 4), Vec2(0, 4)]
        XCTAssertFalse(GeometryOps.polygonSelfIntersects(square))
    }

    func testSimplifiedRemovesCollinearPoints() {
        let poly = [Vec2(0, 0), Vec2(2, 0), Vec2(4, 0), Vec2(4, 4), Vec2(0, 4)]
        let simplified = GeometryOps.simplified(poly)
        XCTAssertEqual(simplified.count, 4)
        XCTAssertEqual(GeometryOps.area(simplified), 16, accuracy: 1e-9)
    }

    func testVecOperations() {
        let v = Vec2(3, 4)
        XCTAssertEqual(v.length, 5, accuracy: 1e-12)
        XCTAssertEqual(v.normalized.length, 1, accuracy: 1e-12)
        XCTAssertEqual(v.perpendicular.dot(v), 0, accuracy: 1e-12)
        let r = Vec2(1, 0).rotated(by: .pi / 2)
        XCTAssertEqual(r.x, 0, accuracy: 1e-12)
        XCTAssertEqual(r.y, 1, accuracy: 1e-12)
    }

    func testPlanProjection() {
        // World (x, y-up, z) → plan (x, -z).
        let world = Vec3(2, 1.5, -3)
        let plan = world.planProjection
        XCTAssertEqual(plan.x, 2, accuracy: 1e-12)
        XCTAssertEqual(plan.y, 3, accuracy: 1e-12)
    }
}

final class WallGraphTests: XCTestCase {

    func rectWalls(w: Double, d: Double, gap: Double = 0) -> [Wall] {
        // Four walls; when gap > 0 the last corner doesn't quite close.
        [
            Wall(start: Vec2(0, 0), end: Vec2(w, 0)),
            Wall(start: Vec2(w, 0), end: Vec2(w, d)),
            Wall(start: Vec2(w, d), end: Vec2(0, d)),
            Wall(start: Vec2(0, d), end: Vec2(0 + gap, 0 + gap)),
        ]
    }

    func testSnapJoinsNearbyEndpoints() {
        let walls = rectWalls(w: 4, d: 3, gap: 0.05)
        let snapped = GeometryCleaner.snapEndpoints(walls, tolerance: 0.08)
        // Last wall's end must now coincide with first wall's start.
        XCTAssertEqual(snapped[3].end.distance(to: snapped[0].start), 0, accuracy: 1e-9)
    }

    func testInteriorFaceDetection() {
        let walls = rectWalls(w: 4, d: 3)
        let graph = WallGraph(walls: walls, tolerance: 0.05)
        let faces = graph.interiorFaces(minArea: 0.5)
        XCTAssertEqual(faces.count, 1)
        XCTAssertEqual(GeometryOps.area(faces[0]), 12, accuracy: 1e-6)
        XCTAssertGreaterThan(GeometryOps.signedArea(faces[0]), 0) // CCW
    }

    func testTwoAdjacentRoomsShareWall() {
        // Two 4×3 rooms sharing the wall x=4.
        var walls = [
            Wall(start: Vec2(0, 0), end: Vec2(4, 0)),
            Wall(start: Vec2(4, 0), end: Vec2(8, 0)),
            Wall(start: Vec2(8, 0), end: Vec2(8, 3)),
            Wall(start: Vec2(8, 3), end: Vec2(4, 3)),
            Wall(start: Vec2(4, 3), end: Vec2(0, 3)),
            Wall(start: Vec2(0, 3), end: Vec2(0, 0)),
        ]
        walls.append(Wall(start: Vec2(4, 0), end: Vec2(4, 3))) // shared partition
        let graph = WallGraph(walls: walls, tolerance: 0.05)
        let faces = graph.interiorFaces(minArea: 0.5)
        XCTAssertEqual(faces.count, 2)
        let areas = faces.map { GeometryOps.area($0) }.sorted()
        XCTAssertEqual(areas[0], 12, accuracy: 1e-6)
        XCTAssertEqual(areas[1], 12, accuracy: 1e-6)
    }

    func testExteriorBoundary() {
        let walls = rectWalls(w: 5, d: 4)
        let graph = WallGraph(walls: walls, tolerance: 0.05)
        let boundary = graph.exteriorBoundary()
        XCTAssertNotNil(boundary)
        XCTAssertEqual(GeometryOps.area(boundary!), 20, accuracy: 1e-6)
    }

    func testDanglingWallPrunedFromFaces() {
        var walls = rectWalls(w: 4, d: 3)
        walls.append(Wall(start: Vec2(4, 0), end: Vec2(6, -1))) // stub
        let graph = WallGraph(walls: walls, tolerance: 0.05)
        let faces = graph.interiorFaces(minArea: 0.5)
        XCTAssertEqual(faces.count, 1)
        XCTAssertEqual(GeometryOps.area(faces[0]), 12, accuracy: 1e-6)
        XCTAssertEqual(graph.danglingWalls().count, 1)
    }

    func testConnectedComponents() {
        var walls = rectWalls(w: 4, d: 3)
        walls.append(Wall(start: Vec2(10, 10), end: Vec2(12, 10)))
        let graph = WallGraph(walls: walls, tolerance: 0.05)
        XCTAssertEqual(graph.connectedComponents().count, 2)
    }

    func testOverlappingPairDetection() {
        let walls = [
            Wall(start: Vec2(0, 0), end: Vec2(4, 0)),
            Wall(start: Vec2(1, 0.02), end: Vec2(5, 0.02)),
        ]
        let graph = WallGraph(walls: walls, tolerance: 0.05)
        XCTAssertEqual(graph.overlappingPairs().count, 1)
    }

    func testMergeCollinear() {
        let a = Wall(start: Vec2(0, 0), end: Vec2(2, 0),
                     openings: [WallOpening(kind: .door, centerOffset: 1, width: 0.8, height: 2)])
        let b = Wall(start: Vec2(2, 0), end: Vec2(5, 0),
                     openings: [WallOpening(kind: .window, centerOffset: 1.5, width: 1, height: 1.2, sillHeight: 0.9)])
        let merged = GeometryCleaner.mergeCollinear([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].length, 5, accuracy: 1e-9)
        XCTAssertEqual(merged[0].openings.count, 2)
        // Door stays at 1.0 from origin; window moves to 2 + 1.5 = 3.5.
        let offsets = merged[0].openings.map(\.centerOffset).sorted()
        XCTAssertEqual(offsets[0], 1.0, accuracy: 1e-6)
        XCTAssertEqual(offsets[1], 3.5, accuracy: 1e-6)
    }

    func testMergeCollinearDoesNotMergeCorner() {
        let a = Wall(start: Vec2(0, 0), end: Vec2(2, 0))
        let b = Wall(start: Vec2(2, 0), end: Vec2(2, 3))
        XCTAssertEqual(GeometryCleaner.mergeCollinear([a, b]).count, 2)
    }

    func testMergeCollinearRespectsTJunction() {
        // Collinear pair with a third wall at the junction: must NOT merge.
        let a = Wall(start: Vec2(0, 0), end: Vec2(2, 0))
        let b = Wall(start: Vec2(2, 0), end: Vec2(5, 0))
        let t = Wall(start: Vec2(2, 0), end: Vec2(2, 3))
        XCTAssertEqual(GeometryCleaner.mergeCollinear([a, b, t]).count, 3)
    }

    func testLoopPolygonFromUnorderedWalls() {
        let walls = [
            Wall(start: Vec2(4, 3), end: Vec2(0, 3)),
            Wall(start: Vec2(0, 0), end: Vec2(4, 0)),
            Wall(start: Vec2(0, 3), end: Vec2(0, 0)),
            Wall(start: Vec2(4, 0), end: Vec2(4, 3)),
        ]
        let polygon = GeometryCleaner.loopPolygon(from: walls)
        XCTAssertNotNil(polygon)
        XCTAssertEqual(GeometryOps.area(polygon!), 12, accuracy: 1e-6)
        XCTAssertGreaterThan(GeometryOps.signedArea(polygon!), 0)
    }

    func testLoopPolygonFailsOnOpenChain() {
        let walls = [
            Wall(start: Vec2(0, 0), end: Vec2(4, 0)),
            Wall(start: Vec2(4, 0), end: Vec2(4, 3)),
            Wall(start: Vec2(4, 3), end: Vec2(0, 3)),
            // Missing closing wall entirely (1.0 gap far exceeds tolerance).
        ]
        XCTAssertNil(GeometryCleaner.loopPolygon(from: walls, tolerance: 0.15))
    }
}
