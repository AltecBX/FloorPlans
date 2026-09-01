import Foundation

// MARK: - Mesh evidence
//
// One ARMeshAnchor's geometry, kept as the scanner delivered it: vertices in
// the anchor's local frame plus the anchor transform, triangle indices and
// ARKit's per-face classification when the session provided one. This is
// the raw surface evidence behind every wall RoomPlan reports.

/// ARKit's `ARMeshClassification` raw values, mirrored so the core can read
/// them without ARKit.
public enum MeshFaceClass: UInt8, Codable, Sendable, CaseIterable {
    case none = 0
    case wall = 1
    case floor = 2
    case ceiling = 3
    case table = 4
    case seat = 5
    case window = 6
    case door = 7

    public var displayName: String {
        switch self {
        case .none: return "Unclassified"
        case .wall: return "Wall"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .table: return "Table"
        case .seat: return "Seat"
        case .window: return "Window"
        case .door: return "Door"
        }
    }
}

public struct MeshChunk: Hashable, Sendable {
    public var anchorID: UUID
    /// Anchor-to-world transform, 16 floats column-major.
    public var transform: [Float]
    /// Local vertex positions, 3 floats each.
    public var vertices: [Float]
    /// Triangle vertex indices, 3 per face.
    public var faces: [UInt32]
    /// Per-face `MeshFaceClass` raw values when ARKit classified the mesh.
    public var classification: [UInt8]?

    public init(anchorID: UUID, transform: [Float], vertices: [Float], faces: [UInt32],
                classification: [UInt8]? = nil) {
        self.anchorID = anchorID
        self.transform = transform.count == 16 ? transform : PoseSample.identity
        self.vertices = vertices
        self.faces = faces
        if let classification, classification.count == faces.count / 3 {
            self.classification = classification
        } else {
            self.classification = nil
        }
    }

    public var vertexCount: Int { vertices.count / 3 }
    public var faceCount: Int { faces.count / 3 }

    public func localVertex(_ index: Int) -> Vec3 {
        let i = index * 3
        return Vec3(Double(vertices[i]), Double(vertices[i + 1]), Double(vertices[i + 2]))
    }

    public func worldVertex(_ index: Int) -> Vec3 {
        transformToWorld(localVertex(index))
    }

    func transformToWorld(_ p: Vec3) -> Vec3 {
        let t = transform
        let x = Double(t[0]) * p.x + Double(t[4]) * p.y + Double(t[8]) * p.z + Double(t[12])
        let y = Double(t[1]) * p.x + Double(t[5]) * p.y + Double(t[9]) * p.z + Double(t[13])
        let z = Double(t[2]) * p.x + Double(t[6]) * p.y + Double(t[10]) * p.z + Double(t[14])
        return Vec3(x, y, z)
    }

    func faceVertexIndices(_ face: Int) -> (Int, Int, Int) {
        let i = face * 3
        return (Int(faces[i]), Int(faces[i + 1]), Int(faces[i + 2]))
    }

    public func faceCentroid(_ face: Int) -> Vec3 {
        let (a, b, c) = faceVertexIndices(face)
        let sum = worldVertex(a) + worldVertex(b) + worldVertex(c)
        return sum * (1.0 / 3.0)
    }

    /// Unit normal in world space; the winding decides the sign.
    public func faceNormal(_ face: Int) -> Vec3 {
        let (a, b, c) = faceVertexIndices(face)
        let pa = worldVertex(a)
        let pb = worldVertex(b)
        let pc = worldVertex(c)
        return (pb - pa).cross(pc - pa).normalized
    }

    public func faceArea(_ face: Int) -> Double {
        let (a, b, c) = faceVertexIndices(face)
        let pa = worldVertex(a)
        let pb = worldVertex(b)
        let pc = worldVertex(c)
        return (pb - pa).cross(pc - pa).length / 2
    }

    public func faceClass(_ face: Int) -> MeshFaceClass? {
        guard let classification, face < classification.count else { return nil }
        return MeshFaceClass(rawValue: classification[face])
    }

    public func worldBounds() -> (min: Vec3, max: Vec3)? {
        guard vertexCount > 0 else { return nil }
        var lo = Vec3(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = Vec3(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for i in 0..<vertexCount {
            let v = worldVertex(i)
            lo = Vec3(min(lo.x, v.x), min(lo.y, v.y), min(lo.z, v.z))
            hi = Vec3(max(hi.x, v.x), max(hi.y, v.y), max(hi.z, v.z))
        }
        return (lo, hi)
    }

    /// Face counts per `MeshFaceClass` raw value; all in bucket 0 when the
    /// mesh carries no classification.
    public func classificationHistogram() -> [Int] {
        var counts = Array(repeating: 0, count: MeshFaceClass.allCases.count)
        guard let classification else {
            counts[0] = faceCount
            return counts
        }
        for value in classification where Int(value) < counts.count {
            counts[Int(value)] += 1
        }
        return counts
    }

    public func summary(fileName: String, revision: Int, updatedAt: Double) -> MeshChunkSummary {
        let bounds = worldBounds()
        return MeshChunkSummary(
            anchorID: anchorID, fileName: fileName, revision: revision, updatedAt: updatedAt,
            vertexCount: vertexCount, faceCount: faceCount,
            boundsMin: bounds?.min, boundsMax: bounds?.max,
            classificationCounts: classificationHistogram())
    }
}

// MARK: - Binary codec

/// Compact little-endian binary format for `MeshChunk`, documented in
/// `Docs/SCAN_PIPELINE.md`. JSON would be ten times the size for the same
/// numbers and far slower to write during a scan.
public enum MeshChunkCodec {
    public static let magic: [UInt8] = Array("FPMSH001".utf8)
    static let flagClassification: UInt8 = 0x01

    public enum CodecError: Error, Equatable {
        case badMagic
        case truncated
        case badCounts
    }

    public static func encode(_ chunk: MeshChunk) -> Data {
        var data = Data()
        data.reserveCapacity(64 + chunk.vertices.count * 4 + chunk.faces.count * 4 + chunk.faceCount)
        data.append(contentsOf: magic)
        withUnsafeBytes(of: chunk.anchorID.uuid) { data.append(contentsOf: $0) }
        appendUInt32(&data, UInt32(chunk.vertexCount))
        appendUInt32(&data, UInt32(chunk.faceCount))
        data.append(chunk.classification != nil ? flagClassification : 0)
        data.append(contentsOf: [0, 0, 0])
        appendFloats(&data, chunk.transform)
        appendFloats(&data, chunk.vertices)
        chunk.faces.withUnsafeBytes { data.append(contentsOf: $0) }
        if let classification = chunk.classification {
            data.append(contentsOf: classification)
        }
        return data
    }

    public static func decode(_ input: Data) throws -> MeshChunk {
        let bytes = [UInt8](input)
        var offset = 0

        func require(_ count: Int) throws {
            guard offset + count <= bytes.count else { throw CodecError.truncated }
        }
        func readUInt32() throws -> UInt32 {
            try require(4)
            let value = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return value
        }
        func readFloats(_ count: Int) throws -> [Float] {
            try require(count * 4)
            var out = [Float](repeating: 0, count: count)
            out.withUnsafeMutableBytes { raw in
                bytes.withUnsafeBytes { src in
                    raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<(offset + count * 4)]))
                }
            }
            offset += count * 4
            return out
        }
        func readUInt32s(_ count: Int) throws -> [UInt32] {
            try require(count * 4)
            var out = [UInt32](repeating: 0, count: count)
            out.withUnsafeMutableBytes { raw in
                bytes.withUnsafeBytes { src in
                    raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<(offset + count * 4)]))
                }
            }
            offset += count * 4
            return out
        }

        try require(magic.count)
        guard Array(bytes[0..<magic.count]) == magic else { throw CodecError.badMagic }
        offset = magic.count

        try require(16)
        let uuid = uuid_t(
            bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
            bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
            bytes[offset + 8], bytes[offset + 9], bytes[offset + 10], bytes[offset + 11],
            bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15])
        offset += 16

        let vertexCount = Int(try readUInt32())
        let faceCount = Int(try readUInt32())
        try require(4)
        let flags = bytes[offset]
        offset += 4
        guard vertexCount >= 0, faceCount >= 0, vertexCount < 50_000_000, faceCount < 50_000_000 else {
            throw CodecError.badCounts
        }

        let transform = try readFloats(16)
        let vertices = try readFloats(vertexCount * 3)
        let faces = try readUInt32s(faceCount * 3)
        var classification: [UInt8]? = nil
        if flags & flagClassification != 0 {
            try require(faceCount)
            classification = Array(bytes[offset..<(offset + faceCount)])
            offset += faceCount
        }
        for index in faces where Int(index) >= vertexCount { throw CodecError.badCounts }
        return MeshChunk(anchorID: UUID(uuid: uuid), transform: transform,
                         vertices: vertices, faces: faces, classification: classification)
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }

    private static func appendFloats(_ data: inout Data, _ values: [Float]) {
        values.withUnsafeBytes { data.append(contentsOf: $0) }
    }
}

// MARK: - Face classification

/// Decides what a mesh face is. ARKit's classification is used when the
/// session provided one; otherwise the face normal and its height above the
/// floor decide, so coverage still works when RoomPlan's own configuration
/// omits mesh classification.
public struct MeshFaceClassifier: Sendable {
    /// Faces this close above the floor are floor.
    public var floorBand = 0.35
    /// Faces this close below the ceiling are ceiling.
    public var ceilingBand = 0.40
    /// |normal.y| below this is a vertical face.
    public var verticalNormalMax = 0.35
    /// |normal.y| above this is a horizontal face.
    public var horizontalNormalMin = 0.80
    /// Vertical faces below this height above the floor are furniture, not wall.
    public var wallMinimumHeight = 0.05

    public init() {}

    public func classify(_ chunk: MeshChunk, face: Int, floorElevation: Double?, ceilingElevation: Double?) -> MeshFaceClass {
        if let known = chunk.faceClass(face), known != .none { return known }
        let normal = chunk.faceNormal(face)
        let centroid = chunk.faceCentroid(face)
        let ny = abs(normal.y)
        let floor = floorElevation ?? 0
        if ny >= horizontalNormalMin {
            if centroid.y <= floor + floorBand { return .floor }
            if let ceiling = ceilingElevation, centroid.y >= ceiling - ceilingBand { return .ceiling }
            return .table
        }
        if ny <= verticalNormalMax {
            return centroid.y > floor + wallMinimumHeight ? .wall : .none
        }
        return .none
    }

    /// Floor elevation as the 5th percentile of horizontal-face heights.
    public static func estimateFloorElevation(_ chunks: [MeshChunk], horizontalNormalMin: Double = 0.8) -> Double? {
        var heights: [Double] = []
        for chunk in chunks {
            for face in 0..<chunk.faceCount {
                if let known = chunk.faceClass(face) {
                    if known == .floor { heights.append(chunk.faceCentroid(face).y) }
                    if known != .none { continue }
                }
                if abs(chunk.faceNormal(face).y) >= horizontalNormalMin {
                    heights.append(chunk.faceCentroid(face).y)
                }
            }
        }
        guard heights.count >= 10 else { return heights.min() }
        heights.sort()
        return heights[Int(Double(heights.count - 1) * 0.05)]
    }

    /// Ceiling elevation as the 95th percentile of horizontal faces at least
    /// 1.5 m above the floor.
    public static func estimateCeilingElevation(_ chunks: [MeshChunk], floorElevation: Double,
                                                horizontalNormalMin: Double = 0.8) -> Double? {
        var heights: [Double] = []
        for chunk in chunks {
            for face in 0..<chunk.faceCount {
                let y = chunk.faceCentroid(face).y
                guard y > floorElevation + 1.5 else { continue }
                if let known = chunk.faceClass(face) {
                    if known == .ceiling { heights.append(y) }
                    if known != .none { continue }
                }
                if abs(chunk.faceNormal(face).y) >= horizontalNormalMin { heights.append(y) }
            }
        }
        guard heights.count >= 10 else { return heights.max() }
        heights.sort()
        return heights[Int(Double(heights.count - 1) * 0.95)]
    }
}
