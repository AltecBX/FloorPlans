import SceneKit
import UIKit
import FieldPlanCore

/// Recognisable 3D models for scanned fixtures and furniture.
///
/// RoomPlan reports each object as a bounding box, and a bounding box renders
/// like a stack of crates — which is what a dollhouse view built straight from
/// a scan looks like. Every category here is instead assembled from primitives
/// *inside* that measured box: the proportions stay exactly what was scanned,
/// but a bed reads as a bed and a toilet as a toilet.
///
/// This is deliberately parametric rather than a library of imported meshes —
/// no asset downloads, no licensing, nothing to keep in sync with a scan, and
/// it works for a 4-foot tub and an 6-foot tub alike.
enum FurnitureModels {

    // Presentation palette. Muted and warm, so the render reads as a staged
    // dollhouse rather than a CAD screenshot.
    private enum Palette {
        static let upholstery = UIColor(red: 0.78, green: 0.73, blue: 0.66, alpha: 1)
        static let cushion = UIColor(red: 0.84, green: 0.80, blue: 0.74, alpha: 1)
        static let wood = UIColor(red: 0.65, green: 0.51, blue: 0.38, alpha: 1)
        static let darkWood = UIColor(red: 0.45, green: 0.34, blue: 0.25, alpha: 1)
        static let linen = UIColor(white: 0.95, alpha: 1)
        static let porcelain = UIColor(white: 0.98, alpha: 1)
        static let cabinet = UIColor(white: 0.93, alpha: 1)
        static let counter = UIColor(white: 0.32, alpha: 1)
        static let appliance = UIColor(white: 0.80, alpha: 1)
        static let metal = UIColor(white: 0.72, alpha: 1)
        static let screen = UIColor(white: 0.12, alpha: 1)
        static let glass = UIColor(white: 0.85, alpha: 0.25)
    }

    /// Builds the model for `fixture` with its origin at the **floor centre** of
    /// the fixture's footprint: local +X is its width, +Y is up, +Z is its depth.
    /// `override` colours everything flat when the fixture is marked for demo or
    /// as new construction, so renovation states stay readable.
    static func node(for fixture: FixtureItem, height: Double, override: UIColor?) -> SCNNode {
        let width = max(fixture.size.x, 0.05)
        let depth = max(fixture.size.y, 0.05)
        let tall = max(height, 0.05)
        let root = SCNNode()

        func add(_ w: Double, _ h: Double, _ d: Double,
                 x: Double = 0, y: Double, z: Double = 0,
                 color: UIColor, chamfer: Double = 0.01) {
            let geometry = SCNBox(width: CGFloat(max(w, 0.005)),
                                  height: CGFloat(max(h, 0.005)),
                                  length: CGFloat(max(d, 0.005)),
                                  chamferRadius: CGFloat(chamfer))
            geometry.materials = [material(override ?? color)]
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(Float(x), Float(y), Float(z))
            root.addChildNode(node)
        }

        func addCylinder(radius: Double, height h: Double,
                         x: Double = 0, y: Double, z: Double = 0,
                         color: UIColor) {
            let geometry = SCNCylinder(radius: CGFloat(max(radius, 0.005)),
                                       height: CGFloat(max(h, 0.005)))
            geometry.materials = [material(override ?? color)]
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(Float(x), Float(y), Float(z))
            root.addChildNode(node)
        }

        switch fixture.category {
        case .bed:
            // Base, mattress, duvet fold and two pillows at the head (-Z).
            let baseHeight = tall * 0.42
            let mattress = tall * 0.45
            add(width, baseHeight, depth, y: baseHeight / 2, color: Palette.darkWood)
            add(width * 0.98, mattress, depth * 0.98,
                y: baseHeight + mattress / 2, color: Palette.linen, chamfer: 0.04)
            add(width * 0.98, tall * 0.10, depth * 0.55,
                z: depth * 0.20, y: baseHeight + mattress, color: Palette.cushion, chamfer: 0.03)
            let pillowWidth = width * 0.40
            for side in [-1.0, 1.0] {
                add(pillowWidth, tall * 0.13, depth * 0.16,
                    x: side * width * 0.24, y: baseHeight + mattress + tall * 0.05,
                    z: -depth * 0.36, color: Palette.linen, chamfer: 0.05)
            }

        case .sofa:
            // Seat, back along -Z, an arm at each end.
            let armWidth = width * 0.10
            let seatHeight = tall * 0.50
            add(width, seatHeight, depth, y: seatHeight / 2, color: Palette.upholstery)
            add(width - armWidth * 2, tall * 0.18, depth * 0.80,
                y: seatHeight + tall * 0.09, z: depth * 0.08,
                color: Palette.cushion, chamfer: 0.04)
            add(width, tall * 0.50, depth * 0.22,
                y: tall * 0.75, z: -depth * 0.39, color: Palette.upholstery, chamfer: 0.04)
            for side in [-1.0, 1.0] {
                add(armWidth, tall * 0.30, depth,
                    x: side * (width - armWidth) / 2, y: tall * 0.65,
                    color: Palette.upholstery, chamfer: 0.04)
            }

        case .chair:
            let seatHeight = tall * 0.55
            add(width, tall * 0.08, depth, y: seatHeight, color: Palette.upholstery, chamfer: 0.02)
            add(width, tall * 0.45, depth * 0.14,
                y: seatHeight + tall * 0.26, z: -depth * 0.43, color: Palette.upholstery)
            for (dx, dz) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                add(width * 0.07, seatHeight, depth * 0.07,
                    x: dx * width * 0.42, y: seatHeight / 2, z: dz * depth * 0.42,
                    color: Palette.darkWood, chamfer: 0)
            }

        case .table:
            add(width, tall * 0.07, depth, y: tall - tall * 0.035, color: Palette.wood, chamfer: 0.02)
            for (dx, dz) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                add(width * 0.06, tall * 0.93, depth * 0.06,
                    x: dx * width * 0.42, y: tall * 0.465, z: dz * depth * 0.42,
                    color: Palette.darkWood, chamfer: 0)
            }

        case .toilet:
            // Tank against the back (-Z), bowl in front, seat on top.
            add(width * 0.62, tall * 0.55, depth * 0.24,
                y: tall * 0.45, z: -depth * 0.36, color: Palette.porcelain, chamfer: 0.03)
            add(width * 0.52, tall * 0.42, depth * 0.62,
                y: tall * 0.21, z: depth * 0.10, color: Palette.porcelain, chamfer: 0.08)
            add(width * 0.56, tall * 0.06, depth * 0.58,
                y: tall * 0.45, z: depth * 0.10, color: Palette.linen, chamfer: 0.06)

        case .bathtub:
            // Apron and rim with a recessed basin: four walls plus a floor,
            // which reads as a tub from above without any CSG.
            let wall = min(width, depth) * 0.10
            add(width, tall, depth, y: tall / 2, color: Palette.porcelain, chamfer: 0.05)
            add(width - wall * 2, tall * 0.10, depth - wall * 2,
                y: tall * 0.30, color: UIColor(white: 0.90, alpha: 1), chamfer: 0.04)
            addCylinder(radius: min(width, depth) * 0.04, height: tall * 0.35,
                        y: tall + tall * 0.17, z: -depth * 0.40, color: Palette.metal)

        case .shower:
            let tray = tall * 0.06
            add(width, tray, depth, y: tray / 2, color: Palette.porcelain, chamfer: 0.02)
            add(width, tall - tray, depth * 0.04,
                y: tall / 2 + tray, z: depth * 0.48, color: Palette.glass, chamfer: 0)
            addCylinder(radius: min(width, depth) * 0.06, height: tall * 0.04,
                        y: tall * 0.92, z: -depth * 0.30, color: Palette.metal)

        case .sink, .vanity:
            // Cabinet, counter slab, basin sunk into it, tap at the back.
            let counter = 0.04
            add(width, tall - counter, depth, y: (tall - counter) / 2, color: Palette.cabinet)
            add(width, counter, depth, y: tall - counter / 2, color: Palette.counter, chamfer: 0.005)
            addCylinder(radius: min(width, depth) * 0.28, height: counter * 1.4,
                        y: tall, color: Palette.porcelain)
            addCylinder(radius: min(width, depth) * 0.035, height: 0.16,
                        y: tall + 0.08, z: -depth * 0.30, color: Palette.metal)

        case .cabinetBase, .island, .countertop:
            let counter = 0.04
            add(width, tall - counter, depth, y: (tall - counter) / 2, color: Palette.cabinet)
            add(width * 1.02, counter, depth * 1.04,
                y: tall - counter / 2, color: Palette.counter, chamfer: 0.005)
            // Door fronts: one per ~60 cm of run, the way cabinetry is made.
            let doors = max(1, Int((width / 0.6).rounded()))
            let doorWidth = width / Double(doors)
            for index in 0..<doors {
                let x = -width / 2 + doorWidth * (Double(index) + 0.5)
                add(doorWidth * 0.92, (tall - counter) * 0.88, 0.012,
                    x: x, y: (tall - counter) / 2, z: depth / 2,
                    color: UIColor(white: 0.88, alpha: 1), chamfer: 0.004)
            }

        case .refrigerator:
            add(width, tall, depth, y: tall / 2, color: Palette.appliance, chamfer: 0.02)
            // Freezer over fridge, with handles on the door faces.
            add(width * 0.98, 0.012, depth * 0.02,
                y: tall * 0.66, z: depth / 2, color: Palette.metal, chamfer: 0)
            for y in [tall * 0.50, tall * 0.78] {
                add(0.03, tall * 0.14, 0.03,
                    x: width * 0.36, y: y, z: depth / 2 + 0.02,
                    color: Palette.metal, chamfer: 0.01)
            }

        case .stove, .oven:
            add(width, tall, depth, y: tall / 2, color: Palette.appliance, chamfer: 0.02)
            add(width * 0.98, 0.02, depth * 0.98, y: tall, color: Palette.screen, chamfer: 0.005)
            for (dx, dz) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                addCylinder(radius: min(width, depth) * 0.11, height: 0.012,
                            x: dx * width * 0.22, y: tall + 0.012, z: dz * depth * 0.20,
                            color: Palette.metal)
            }
            add(width * 0.92, tall * 0.45, 0.015,
                y: tall * 0.32, z: depth / 2, color: Palette.screen, chamfer: 0.01)

        case .dishwasher, .washerDryer:
            add(width, tall, depth, y: tall / 2, color: Palette.appliance, chamfer: 0.02)
            addCylinder(radius: min(width, tall) * 0.28, height: 0.02,
                        y: tall * 0.55, z: depth / 2, color: Palette.metal)
            add(width * 0.9, 0.03, 0.03, y: tall * 0.9, z: depth / 2, color: Palette.metal)

        case .television:
            add(width, tall * 0.86, depth * 0.25, y: tall * 0.57, color: Palette.screen, chamfer: 0.01)
            add(width * 0.30, tall * 0.14, depth, y: tall * 0.07, color: Palette.darkWood)

        case .stairs:
            // Actual treads rather than a ramp — the shape a client recognises.
            let treads = max(3, Int((depth / 0.28).rounded()))
            let run = depth / Double(treads)
            let rise = max(tall, 0.18 * Double(treads)) / Double(treads)
            for index in 0..<treads {
                add(width, rise, run,
                    y: rise * (Double(index) + 0.5),
                    z: -depth / 2 + run * (Double(index) + 0.5),
                    color: Palette.wood, chamfer: 0.005)
            }

        case .storage, .cabinetUpper, .medicineCabinet:
            add(width, tall, depth, y: tall / 2, color: Palette.cabinet, chamfer: 0.01)
            let shelves = max(1, Int((tall / 0.35).rounded()) - 1)
            for index in 1...shelves {
                add(width * 0.94, 0.015, depth * 0.9,
                    y: tall * Double(index) / Double(shelves + 1),
                    color: UIColor(white: 0.86, alpha: 1), chamfer: 0)
            }

        case .radiator:
            add(width, tall, depth * 0.5, y: tall / 2, color: Palette.metal, chamfer: 0.01)
            let fins = max(3, Int((width / 0.08).rounded()))
            for index in 0..<fins {
                add(0.012, tall * 0.86, depth * 0.62,
                    x: -width / 2 + width * (Double(index) + 0.5) / Double(fins),
                    y: tall / 2, color: UIColor(white: 0.78, alpha: 1), chamfer: 0)
            }

        case .fireplace:
            add(width, tall, depth, y: tall / 2, color: UIColor(white: 0.88, alpha: 1), chamfer: 0.02)
            add(width * 0.6, tall * 0.5, 0.04,
                y: tall * 0.32, z: depth / 2, color: Palette.screen, chamfer: 0.01)
            add(width * 1.06, 0.05, depth * 1.1, y: tall, color: Palette.wood, chamfer: 0.01)

        default:
            // Columns, soffits, custom items: the measured box is the honest
            // shape, and inventing detail for an unknown object would be a lie.
            add(width, tall, depth, y: tall / 2,
                color: fixture.category.isFurniture ? Palette.upholstery : Palette.cabinet)
        }

        return root
    }

    private static func material(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.85
        material.metalness.contents = 0.0
        return material
    }
}
