import SceneKit
import UIKit
import FieldPlanCore

/// Lighting, materials and floor textures for the dollhouse.
///
/// The geometry was never what made the 3D view look cheap. It was rendering
/// with `autoenablesDefaultLighting` — one flat headlight, no shadows, no
/// ambient occlusion — over untextured solid colours. Under that setup *any*
/// model reads as moulded plastic, however well it is shaped.
///
/// This is the presentation layer a marketing floor plan actually uses: a warm
/// key light that casts soft shadows, a cool fill so shadowed sides do not go
/// black, image-based ambient light for physically-based materials, screen
/// space ambient occlusion to seat objects on the floor, and real floor
/// textures per room type. Every texture is drawn in code — nothing to license,
/// nothing to download, and it scales to any room size.
enum SceneStyling {

    // MARK: - Lighting

    /// Replaces the default headlight with a three-point rig plus environment.
    /// Call once per built scene; the caller must also switch
    /// `autoenablesDefaultLighting` off or the headlight flattens all of it.
    static func applyLighting(to scene: SCNScene, radius: Double) {
        let extent = max(radius, 4)

        // Key: warm, high and off to one side, casting the soft shadows that
        // give the model depth. Orthographic extent has to cover the whole
        // floor or shadows clip at the edges.
        let key = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 900
        keyLight.temperature = 5200
        keyLight.castsShadow = true
        keyLight.shadowMode = .deferred
        keyLight.shadowRadius = 8
        keyLight.shadowSampleCount = 16
        keyLight.shadowColor = UIColor(white: 0, alpha: 0.34)
        keyLight.orthographicScale = extent * 1.6
        keyLight.zNear = 0.1
        keyLight.zFar = extent * 8
        key.light = keyLight
        key.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
        scene.rootNode.addChildNode(key)

        // Fill: cool and opposite, so shadowed faces read as shade, not soot.
        let fill = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 320
        fillLight.temperature = 7200
        fillLight.castsShadow = false
        fill.light = fillLight
        fill.eulerAngles = SCNVector3(-Float.pi / 5, -Float.pi * 0.8, 0)
        scene.rootNode.addChildNode(fill)

        let ambient = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 260
        ambientLight.color = UIColor(white: 0.98, alpha: 1)
        ambient.light = ambientLight
        scene.rootNode.addChildNode(ambient)

        // Image-based lighting: physically-based materials need an environment
        // to reflect or they look chalky. A soft vertical gradient is enough.
        scene.lightingEnvironment.contents = environmentGradient()
        scene.lightingEnvironment.intensity = 1.1
        scene.background.contents = UIColor(white: 0.93, alpha: 1)
    }

    /// Camera treatment that seats objects on the floor and lifts the whites.
    static func styleCamera(_ camera: SCNCamera) {
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0.18
        camera.bloomThreshold = 0.85
        camera.bloomBlurRadius = 8
        camera.screenSpaceAmbientOcclusionIntensity = 0.55
        camera.screenSpaceAmbientOcclusionRadius = 0.35
        camera.screenSpaceAmbientOcclusionBias = 0.03
        camera.zFar = 500
    }

    // MARK: - Materials

    static func wallMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.97, alpha: 1)
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.92
        material.metalness.contents = 0.0
        return material
    }

    /// Floor finish per room: wood in living space, tile in wet rooms, carpet
    /// in bedrooms — the read that makes a dollhouse look designed.
    static func floorMaterial(for type: RoomType) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.0

        switch type {
        case .bathroom, .powderRoom, .laundry, .utilityRoom, .mechanicalRoom:
            material.diffuse.contents = tileTexture()
            material.roughness.contents = 0.35
            repeatTexture(material, tilesPerMeter: 2.2)
        case .bedroom:
            material.diffuse.contents = carpetTexture()
            material.roughness.contents = 0.95
            repeatTexture(material, tilesPerMeter: 1.4)
        case .garage, .basement:
            material.diffuse.contents = UIColor(white: 0.72, alpha: 1)
            material.roughness.contents = 0.9
        default:
            material.diffuse.contents = woodTexture()
            material.roughness.contents = 0.55
            repeatTexture(material, tilesPerMeter: 0.9)
        }
        return material
    }

    private static func repeatTexture(_ material: SCNMaterial, tilesPerMeter: Double) {
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        let scale = Float(tilesPerMeter)
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(scale, scale, 1)
    }

    // MARK: - Procedural textures

    private static let textureSize = CGSize(width: 512, height: 512)

    /// Oak planks with staggered joints and a little grain. Seamless
    /// horizontally so the repeat does not show a visible seam.
    static func woodTexture() -> UIImage {
        image { context, size in
            let base = UIColor(red: 0.80, green: 0.68, blue: 0.53, alpha: 1)
            base.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let plankHeight = size.height / 6
            for row in 0..<6 {
                let y = CGFloat(row) * plankHeight
                // Alternate the joint offset so rows stagger like a real floor.
                let offset = row % 2 == 0 ? 0 : size.width / 2
                let shade = 0.94 + Double(row % 3) * 0.035
                UIColor(red: 0.80 * shade, green: 0.68 * shade, blue: 0.53 * shade, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: y, width: size.width, height: plankHeight - 1))

                // Joint line, drawn twice so it wraps at the tile edge.
                UIColor(red: 0.60, green: 0.48, blue: 0.36, alpha: 0.75).setFill()
                context.fill(CGRect(x: offset, y: y, width: 1.5, height: plankHeight))
                context.fill(CGRect(x: 0, y: y + plankHeight - 1, width: size.width, height: 1))

                // Grain.
                UIColor(red: 0.68, green: 0.56, blue: 0.42, alpha: 0.18).setFill()
                for grain in 0..<3 {
                    let gy = y + plankHeight * CGFloat(grain + 1) / 4
                    context.fill(CGRect(x: 0, y: gy, width: size.width, height: 0.8))
                }
            }
        }
    }

    /// Square tile with grout, for wet rooms.
    static func tileTexture() -> UIImage {
        image { context, size in
            UIColor(red: 0.80, green: 0.79, blue: 0.77, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let count = 4
            let tile = size.width / CGFloat(count)
            let grout: CGFloat = 3
            for row in 0..<count {
                for column in 0..<count {
                    let shade = 0.97 + Double((row + column) % 2) * 0.03
                    UIColor(red: 0.91 * shade, green: 0.91 * shade, blue: 0.90 * shade, alpha: 1).setFill()
                    context.fill(CGRect(
                        x: CGFloat(column) * tile + grout / 2,
                        y: CGFloat(row) * tile + grout / 2,
                        width: tile - grout,
                        height: tile - grout))
                }
            }
        }
    }

    /// Flat weave with fibre noise, for bedrooms.
    static func carpetTexture() -> UIImage {
        image { context, size in
            UIColor(red: 0.85, green: 0.82, blue: 0.78, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // Deterministic speckle: a fixed pattern beats a random one, which
            // would change every launch and shimmer between renders.
            var seed: UInt64 = 0x5EED
            func next() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double((seed >> 33) % 1000) / 1000
            }
            for _ in 0..<2600 {
                let x = CGFloat(next()) * size.width
                let y = CGFloat(next()) * size.height
                let dark = next() > 0.5
                let alpha = CGFloat(0.05 + next() * 0.06)
                (dark ? UIColor.black : UIColor.white).withAlphaComponent(alpha).setFill()
                context.fill(CGRect(x: x, y: y, width: 2.5, height: 2.5))
            }
        }
    }

    /// Soft sky-to-floor gradient used as the lighting environment.
    private static func environmentGradient() -> UIImage {
        image { context, size in
            let colors = [
                UIColor(white: 1.0, alpha: 1).cgColor,
                UIColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1).cgColor,
                UIColor(white: 0.62, alpha: 1).cgColor,
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.55, 1]) else { return }
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: [])
        }
    }

    private static func image(_ draw: (CGContext, CGSize) -> Void) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: textureSize)
        return renderer.image { context in
            draw(context.cgContext, textureSize)
        }
    }
}
