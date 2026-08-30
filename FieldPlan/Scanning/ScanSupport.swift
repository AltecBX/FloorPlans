import Foundation
import RoomPlan
import ARKit
import simd
import FieldPlanCore

/// Device capability detection (spec §3). Checked once at first use; the
/// scanner UI is never presented on unsupported hardware.
enum ScanCapability {
    /// RoomPlan requires a LiDAR device with A14+ silicon.
    static var isRoomPlanSupported: Bool {
        RoomCaptureSession.isSupported
    }

    static var isSceneReconstructionSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
}

// MARK: - CapturedRoom → DTO bridge
//
// The ONLY code that touches RoomPlan types for geometry. Everything after
// this mechanical mapping runs through FieldPlanCore's tested conversion.

enum CapturedRoomBridge {

    static func vec3(_ v: simd_float3) -> Vec3 {
        Vec3(Double(v.x), Double(v.y), Double(v.z))
    }

    static func center(of transform: simd_float4x4) -> Vec3 {
        let c = transform.columns.3
        return Vec3(Double(c.x), Double(c.y), Double(c.z))
    }

    static func xAxis(of transform: simd_float4x4) -> Vec3 {
        let c = transform.columns.0
        return Vec3(Double(c.x), Double(c.y), Double(c.z))
    }

    static func worldPoint(_ local: simd_float3, transform: simd_float4x4) -> Vec3 {
        let world = transform * simd_float4(local, 1)
        return Vec3(Double(world.x), Double(world.y), Double(world.z))
    }

    static func confidenceLevel(_ confidence: CapturedRoom.Confidence) -> Int {
        switch confidence {
        case .high: return 2
        case .medium: return 1
        case .low: return 0
        @unknown default: return 1
        }
    }

    static func surfaceDTO(_ surface: CapturedRoom.Surface, kind: ScannedSurfaceKind) -> ScannedSurfaceDTO {
        ScannedSurfaceDTO(
            id: surface.identifier,
            kind: kind,
            center: center(of: surface.transform),
            xAxis: xAxis(of: surface.transform),
            width: Double(surface.dimensions.x),
            height: Double(surface.dimensions.y),
            thickness: nil,
            polygonCorners: surface.polygonCorners.map { worldPoint($0, transform: surface.transform) },
            confidenceLevel: confidenceLevel(surface.confidence),
            parentID: surface.parentIdentifier
        )
    }

    static func objectCategoryName(_ category: CapturedRoom.Object.Category) -> String {
        // String(describing:) yields the case name ("refrigerator", "sofa"),
        // which FieldPlanCore maps to a fixture category — robust against
        // future RoomPlan categories (they fall through to .custom).
        String(describing: category)
    }

    /// Converts one processed CapturedRoom to the platform-independent DTO.
    static func dto(from room: CapturedRoom, name: String?) -> ScannedRoomDTO {
        var surfaces: [ScannedSurfaceDTO] = []
        surfaces.append(contentsOf: room.walls.map { surfaceDTO($0, kind: .wall) })
        surfaces.append(contentsOf: room.windows.map { surfaceDTO($0, kind: .window) })
        surfaces.append(contentsOf: room.openings.map { surfaceDTO($0, kind: .opening) })
        surfaces.append(contentsOf: room.doors.map { surfaceDTO($0, kind: .door) })
        surfaces.append(contentsOf: room.floors.map { surfaceDTO($0, kind: .floor) })

        let objects = room.objects.map { object in
            ScannedObjectDTO(
                id: object.identifier,
                categoryName: objectCategoryName(object.category),
                center: center(of: object.transform),
                xAxis: xAxis(of: object.transform),
                dimensions: Vec3(
                    Double(object.dimensions.x),
                    Double(object.dimensions.y),
                    Double(object.dimensions.z)),
                confidenceLevel: confidenceLevel(object.confidence))
        }

        // RoomPlan's own room classification (iOS 17 sections). The case name
        // ("livingRoom", "bathroom", …) feeds FieldPlanCore's type mapping;
        // when it's absent or unidentified, the core infers the type from the
        // fixtures found in the room.
        let sectionLabel: String? = room.sections.first.map { String(describing: $0.label) }

        return ScannedRoomDTO(
            id: room.identifier,
            suggestedName: name,
            suggestedType: sectionLabel,
            surfaces: surfaces,
            objects: objects,
            capturedAt: Date()
        )
    }

    // MARK: - Raw scan persistence (spec §10)

    /// Serializes the processed CapturedRoom so it can be re-processed later
    /// without revisiting the property.
    static func rawJSON(for room: CapturedRoom) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(room)
    }

    static func loadRawRoom(from data: Data) throws -> CapturedRoom {
        try JSONDecoder().decode(CapturedRoom.self, from: data)
    }
}
