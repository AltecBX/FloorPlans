import XCTest
@testable import FieldPlanCore

/// Coverage is about mesh behind an element, not the camera having looked
/// that way. These build small tessellated planes as ARKit would deliver
/// them and check the scores that come out.
final class CoverageGridTests: XCTestCase {

    /// A tessellated plane. `origin` is one corner in world space; `u` and
    /// `v` span the plane; `step` is the triangle size.
    private func plane(origin: Vec3, u: Vec3, v: Vec3, step: Double = 0.2,
                       classification: MeshFaceClass? = nil) -> MeshChunk {
        let nu = max(1, Int((u.length / step).rounded(.up)))
        let nv = max(1, Int((v.length / step).rounded(.up)))
        var vertices: [Float] = []
        for j in 0...nv {
            for i in 0...nu {
                let p = origin + u * (Double(i) / Double(nu)) + v * (Double(j) / Double(nv))
                vertices.append(contentsOf: [Float(p.x), Float(p.y), Float(p.z)])
            }
        }
        var faces: [UInt32] = []
        for j in 0..<nv {
            for i in 0..<nu {
                let a = UInt32(j * (nu + 1) + i)
                let b = a + 1
                let c = a + UInt32(nu + 1)
                let d = c + 1
                faces.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        let classes = classification.map { Array(repeating: $0.rawValue, count: faces.count / 3) }
        return MeshChunk(anchorID: UUID(), transform: PoseSample.identity,
                         vertices: vertices, faces: faces, classification: classes)
    }

    /// 4 m × 3 m room: plan x 0…4, plan y 0…3 (world z 0…-3). Floor plus the
    /// north wall (plan y = 3) and the east wall (plan x = 4); the south and
    /// west walls have no mesh.
    private func roomMeshes(classified: Bool) -> [MeshChunk] {
        let cls: (MeshFaceClass) -> MeshFaceClass? = { classified ? $0 : nil }
        return [
            plane(origin: Vec3(0, 0, 0), u: Vec3(4, 0, 0), v: Vec3(0, 0, -3), classification: cls(.floor)),
            plane(origin: Vec3(0, 0, -3), u: Vec3(4, 0, 0), v: Vec3(0, 2.4, 0), classification: cls(.wall)),
            plane(origin: Vec3(4, 0, 0), u: Vec3(0, 0, -3), v: Vec3(0, 2.4, 0), classification: cls(.wall)),
        ]
    }

    private let roomPolygon = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)]

    func testFloorCoverageOfAScannedRoomIsComplete() {
        let grid = CoverageGrid.build(chunks: roomMeshes(classified: true))
        XCTAssertGreaterThanOrEqual(grid.floorCoverage(of: roomPolygon), 0.9)
        XCTAssertTrue(grid.unobservedFloorCells(in: roomPolygon).count <= 4)
        XCTAssertEqual(grid.observedFloorArea, 12, accuracy: 1.5)
    }

    func testWallCoverageDistinguishesScannedAndUnscannedWalls() {
        let grid = CoverageGrid.build(chunks: roomMeshes(classified: true))
        let north = grid.wallCoverage(from: Vec2(0, 3), to: Vec2(4, 3))
        let south = grid.wallCoverage(from: Vec2(0, 0), to: Vec2(4, 0))
        XCTAssertGreaterThanOrEqual(north.fraction, 0.9, "north wall has mesh")
        XCTAssertEqual(south.fraction, 0, "south wall has none")
        XCTAssertTrue(north.gaps.isEmpty)
        XCTAssertEqual(south.gaps.count, 1)
        XCTAssertEqual(south.gaps.first?.length ?? 0, 4, accuracy: 1e-6)
    }

    func testPartialWallReportsTheGap() {
        // Only the western half of the north wall is meshed.
        let chunks = [
            plane(origin: Vec3(0, 0, -3), u: Vec3(2, 0, 0), v: Vec3(0, 2.4, 0), classification: .wall),
        ]
        let grid = CoverageGrid.build(chunks: chunks, floorElevation: 0)
        let coverage = grid.wallCoverage(from: Vec2(0, 3), to: Vec2(4, 3))
        XCTAssertEqual(coverage.fraction, 0.55, accuracy: 0.12)
        XCTAssertEqual(coverage.gaps.count, 1)
        XCTAssertGreaterThan(coverage.gaps.first?.start ?? 0, 1.8)
    }

    func testGeometricClassificationWorksWithoutARKitLabels() {
        let grid = CoverageGrid.build(chunks: roomMeshes(classified: false))
        XCTAssertEqual(grid.floorElevation ?? 9, 0, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(grid.floorCoverage(of: roomPolygon), 0.9)
        XCTAssertGreaterThanOrEqual(grid.wallCoverage(from: Vec2(4, 0), to: Vec2(4, 3)).fraction, 0.9)
        XCTAssertEqual(grid.wallCoverage(from: Vec2(0, 0), to: Vec2(0, 3)).fraction, 0)
    }

    func testCornerCoverage() {
        let grid = CoverageGrid.build(chunks: roomMeshes(classified: true))
        XCTAssertGreaterThan(grid.cornerCoverage(at: Vec2(4, 3)), 0.25, "north-east corner has both walls")
        XCTAssertEqual(grid.cornerCoverage(at: Vec2(0, 0)), 0, "south-west corner has neither")
    }

    func testCameraVisitsAreCounted() {
        var grid = CoverageGrid()
        grid.addCameraPosition(Vec2(1, 1), time: 1)
        grid.addCameraPosition(Vec2(1.1, 1.05), time: 2)
        XCTAssertEqual(grid.visits(in: roomPolygon), 2)
        XCTAssertEqual(grid.visits(in: [Vec2(10, 10), Vec2(12, 10), Vec2(12, 12)]), 0)
    }

    func testAdvisorFlagsUnscannedWallsAndCorners() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 4 / UnitConstants.metersPerFoot,
                                                   depthFeet: 3 / UnitConstants.metersPerFoot)
        let grid = CoverageGrid.build(chunks: roomMeshes(classified: true))
        let report = CoverageAdvisor.report(level: level, grid: grid)
        XCTAssertTrue(report.advice.contains(.wallNotCovered))
        XCTAssertTrue(report.advice.contains(.cornerNotCovered))
        let fractions = level.walls.map { report.wallCoverage[$0.id]?.fraction ?? -1 }.sorted()
        XCTAssertEqual(fractions.filter { $0 < 0.1 }.count, 2, "two walls have no mesh: \(fractions)")
        XCTAssertEqual(fractions.filter { $0 > 0.9 }.count, 2)
        XCTAssertGreaterThanOrEqual(report.floorCoverage[level.rooms[0].id] ?? 0, 0.9)
    }

    func testEvidenceAttachmentScoresWallsByCoverage() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 4 / UnitConstants.metersPerFoot,
                                                   depthFeet: 3 / UnitConstants.metersPerFoot)
        for i in level.walls.indices {
            level.walls[i].source = .lidarScanned
            level.walls[i].confidence = .high
        }
        let grid = CoverageGrid.build(chunks: roomMeshes(classified: true))
        let scored = EvidenceAttachment.attach(to: level, grid: grid, trackingNormalFraction: 1.0, sessionID: UUID())
        let scores = scored.walls.compactMap { $0.evidence?.confidence }.sorted()
        XCTAssertEqual(scores.count, 4)
        XCTAssertLessThan(scores[0], 0.65, "an unmeshed wall scores low")
        XCTAssertGreaterThan(scores[3], 0.85, "a fully meshed wall scores high")
        XCTAssertNotNil(scored.rooms[0].evidence)
        XCTAssertLessThan(scored.rooms[0].evidence!.confidence, scores[3],
                          "the room is no better than its weakest walls allow")
    }
}
