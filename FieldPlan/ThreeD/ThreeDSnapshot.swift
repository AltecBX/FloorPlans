import SceneKit
import Metal
import UIKit
import FieldPlanCore

/// Offscreen dollhouse rendering (spec §35 "3D screenshots"): the same scene
/// the interactive viewer builds, photographed from a high three-quarter
/// angle for reports and PNG export — the client-facing 3D view that pairs
/// with the 2D plan on one page.
@MainActor
enum ThreeDSnapshot {

    /// Renders levels to an image on a white background. Returns nil when
    /// there is no geometry or the device has no Metal support.
    static func render(
        levels: [LevelGeometry],
        mode: PlanRenderMode = .existing,
        size: CGSize = CGSize(width: 1600, height: 1200),
        showFurniture: Bool = true
    ) -> UIImage? {
        guard levels.contains(where: { !$0.walls.isEmpty || !$0.rooms.isEmpty }) else { return nil }
        guard let device = MTLCreateSystemDefaultDevice() else {
            AppLog.export.error("Metal unavailable; 3D snapshot skipped")
            return nil
        }

        let scene = ThreeDSceneBuilder.build(levels: levels, mode: mode, showFurniture: showFurniture)
        scene.background.contents = UIColor.white

        // High three-quarter presentation camera (dollhouse look).
        let (center, radius) = ThreeDSceneBuilder.boundingSphere(of: levels)
        let cameraNode = scene.rootNode.childNodes.first { $0.camera != nil }
        if let cameraNode {
            let distance = max(radius * 2.1, 6)
            cameraNode.position = SCNVector3(
                Float(center.x + distance * 0.52),
                Float(distance * 1.05),
                Float(-center.y + distance * 0.52))
            cameraNode.look(at: SCNVector3(Float(center.x), 0, Float(-center.y)))
        }

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        // The scene lights itself; the headlight would flatten the shadows.
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
