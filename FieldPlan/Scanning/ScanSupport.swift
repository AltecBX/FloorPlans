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

    /// Column-major 16 floats, the layout the core's evidence types use.
    static func floats(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    static func confidenceLevel(_ confidence: CapturedRoom.Confidence) -> Int {
        switch confidence {
        case .high: return 2
        case .medium: return 1
        case .low: return 0
        @unknown default: return 1
        }
    }

    static func curveDTO(_ curve: CapturedRoom.Surface.Curve?) -> ScannedCurveDTO? {
        guard let curve else { return nil }
        return ScannedCurveDTO(
            center: Vec2(Double(curve.center.x), Double(curve.center.y)),
            radius: Double(curve.radius),
            startAngle: curve.startAngle.converted(to: .radians).value,
            endAngle: curve.endAngle.converted(to: .radians).value)
    }

    static func surfaceDTO(_ surface: CapturedRoom.Surface, kind: ScannedSurfaceKind) -> ScannedSurfaceDTO {
        // RoomPlan reports whether a door stood open; nothing else about a
        // door's operation is in the capture.
        var isDoorOpen: Bool? = nil
        if case .door(let isOpen) = surface.category {
            isDoorOpen = isOpen
        }
        return ScannedSurfaceDTO(
            id: surface.identifier,
            kind: kind,
            center: center(of: surface.transform),
            xAxis: xAxis(of: surface.transform),
            width: Double(surface.dimensions.x),
            height: Double(surface.dimensions.y),
            thickness: nil,
            polygonCorners: surface.polygonCorners.map { worldPoint($0, transform: surface.transform) },
            confidenceLevel: confidenceLevel(surface.confidence),
            parentID: surface.parentIdentifier,
            isDoorOpen: isDoorOpen,
            transform: floats(surface.transform),
            curve: curveDTO(surface.curve),
            story: surface.story
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
                confidenceLevel: confidenceLevel(object.confidence),
                attributes: object.attributes.map { String(describing: $0) },
                story: object.story,
                parentID: object.parentIdentifier)
        }

        // RoomPlan's room classification (iOS 17 sections): every section
        // with its centre, so a continuous capture can type each of the rooms
        // it contains; the first one doubles as the overall suggestion.
        let sections = room.sections.map { section in
            ScannedSectionDTO(
                label: String(describing: section.label),
                center: vec3(section.center),
                story: section.story)
        }
        let sectionLabel: String? = sections.first?.label

        return ScannedRoomDTO(
            id: room.identifier,
            suggestedName: name,
            suggestedType: sectionLabel,
            surfaces: surfaces,
            objects: objects,
            capturedAt: Date(),
            sections: sections
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

    /// Maps RoomPlan's coaching instruction onto the advice vocabulary so it
    /// shares one prioritised list with the quality engine.
    static func adviceKind(for instruction: RoomCaptureSession.Instruction) -> ScanAdviceKind? {
        switch instruction {
        case .moveCloseToWall: return .moveCloser
        case .moveAwayFromWall: return .moveAway
        case .slowDown: return .slowDown
        case .turnOnLight: return .lowLight
        case .lowTexture: return .lowTexture
        case .normal: return nil
        @unknown default: return nil
        }
    }
}
