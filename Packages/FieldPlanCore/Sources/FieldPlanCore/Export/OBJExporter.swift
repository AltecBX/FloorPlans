import Foundation

// MARK: - OBJ export (brief §19)
//
// A Wavefront OBJ of the canonical model, written from the same dollhouse
// geometry the 3D viewer draws (`DollhouseBuilder`) — mitred corners, door
// and window openings with their leaves, frames, glass and trim, floors by
// room — so the file matches the viewer and the plan to the millimetre and
// depends on no rendering framework. Metres, Y up; plan +y becomes −z.
// Materials are flat colours in a companion MTL; new and demolished work get
// their own tinted materials, as on the 2D plan.

public enum OBJExporter {

    public struct Options: Sendable {
        public var mode: PlanRenderMode = .existing
        public var includeFixtures = true
        public var includeFurniture = true
        /// Story spacing when a level has no scanned floor height; nil stacks
        /// each story on the walls below it, as the viewer does.
        public var levelSpacing: Double?
        public var materialFileName = "fieldplan.mtl"
        /// Floor slab thickness below the finished floor.
        public var slabThickness = 0.08
        public init() {}
    }

    public struct Output: Sendable {
        public var obj: String
        public var mtl: String
    }

    public static func export(levels: [LevelGeometry], options: Options = Options()) -> Output {
        var build = DollhouseBuilder.Options()
        build.mode = options.mode
        build.levelSpacing = options.levelSpacing
        build.slabThickness = options.slabThickness
        build.includeFixtures = options.includeFixtures
        build.includeFurniture = options.includeFurniture
        let model = DollhouseBuilder.build(levels: levels, options: build)

        var writer = Writer()
        writer.line("# Jerry FieldPlans model — metres, Y up, plan north is -Z")
        writer.line("mtllib \(options.materialFileName)")
        var used: [String: (DollhouseMaterial, DollhouseTint)] = [:]
        for level in model.levels {
            writer.line("g \(safe(level.name))")
            for element in level.elements where !element.mesh.isEmpty {
                writer.line("o \(element.kind.rawValue)_\(element.id.uuidString.prefix(8))")
                let offset = writer.vertices(element.mesh.positions)
                for sub in element.mesh.submeshes where !sub.indices.isEmpty {
                    let name = materialName(sub.material, element.tint)
                    used[name] = (sub.material, element.tint)
                    writer.material(name)
                    var i = 0
                    while i + 2 < sub.indices.count {
                        writer.face([offset + Int(sub.indices[i]),
                                     offset + Int(sub.indices[i + 1]),
                                     offset + Int(sub.indices[i + 2])])
                        i += 3
                    }
                }
            }
        }
        return Output(obj: writer.text, mtl: materials(used))
    }

    static func safe(_ name: String) -> String {
        let cleaned = name.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(cleaned).isEmpty ? "level" : String(cleaned)
    }

    static func materialName(_ material: DollhouseMaterial, _ tint: DollhouseTint) -> String {
        switch tint {
        case .none: return material.name
        case .new: return material.name + "_new"
        case .demolish: return material.name + "_demolished"
        }
    }

    /// Flat colours, close to the viewer's look.
    static func colour(_ material: DollhouseMaterial) -> (Double, Double, Double) {
        switch material {
        case .wall: return (0.92, 0.91, 0.88)
        case .wallCap: return (0.36, 0.37, 0.39)
        case .floor(.wood): return (0.72, 0.56, 0.40)
        case .floor(.tile): return (0.86, 0.86, 0.84)
        case .floor(.carpet): return (0.74, 0.71, 0.66)
        case .floor(.concrete): return (0.62, 0.62, 0.60)
        case .floor(.stone): return (0.66, 0.63, 0.58)
        case .threshold: return (0.62, 0.48, 0.34)
        case .baseboard, .trim, .windowFrame: return (0.96, 0.96, 0.94)
        case .ceiling: return (0.97, 0.97, 0.96)
        case .doorLeaf: return (0.93, 0.92, 0.89)
        case .hardware: return (0.55, 0.56, 0.58)
        case .glass: return (0.70, 0.83, 0.90)
        case .windowSill: return (0.90, 0.89, 0.86)
        case .fixture: return (0.85, 0.87, 0.90)
        case .furniture: return (0.70, 0.66, 0.60)
        }
    }

    static func materials(_ used: [String: (DollhouseMaterial, DollhouseTint)]) -> String {
        var text = "# Jerry FieldPlans materials\n"
        for name in used.keys.sorted() {
            guard let (material, tint) = used[name] else { continue }
            var (r, g, b) = colour(material)
            let target: (Double, Double, Double)?
            switch tint {
            case .none: target = nil
            case .new: target = (0.30, 0.52, 0.86)
            case .demolish: target = (0.85, 0.32, 0.30)
            }
            if let target {
                // Walls take the plan's colour outright; trim and the rest
                // lean toward it so the detail still reads.
                let t = material == .wall ? 1.0 : 0.65
                r += (target.0 - r) * t
                g += (target.1 - g) * t
                b += (target.2 - b) * t
            }
            let rgb = String(format: "%.2f %.2f %.2f", r, g, b)
            text += "newmtl \(name)\nKd \(rgb)\nKa \(rgb)\n"
            if material == .glass {
                text += "d 0.35\nTr 0.65\n"
            }
        }
        return text + "\n"
    }

    // MARK: Writer

    struct Writer {
        var text = ""
        var vertexCount = 0
        var currentMaterial = ""

        mutating func line(_ s: String) {
            text += s
            text += "\n"
        }

        mutating func material(_ name: String) {
            guard name != currentMaterial else { return }
            line("usemtl \(name)")
            currentMaterial = name
        }

        /// Writes the points and returns the 1-based index of the first.
        mutating func vertices(_ points: [Vec3]) -> Int {
            let first = vertexCount + 1
            for p in points {
                line(String(format: "v %.4f %.4f %.4f", p.x, p.y, p.z))
            }
            vertexCount += points.count
            return first
        }

        mutating func face(_ ids: [Int]) {
            line("f " + ids.map(String.init).joined(separator: " "))
        }
    }
}
