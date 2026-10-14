import SceneKit
import Metal
import UIKit
import FieldPlanCore

/// Offscreen dollhouse rendering (spec §35 "3D screenshots"): the same scene
/// the interactive viewer builds, photographed from its dollhouse view for
/// reports and PNG/JPG export — the client-facing 3D view that pairs with
/// the 2D plan on one page.
@MainActor
enum ThreeDSnapshot {

    /// Renders levels to an image on a white background. Returns nil when
    /// there is no geometry or the device has no Metal support.
    ///
    /// Rendered at twice the size and scaled down, on top of 4× multisampling,
    /// so trim, window bars and wall edges stay crisp in a printed report.
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

        let dollhouse = DollhouseScene()
        var configuration = DollhouseScene.Configuration()
        configuration.mode = mode
        configuration.furniture = showFurniture
        // The 2D plan beside it carries the names.
        configuration.labels = false
        dollhouse.update(levels: levels, version: 1, configuration: configuration)
        dollhouse.scene.background.contents = UIColor.white
        dollhouse.placeCamera(.dollhouse, aspect: Float(size.width / max(size.height, 1)))

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = dollhouse.scene
        renderer.pointOfView = dollhouse.cameraNode
        // The scene lights itself; the headlight would flatten the shadows.
        renderer.autoenablesDefaultLighting = false

        let supersample: CGFloat = 2
        let large = renderer.snapshot(
            atTime: 0,
            with: CGSize(width: size.width * supersample, height: size.height * supersample),
            antialiasingMode: .multisampling4X)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.interpolationQuality = .high
            large.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
