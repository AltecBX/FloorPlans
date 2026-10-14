import SceneKit
import UIKit
import FieldPlanCore

/// How the dollhouse looks: materials for every surface the core model
/// names, the light that falls on them, and the camera that sees them.
///
/// The geometry decides *where* things are (`DollhouseBuilder`, in the core);
/// this only decides what each surface is made of. Everything is drawn in
/// code — the floor textures, the sky the materials reflect — so there is
/// nothing to license or download and the look is identical offline.
///
/// Texture coordinates from the core are in metres, so each texture is
/// scaled to its real size: a plank is 15 cm wide in a closet and in a
/// ballroom, and a floor tile is 30 cm wherever it is laid.
@MainActor
enum SceneStyling {

    // MARK: - Colours

    struct RGB {
        var r: Double, g: Double, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        var color: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
        func mixed(with other: RGB, _ t: Double) -> RGB {
            RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
        }
    }

    /// Proposed new work and work to be demolished — the plan's blue and red.
    static let newWork = RGB(0.27, 0.50, 0.90)
    static let demolition = RGB(0.88, 0.32, 0.29)

    // MARK: - Materials

    private static var cache: [String: SCNMaterial] = [:]

    /// The material for a surface, shared between every node that uses it.
    static func material(_ kind: DollhouseMaterial, tint: DollhouseTint) -> SCNMaterial {
        let key = "\(kind.name)|\(tint.rawValue)"
        if let cached = cache[key] { return cached }
        let material = makeMaterial(kind, tint: tint)
        material.name = key
        cache[key] = material
        return material
    }

    private struct Finish {
        var color: RGB
        var roughness: Double
        var metalness: Double = 0
        /// A texture and the metres one repeat covers.
        var texture: (image: UIImage, metres: Double)? = nil
    }

    private static func finish(for kind: DollhouseMaterial) -> Finish {
        switch kind {
        case .wall: return Finish(color: RGB(0.93, 0.92, 0.89), roughness: 0.88)
        // The cut top of a wall, in the dark of an architectural section.
        case .wallCap: return Finish(color: RGB(0.25, 0.26, 0.28), roughness: 0.7)
        case .floor(.wood):
            return Finish(color: RGB(0.70, 0.53, 0.37), roughness: 0.42, texture: (wood, 0.9))
        case .floor(.tile):
            return Finish(color: RGB(0.86, 0.85, 0.83), roughness: 0.22, texture: (tile, 1.2))
        case .floor(.carpet):
            return Finish(color: RGB(0.76, 0.73, 0.68), roughness: 1.0, texture: (carpet, 0.5))
        case .floor(.concrete):
            return Finish(color: RGB(0.62, 0.61, 0.59), roughness: 0.75, texture: (concrete, 2.0))
        case .floor(.stone):
            return Finish(color: RGB(0.68, 0.65, 0.60), roughness: 0.6, texture: (stone, 1.2))
        case .threshold: return Finish(color: RGB(0.60, 0.46, 0.32), roughness: 0.4)
        // Satin-painted woodwork, a touch brighter and glossier than the walls.
        case .baseboard, .trim, .windowFrame: return Finish(color: RGB(0.97, 0.97, 0.95), roughness: 0.32)
        case .ceiling: return Finish(color: RGB(0.97, 0.97, 0.96), roughness: 0.95)
        case .doorLeaf: return Finish(color: RGB(0.95, 0.94, 0.91), roughness: 0.38)
        // Brushed nickel.
        case .hardware: return Finish(color: RGB(0.66, 0.67, 0.69), roughness: 0.28, metalness: 1)
        case .glass: return Finish(color: RGB(0.78, 0.87, 0.92), roughness: 0.04)
        case .windowSill: return Finish(color: RGB(0.92, 0.91, 0.88), roughness: 0.35)
        case .fixture: return Finish(color: RGB(0.88, 0.89, 0.91), roughness: 0.45)
        case .furniture: return Finish(color: RGB(0.72, 0.67, 0.60), roughness: 0.8)
        }
    }

    private static func makeMaterial(_ kind: DollhouseMaterial, tint: DollhouseTint) -> SCNMaterial {
        let finish = finish(for: kind)
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = finish.roughness
        material.metalness.contents = finish.metalness

        let target: RGB?
        switch tint {
        case .none: target = nil
        case .new: target = newWork
        case .demolish: target = demolition
        }

        if let target, kind != .glass {
            // Renovation work reads by colour, as on the plan: walls take it
            // fully, the detail on them leans toward it so it still reads.
            let amount = kind == .wall ? 0.88 : (kind == .wallCap ? 0.55 : 0.6)
            material.diffuse.contents = finish.color.mixed(with: target, amount).color
        } else if let texture = finish.texture {
            material.diffuse.contents = texture.image
            let scale = Float(1 / texture.metres)
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(scale, scale, 1)
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            material.diffuse.mipFilter = .linear
            material.diffuse.maxAnisotropy = 16
        } else {
            material.diffuse.contents = finish.color.color
        }

        if kind == .glass {
            material.transparency = 0.22
            material.transparencyMode = .dualLayer
            material.writesToDepthBuffer = false
        }
        return material
    }

    // MARK: - Lighting

    /// Sun, fill and sky light sized to the model, and a ground that shows
    /// only the shadow the model casts on it. Returns the rig's root node.
    ///
    /// The sun is aimed at the model's centre with a shadow frustum just
    /// larger than the model, so the whole of every shadow is crisp: a
    /// frustum left at the origin, or sized for a city block, gives soft,
    /// clipped or missing shadows.
    static func lightingRig(center: SIMD3<Float>, radius: Float, groundY: Float) -> SCNNode {
        let rig = SCNNode()
        rig.name = "lighting"
        let r = max(radius, 2)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1500
        sun.temperature = 5400
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowMapSize = CGSize(width: 4096, height: 4096)
        sun.shadowSampleCount = 16
        sun.shadowRadius = 2.5
        sun.shadowColor = UIColor(white: 0, alpha: 0.55)
        sun.automaticallyAdjustsShadowProjection = false
        sun.orthographicScale = Double(r * 1.15)
        sun.zNear = 0.1
        sun.zFar = CGFloat(r * 8)
        let sunNode = SCNNode()
        sunNode.light = sun
        // High in the south-west sky, so walls throw shadows across the rooms
        // without filling them.
        let toSun = simd_normalize(SIMD3<Float>(-0.5, 1.15, 0.42))
        sunNode.simdPosition = center + toSun * r * 4
        sunNode.simdLook(at: center)
        rig.addChildNode(sunNode)

        // Fill from the opposite side: shadowed faces read as shade, not soot.
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 280
        fill.temperature = 7200
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.simdPosition = center + simd_normalize(SIMD3<Float>(0.6, 0.7, -0.5)) * r * 4
        fillNode.simdLook(at: center)
        rig.addChildNode(fillNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 110
        ambient.color = UIColor(white: 1, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        rig.addChildNode(ambientNode)

        // An invisible ground that only darkens where the model shades it,
        // so the house sits on the page instead of hovering in front of it.
        let plane = SCNPlane(width: CGFloat(r * 12), height: CGFloat(r * 12))
        let catcher = SCNMaterial()
        catcher.lightingModel = .shadowOnly
        plane.materials = [catcher]
        let ground = SCNNode(geometry: plane)
        ground.name = "ground"
        ground.eulerAngles.x = -.pi / 2
        ground.simdPosition = SIMD3<Float>(center.x, groundY - 0.003, center.z)
        ground.castsShadow = false
        ground.categoryBitMask = SceneCategory.ground
        rig.addChildNode(ground)
        return rig
    }

    /// Image-based light: the sky every physically based surface reflects.
    /// An equirectangular image (2:1), bright overhead and at the horizon,
    /// warm grey below — enough for glass, metal and satin paint to read.
    static func applyEnvironment(to scene: SCNScene, background: UIColor) {
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 1.15
        scene.background.contents = background
    }

    static func background(dark: Bool) -> UIColor {
        dark ? UIColor(red: 0.105, green: 0.11, blue: 0.12, alpha: 1)
             : UIColor(red: 0.95, green: 0.95, blue: 0.94, alpha: 1)
    }

    /// HDR, ambient occlusion where things meet, a whisper of vignette.
    static func styleCamera(_ camera: SCNCamera, interior: Bool = false) {
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = interior ? 0.15 : -0.05
        camera.bloomIntensity = 0
        camera.screenSpaceAmbientOcclusionIntensity = interior ? 0.9 : 0.75
        camera.screenSpaceAmbientOcclusionRadius = interior ? 0.35 : 0.22
        camera.screenSpaceAmbientOcclusionBias = 0.02
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.2
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        camera.vignettingIntensity = interior ? 0.3 : 0.18
        camera.vignettingPower = 0.6
        camera.contrast = 0.05
        camera.saturation = 1.04
        camera.zNear = 0.03
        camera.zFar = 400
    }

    // MARK: - Procedural textures

    private static let textureSide: CGFloat = 1024

    /// Oak planks 15 cm wide (six to a 90 cm repeat), each a slightly
    /// different board, with staggered butt joints and fine grain.
    static let wood: UIImage = image { context, side in
        var random = SeededRandom(seed: 0xF100_0D)
        let rows = 6
        let plank = side / CGFloat(rows)
        for row in 0..<rows {
            let y = CGFloat(row) * plank
            // Boards along the row, with joints at varied points.
            var x: CGFloat = -side * CGFloat(random.next()) * 0.6
            while x < side {
                let length = side * CGFloat(0.45 + random.next() * 0.5)
                let tone = 0.9 + random.next() * 0.16
                let warm = 0.97 + random.next() * 0.05
                UIColor(red: 0.74 * tone, green: 0.56 * tone * warm, blue: 0.39 * tone, alpha: 1).setFill()
                fillWrapped(context, CGRect(x: x, y: y, width: length, height: plank), side: side)
                // Grain: long, faint, slightly wavy lines.
                for _ in 0..<7 {
                    let gy = y + plank * CGFloat(0.08 + random.next() * 0.84)
                    let alpha = 0.05 + random.next() * 0.09
                    UIColor(red: 0.35, green: 0.22, blue: 0.12, alpha: alpha).setFill()
                    fillWrapped(context, CGRect(x: x, y: gy, width: length, height: 1 + CGFloat(random.next()) * 1.5),
                                side: side)
                }
                // Butt joint.
                UIColor(red: 0.30, green: 0.20, blue: 0.12, alpha: 0.55).setFill()
                fillWrapped(context, CGRect(x: x + length - 1.5, y: y, width: 1.5, height: plank), side: side)
                x += length
            }
            // Long edge between rows: a fine dark line and a highlight.
            UIColor(red: 0.28, green: 0.18, blue: 0.10, alpha: 0.6).setFill()
            context.fill(CGRect(x: 0, y: y, width: side, height: 1.5))
            UIColor(white: 1, alpha: 0.12).setFill()
            context.fill(CGRect(x: 0, y: y + 1.5, width: side, height: 1))
        }
    }

    /// 30 cm porcelain tile with narrow grout, four to a 1.2 m repeat.
    static let tile: UIImage = image { context, side in
        var random = SeededRandom(seed: 0x711E)
        UIColor(red: 0.70, green: 0.69, blue: 0.67, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let count = 4
        let cell = side / CGFloat(count)
        let grout: CGFloat = 5
        for row in 0..<count {
            for column in 0..<count {
                let tone = 0.95 + random.next() * 0.05
                UIColor(red: 0.90 * tone, green: 0.895 * tone, blue: 0.88 * tone, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(column) * cell + grout / 2, y: CGFloat(row) * cell + grout / 2,
                                    width: cell - grout, height: cell - grout))
            }
        }
        speckle(context, side: side, count: 2500, alpha: 0.025, size: 2, random: &random)
    }

    /// Cut-pile carpet: an even tone with fibre speckle, 50 cm repeat.
    static let carpet: UIImage = image { context, side in
        var random = SeededRandom(seed: 0xCA4E7)
        UIColor(red: 0.80, green: 0.77, blue: 0.72, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        speckle(context, side: side, count: 26000, alpha: 0.07, size: 2.5, random: &random)
    }

    /// Sealed concrete: soft mottling and fine aggregate, 2 m repeat.
    static let concrete: UIImage = image { context, side in
        var random = SeededRandom(seed: 0xC0C0)
        UIColor(red: 0.64, green: 0.63, blue: 0.61, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        for _ in 0..<140 {
            let radius = CGFloat(40 + random.next() * 160)
            let x = CGFloat(random.next()) * side
            let y = CGFloat(random.next()) * side
            let dark = random.next() > 0.5
            (dark ? UIColor.black : UIColor.white).withAlphaComponent(0.025).setFill()
            for dx in [-side, 0, side] {
                for dy in [-side, 0, side] {
                    context.fillEllipse(in: CGRect(x: x - radius + dx, y: y - radius + dy,
                                                   width: radius * 2, height: radius * 2))
                }
            }
        }
        speckle(context, side: side, count: 9000, alpha: 0.06, size: 2, random: &random)
    }

    /// Large-format pavers (60 cm), two to a 1.2 m repeat.
    static let stone: UIImage = image { context, side in
        var random = SeededRandom(seed: 0x5701E)
        UIColor(red: 0.52, green: 0.50, blue: 0.47, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let cell = side / 2
        let joint: CGFloat = 8
        for row in 0..<2 {
            for column in 0..<2 {
                let tone = 0.92 + random.next() * 0.1
                UIColor(red: 0.70 * tone, green: 0.67 * tone, blue: 0.62 * tone, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(column) * cell + joint / 2, y: CGFloat(row) * cell + joint / 2,
                                    width: cell - joint, height: cell - joint))
            }
        }
        speckle(context, side: side, count: 12000, alpha: 0.05, size: 2.5, random: &random)
    }

    /// The sky for image-based light, equirectangular.
    static let environment: UIImage = {
        let size = CGSize(width: 1024, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [
                UIColor(red: 0.72, green: 0.80, blue: 0.92, alpha: 1).cgColor,   // zenith
                UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1).cgColor,
                UIColor(red: 1.00, green: 0.98, blue: 0.95, alpha: 1).cgColor,   // horizon
                UIColor(red: 0.62, green: 0.59, blue: 0.55, alpha: 1).cgColor,   // ground
                UIColor(red: 0.36, green: 0.34, blue: 0.32, alpha: 1).cgColor,   // nadir
            ] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                            locations: [0, 0.32, 0.5, 0.56, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height),
                                                 options: [])
        }
    }()

    private static func image(_ draw: (CGContext, CGFloat) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let side = textureSide
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            draw(context.cgContext, side)
        }
    }

    /// Fills a rectangle that may run off the right edge, wrapping it to the
    /// left so the texture tiles without a seam.
    private static func fillWrapped(_ context: CGContext, _ rect: CGRect, side: CGFloat) {
        context.fill(rect)
        if rect.maxX > side { context.fill(rect.offsetBy(dx: -side, dy: 0)) }
        if rect.minX < 0 { context.fill(rect.offsetBy(dx: side, dy: 0)) }
    }

    private static func speckle(_ context: CGContext, side: CGFloat, count: Int, alpha: Double,
                                size: CGFloat, random: inout SeededRandom) {
        for _ in 0..<count {
            let x = CGFloat(random.next()) * side
            let y = CGFloat(random.next()) * side
            let dark = random.next() > 0.5
            (dark ? UIColor.black : UIColor.white).withAlphaComponent(alpha * (0.5 + random.next())).setFill()
            context.fill(CGRect(x: x, y: y, width: size, height: size))
        }
    }

    /// A fixed sequence, so a texture is the same every launch and never
    /// shimmers between renders.
    struct SeededRandom {
        var seed: UInt64
        mutating func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % 10_000) / 10_000
        }
    }
}

/// What a tap or a light may touch.
enum SceneCategory {
    static let model = 1
    static let label = 2
    static let ground = 4
}
