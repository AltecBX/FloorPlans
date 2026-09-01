import XCTest
@testable import FieldPlanCore

/// The sensor log and mesh chunks are what a future reconstruction pass reads
/// instead of revisiting the property, so their round trips must be exact.
final class ScanEvidenceTests: XCTestCase {

    func testPoseTransformHelperFacesTheYaw() {
        let pose = PoseSample(time: 0, transform: PoseSample.transform(position: Vec3(1, 1.5, -2), yaw: .pi / 2))
        XCTAssertEqual(pose.position.x, 1, accuracy: 1e-6)
        XCTAssertEqual(pose.position.y, 1.5, accuracy: 1e-6)
        XCTAssertEqual(pose.position.z, -2, accuracy: 1e-6)
        // Plan heading π/2 is plan +Y, which is world -Z.
        XCTAssertEqual(pose.forward.x, 0, accuracy: 1e-6)
        XCTAssertEqual(pose.forward.z, -1, accuracy: 1e-6)
        XCTAssertEqual(pose.planHeading ?? -9, .pi / 2, accuracy: 1e-6)
        XCTAssertEqual(pose.up.y, 1, accuracy: 1e-6)
    }

    func testMeshChunkRoundTrip() throws {
        let chunk = MeshChunk(
            anchorID: UUID(),
            transform: PoseSample.transform(position: Vec3(1, 0, -1), yaw: 0.3),
            vertices: [0, 0, 0, 1, 0, 0, 1, 0, -1, 0, 0, -1],
            faces: [0, 1, 2, 0, 2, 3],
            classification: [MeshFaceClass.floor.rawValue, MeshFaceClass.floor.rawValue])
        let data = MeshChunkCodec.encode(chunk)
        XCTAssertEqual(Array(data.prefix(8)), MeshChunkCodec.magic)
        let decoded = try MeshChunkCodec.decode(data)
        XCTAssertEqual(decoded, chunk)
        XCTAssertEqual(decoded.faceCount, 2)
        XCTAssertEqual(decoded.classificationHistogram()[Int(MeshFaceClass.floor.rawValue)], 2)
    }

    func testMeshChunkWithoutClassificationRoundTrips() throws {
        let chunk = MeshChunk(anchorID: UUID(), transform: PoseSample.identity,
                              vertices: [0, 0, 0, 1, 0, 0, 0, 0, 1], faces: [0, 1, 2])
        let decoded = try MeshChunkCodec.decode(MeshChunkCodec.encode(chunk))
        XCTAssertNil(decoded.classification)
        XCTAssertEqual(decoded.classificationHistogram()[0], 1)
    }

    func testCodecRejectsGarbage() {
        XCTAssertThrowsError(try MeshChunkCodec.decode(Data("not a mesh".utf8)))
        var truncated = MeshChunkCodec.encode(MeshChunk(
            anchorID: UUID(), transform: PoseSample.identity,
            vertices: [0, 0, 0, 1, 0, 0, 0, 0, 1], faces: [0, 1, 2]))
        truncated.removeLast(6)
        XCTAssertThrowsError(try MeshChunkCodec.decode(truncated))
    }

    func testWorldVertexAppliesTransform() {
        var transform = PoseSample.identity
        transform[12] = 2; transform[13] = 3; transform[14] = 4
        let chunk = MeshChunk(anchorID: UUID(), transform: transform,
                              vertices: [1, 1, 1], faces: [])
        let world = chunk.worldVertex(0)
        XCTAssertEqual(world.x, 3, accuracy: 1e-6)
        XCTAssertEqual(world.y, 4, accuracy: 1e-6)
        XCTAssertEqual(world.z, 5, accuracy: 1e-6)
    }

    func testFaceNormalAndArea() {
        // Floor triangle in the XZ plane: normal is vertical, area 0.5.
        let chunk = MeshChunk(anchorID: UUID(), transform: PoseSample.identity,
                              vertices: [0, 0, 0, 1, 0, 0, 0, 0, 1], faces: [0, 1, 2])
        XCTAssertEqual(abs(chunk.faceNormal(0).y), 1, accuracy: 1e-9)
        XCTAssertEqual(chunk.faceArea(0), 0.5, accuracy: 1e-9)
        let c = chunk.faceCentroid(0)
        XCTAssertEqual(c.x, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testSessionSummaryFromAWalk() {
        var log = ScanSessionLog()
        // 10 s at 1 m/s along +X, 10 Hz, normal tracking, depth on.
        for i in 0...100 {
            let t = Double(i) / 10
            log.poses.append(PoseSample(
                time: t, transform: PoseSample.transform(position: Vec3(t, 1.4, 0), yaw: 0),
                tracking: i < 20 ? .initializing : .normal,
                depthAvailable: true,
                depthConfidence: DepthConfidenceStats(high: 0.8, medium: 0.15, low: 0.05)))
        }
        log.finalize(endedAt: log.startedAt.addingTimeInterval(10))
        let s = log.summary!
        XCTAssertEqual(s.distanceWalked, 10, accuracy: 1e-6)
        XCTAssertEqual(s.meanSpeed, 1, accuracy: 1e-6)
        XCTAssertEqual(s.maxSpeed, 1, accuracy: 0.05)
        XCTAssertEqual(s.trackingNormalFraction, 81.0 / 101.0, accuracy: 1e-9)
        XCTAssertEqual(s.depthAvailableFraction, 1, accuracy: 1e-9)
        XCTAssertEqual(s.meanDepthHighConfidence ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(s.duration, 10, accuracy: 1e-6)
    }

    func testDistanceWalkedIgnoresRelocalisationJumps() {
        var log = ScanSessionLog()
        log.poses = [
            PoseSample(time: 0, transform: PoseSample.transform(position: Vec3(0, 0, 0), yaw: 0)),
            PoseSample(time: 1, transform: PoseSample.transform(position: Vec3(1, 0, 0), yaw: 0)),
            PoseSample(time: 2, transform: PoseSample.transform(position: Vec3(9, 0, 0), yaw: 0)), // jump
            PoseSample(time: 3, transform: PoseSample.transform(position: Vec3(10, 0, 0), yaw: 0)),
        ]
        XCTAssertEqual(log.distanceWalked(), 2, accuracy: 1e-9)
    }

    func testSessionLogJSONRoundTrip() throws {
        var log = ScanSessionLog(device: DeviceInfo(model: "iPhone17,3", systemVersion: "18.0",
                                                    appVersion: "1.1", appBuild: "12", hasLiDAR: true))
        log.poses = [PoseSample(time: 0.1, transform: PoseSample.identity, tracking: .normal)]
        log.headings = [HeadingSample(time: 0.1, magneticHeading: 90, trueHeading: 92, accuracy: 5, cameraPlanHeading: 0)]
        log.events = [SessionEvent(time: 0, kind: .sessionStarted)]
        log.meshes = [MeshChunkSummary(anchorID: UUID(), fileName: "a.fpmesh", revision: 2, updatedAt: 3,
                                       vertexCount: 10, faceCount: 4)]
        let data = try ProjectArchive.encoder().encode(log)
        let decoded = try ProjectArchive.decoder().decode(ScanSessionLog.self, from: data)
        XCTAssertEqual(decoded.poses.count, 1)
        XCTAssertEqual(decoded.headings.first?.trueHeading, 92)
        XCTAssertEqual(decoded.meshes.first?.revision, 2)
        XCTAssertEqual(decoded.device?.hasLiDAR, true)
    }

    func testNorthEstimatorFromCompassAndCameraHeading() {
        // Camera faces plan +X while the compass reads 90° (pointing east):
        // north is 90° counter-clockwise from +X, i.e. plan +Y, so the
        // north angle relative to +Y is zero.
        let east = (0..<6).map { i in
            HeadingSample(time: Double(i), magneticHeading: 90, trueHeading: nil,
                          accuracy: 10, cameraPlanHeading: 0)
        }
        XCTAssertEqual(NorthEstimator.northAngle(from: east) ?? 9, 0, accuracy: 1e-9)

        // Camera faces +X and the compass reads 0 (pointing north): north is
        // plan +X, a quarter turn clockwise from +Y.
        let north = (0..<6).map { i in
            HeadingSample(time: Double(i), magneticHeading: 0, accuracy: 10, cameraPlanHeading: 0)
        }
        XCTAssertEqual(NorthEstimator.northAngle(from: north) ?? 9, -.pi / 2, accuracy: 1e-9)

        // Too few samples, or invalid accuracy, gives nothing.
        XCTAssertNil(NorthEstimator.northAngle(from: Array(east.prefix(3))))
        let bad = east.map { s in var c = s; c.accuracy = -1; return c }
        XCTAssertNil(NorthEstimator.northAngle(from: bad))
    }
}
