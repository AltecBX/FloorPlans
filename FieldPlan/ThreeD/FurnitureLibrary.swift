import SceneKit
import UIKit
import FieldPlanCore

/// Loads real 3D furniture models and fits them to what was actually scanned.
///
/// RoomPlan reports each object as a labelled bounding box. The box is the
/// measurement and stays the truth; the model is how that measurement is
/// *drawn*. So a model is loaded for the object's category, normalised, and
/// scaled to the measured box — never the other way round.
///
/// Drop a file named after the category into `FieldPlan/Furniture/` and it is
/// used automatically; anything missing falls back to `FurnitureModels`, so the
/// library can be filled in one piece at a time and the app never regresses.
/// See `Docs/FURNITURE_MODELS.md` for the naming and orientation contract.
enum FurnitureLibrary {

    /// Extensions tried in order. SceneKit reads all of these through ModelIO,
    /// so a downloaded OBJ works without converting it to USDZ first.
    private static let extensions = ["usdz", "scn", "usdc", "dae", "obj"]

    /// Per-category corrections, for models that do not follow the contract.
    ///
    /// This exists because a model downloaded from anywhere may face a
    /// different way than the one next to it, and fixing that should be one
    /// number here rather than re-exporting the asset. `yaw` is in degrees,
    /// applied before fitting; `uniform` keeps a model's proportions instead of
    /// stretching it to fill the scanned box (right for fixtures whose shape is
    /// standardised, like a toilet).
    struct Adjustment {
        var yaw: Double = 0
        var uniform: Bool = false
    }

    static let adjustments: [FixtureCategory: Adjustment] = [
        .toilet: Adjustment(uniform: true),
        .sink: Adjustment(uniform: true),
        .vanity: Adjustment(uniform: true),
        .mirror: Adjustment(uniform: true),
        .television: Adjustment(uniform: true),
    ]

    /// Categories with a model present in the bundle. Shown in Settings so it
    /// is obvious which pieces are real models and which are still primitives.
    static var installedCategories: [FixtureCategory] {
        FixtureCategory.allCases.filter { url(for: $0) != nil }
    }

    /// A model fitted to `size` × `height`, or nil when none is installed.
    /// The returned node's origin is the footprint centre at floor level, so it
    /// drops straight into the same placement the primitives use.
    static func node(for category: FixtureCategory, size: Vec2, height: Double) -> SCNNode? {
        guard let template = template(for: category) else { return nil }

        let adjustment = adjustments[category] ?? Adjustment()
        let model = template.clone()

        // Correction yaw first, so the bounds we fit are the bounds as drawn.
        let yaw = adjustment.yaw * .pi / 180
        model.eulerAngles = SCNVector3(0, Float(yaw), 0)

        let (minBound, maxBound) = template.boundingBox
        var modelWidth = Double(maxBound.x - minBound.x)
        var modelDepth = Double(maxBound.z - minBound.z)
        let modelHeight = Double(maxBound.y - minBound.y)
        // A quarter turn swaps which model axis spans the scanned width.
        let quarterTurns = Int(((adjustment.yaw / 90).rounded())) % 4
        if abs(quarterTurns) % 2 == 1 { swap(&modelWidth, &modelDepth) }

        guard modelWidth > 0.001, modelDepth > 0.001, modelHeight > 0.001 else { return nil }

        var scaleX = max(size.x, 0.05) / modelWidth
        var scaleZ = max(size.y, 0.05) / modelDepth
        var scaleY = max(height, 0.05) / modelHeight

        if adjustment.uniform {
            // Fit inside the scanned box without distorting the shape.
            let uniform = min(scaleX, min(scaleY, scaleZ))
            scaleX = uniform; scaleY = uniform; scaleZ = uniform
        } else {
            // Stretch to the measurement, but never so far that a bad detection
            // produces a grotesque model.
            let mean = pow(scaleX * scaleY * scaleZ, 1.0 / 3.0)
            let limit = 1.6
            scaleX = min(max(scaleX, mean / limit), mean * limit)
            scaleY = min(max(scaleY, mean / limit), mean * limit)
            scaleZ = min(max(scaleZ, mean / limit), mean * limit)
        }

        let pivot = SCNNode()
        pivot.addChildNode(model)
        pivot.scale = SCNVector3(Float(scaleX), Float(scaleY), Float(scaleZ))
        // Centre the footprint on the origin and stand the model on the floor.
        let centreX = Double(minBound.x + maxBound.x) / 2
        let centreZ = Double(minBound.z + maxBound.z) / 2
        model.position = SCNVector3(Float(-centreX), Float(-Double(minBound.y)), Float(-centreZ))

        let root = SCNNode()
        root.addChildNode(pivot)
        return root
    }

    // MARK: - Loading

    private static var cache: [FixtureCategory: SCNNode] = [:]

    /// Loaded once per category and cloned per instance — a scan can contain a
    /// dozen chairs and reloading the file for each would stall the view.
    private static func template(for category: FixtureCategory) -> SCNNode? {
        if let cached = cache[category] { return cached }
        guard let url = url(for: category) else { return nil }
        guard let scene = try? SCNScene(url: url, options: nil) else {
            AppLog.scan.error("Furniture model at \(url.lastPathComponent, privacy: .public) could not be read")
            return nil
        }
        let container = SCNNode()
        for child in scene.rootNode.childNodes {
            container.addChildNode(child)
        }
        // Flattening merges the hierarchy into one geometry: the bounding box
        // then covers the whole model rather than just the root's own mesh,
        // and drawing is much cheaper when the piece repeats.
        let flattened = container.flattenedClone()
        cache[category] = flattened
        return flattened
    }

    private static func url(for category: FixtureCategory) -> URL? {
        for ext in extensions {
            if let url = Bundle.main.url(
                forResource: category.rawValue, withExtension: ext, subdirectory: "Furniture") {
                return url
            }
            // Xcode flattens some resource folders into the bundle root.
            if let url = Bundle.main.url(forResource: category.rawValue, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
