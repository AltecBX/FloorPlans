import Foundation

/// Standards-based ASCII DXF (R12 / AC1009) exporter for CAD interchange
/// (spec §37). R12 is deliberately chosen: it is the most widely imported
/// dialect (AutoCAD, DraftSight, LibreCAD, Revit link, Chief Architect).
///
/// Geometry is exported in INCHES (US CAD convention for architectural
/// plans), Y-up, matching the plan coordinate system directly.
public enum DXFExporter {

    /// DXF layer names (spec §37).
    public enum Layer: String, CaseIterable {
        case walls = "WALLS"
        case doors = "DOORS"
        case windows = "WINDOWS"
        case dimensions = "DIMENSIONS"
        case text = "TEXT"
        case fixtures = "FIXTURES"
        case demolition = "DEMOLITION"
        case newConstruction = "NEW_CONSTRUCTION"
        case symbols = "SYMBOLS"

        /// AutoCAD color index.
        var colorIndex: Int {
            switch self {
            case .walls: return 7        // white/black
            case .doors: return 3        // green
            case .windows: return 4      // cyan
            case .dimensions: return 8   // gray
            case .text: return 7
            case .fixtures: return 6     // magenta
            case .demolition: return 1   // red
            case .newConstruction: return 5 // blue
            case .symbols: return 7
            }
        }

        var lineType: String {
            self == .demolition ? "DASHED" : "CONTINUOUS"
        }
    }

    static let inchesPerMeter = 1.0 / UnitConstants.metersPerInch

    public static func dxf(for scene: PlanScene) -> String {
        var out = ""

        func tag(_ code: Int, _ value: String) {
            out += "\(code)\n\(value)\n"
        }
        func num(_ code: Int, _ value: Double) {
            tag(code, String(format: "%.4f", value))
        }

        let k = inchesPerMeter
        func X(_ p: Vec2) -> Double { (p.x - scene.bounds.minX) * k }
        func Y(_ p: Vec2) -> Double { (p.y - scene.bounds.minY) * k }

        // ---------- HEADER ----------
        tag(0, "SECTION")
        tag(2, "HEADER")
        tag(9, "$ACADVER")
        tag(1, "AC1009")
        tag(9, "$EXTMIN")
        num(10, 0)
        num(20, 0)
        tag(9, "$EXTMAX")
        num(10, scene.bounds.width * k)
        num(20, scene.bounds.height * k)
        tag(0, "ENDSEC")

        // ---------- TABLES ----------
        tag(0, "SECTION")
        tag(2, "TABLES")

        // Line types.
        tag(0, "TABLE")
        tag(2, "LTYPE")
        tag(70, "2")
        tag(0, "LTYPE")
        tag(2, "CONTINUOUS")
        tag(70, "0")
        tag(3, "Solid line")
        tag(72, "65")
        tag(73, "0")
        num(40, 0)
        tag(0, "LTYPE")
        tag(2, "DASHED")
        tag(70, "0")
        tag(3, "Dashed line")
        tag(72, "65")
        tag(73, "2")
        num(40, 9.0)
        num(49, 6.0)
        num(49, -3.0)
        tag(0, "ENDTAB")

        // Layers.
        tag(0, "TABLE")
        tag(2, "LAYER")
        tag(70, String(Layer.allCases.count))
        for layer in Layer.allCases {
            tag(0, "LAYER")
            tag(2, layer.rawValue)
            tag(70, "0")
            tag(62, String(layer.colorIndex))
            tag(6, layer.lineType)
        }
        tag(0, "ENDTAB")

        // Text style.
        tag(0, "TABLE")
        tag(2, "STYLE")
        tag(70, "1")
        tag(0, "STYLE")
        tag(2, "STANDARD")
        tag(70, "0")
        num(40, 0)
        num(41, 1)
        num(50, 0)
        tag(71, "0")
        num(42, 2.5)
        tag(3, "txt")
        tag(4, "")
        tag(0, "ENDTAB")

        tag(0, "ENDSEC")

        // ---------- ENTITIES ----------
        tag(0, "SECTION")
        tag(2, "ENTITIES")

        func emitLine(_ a: Vec2, _ b: Vec2, layer: Layer) {
            tag(0, "LINE")
            tag(8, layer.rawValue)
            num(10, X(a))
            num(20, Y(a))
            num(30, 0)
            num(11, X(b))
            num(21, Y(b))
            num(31, 0)
        }

        func emitPolyline(_ points: [Vec2], closed: Bool, layer: Layer) {
            guard points.count >= 2 else { return }
            tag(0, "POLYLINE")
            tag(8, layer.rawValue)
            tag(66, "1")
            tag(70, closed ? "1" : "0")
            num(10, 0)
            num(20, 0)
            num(30, 0)
            for p in points {
                tag(0, "VERTEX")
                tag(8, layer.rawValue)
                num(10, X(p))
                num(20, Y(p))
                num(30, 0)
            }
            tag(0, "SEQEND")
            tag(8, layer.rawValue)
        }

        func emitCircle(_ center: Vec2, _ radius: Double, layer: Layer) {
            tag(0, "CIRCLE")
            tag(8, layer.rawValue)
            num(10, X(center))
            num(20, Y(center))
            num(30, 0)
            num(40, radius * k)
        }

        func emitArc(_ center: Vec2, _ radius: Double, _ a0: Double, _ a1: Double, layer: Layer) {
            tag(0, "ARC")
            tag(8, layer.rawValue)
            num(10, X(center))
            num(20, Y(center))
            num(30, 0)
            num(40, radius * k)
            num(50, GeometryAngle.degrees(a0))
            num(51, GeometryAngle.degrees(a1))
        }

        func emitText(_ string: String, at position: Vec2, height: Double, rotation: Double,
                      anchor: TextAnchor, layer: Layer) {
            guard !string.isEmpty else { return }
            // R12 justification: 72 is horizontal (0 left, 1 center),
            // 73 vertical (0 baseline, 1 bottom, 2 middle, 3 top).
            let horizontal: String
            let vertical: String
            switch anchor {
            case .center: (horizontal, vertical) = ("1", "2")
            case .leftCenter: (horizontal, vertical) = ("0", "2")
            case .bottomCenter: (horizontal, vertical) = ("1", "1")
            case .topCenter: (horizontal, vertical) = ("1", "3")
            }
            tag(0, "TEXT")
            tag(8, layer.rawValue)
            num(10, X(position))
            num(20, Y(position))
            num(30, 0)
            num(40, height * k)
            tag(1, sanitizeText(string))
            num(50, GeometryAngle.degrees(rotation))
            tag(72, horizontal)
            num(11, X(position))
            num(21, Y(position))
            num(31, 0)
            tag(73, vertical)
        }

        for sceneLayer in scene.layers {
            // Room colour coding is presentation, not geometry: emitting it
            // would put a second outline on every room boundary in CAD.
            if sceneLayer.kind == .roomFills { continue }
            for primitive in sceneLayer.primitives {
                let layer = dxfLayer(for: primitive, in: sceneLayer.kind)
                switch primitive {
                case .line(let a, let b, _):
                    emitLine(a, b, layer: layer)
                case .polyline(let points, let closed, _):
                    emitPolyline(points, closed: closed, layer: layer)
                case .polygon(let points, _, _):
                    emitPolyline(points, closed: true, layer: layer)
                case .circle(let center, let radius, _, _):
                    emitCircle(center, radius, layer: layer)
                case .arc(let center, let radius, let a0, let a1, _):
                    emitArc(center, radius, a0, a1, layer: layer)
                case .text(let string, let position, let height, let rotation, let anchor, _):
                    emitText(string, at: position, height: height, rotation: rotation,
                             anchor: anchor, layer: .text)
                }
            }
        }

        tag(0, "ENDSEC")
        tag(0, "EOF")
        return out
    }

    /// Maps a scene layer + pen to the DXF layer.
    static func dxfLayer(for primitive: PlanPrimitive, in kind: PlanLayerKind) -> Layer {
        // Text always lands on TEXT.
        if case .text = primitive { return .text }

        let pen: PlanPen? = {
            switch primitive {
            case .line(_, _, let p): return p
            case .polyline(_, _, let p): return p
            case .polygon(_, _, let outline): return outline
            case .circle(_, _, let p, _): return p
            case .arc(_, _, _, _, let p): return p
            case .text: return nil
            }
        }()

        if pen == .wallDemolished { return .demolition }
        if pen == .wallNew { return .newConstruction }

        switch kind {
        case .walls: return .walls
        case .demolition: return .demolition
        case .newConstruction: return .newConstruction
        case .openings:
            if pen == .windowGlazing { return .windows }
            return .doors
        case .fixtures, .furniture: return .fixtures
        case .dimensions: return .dimensions
        case .labels, .annotations: return .text
        case .decor: return .symbols
        case .roomFills: return .walls
        }
    }

    /// Folds text to plain ASCII for DXF R12.
    ///
    /// R12 carries no encoding declaration, so CAD programs read the file as
    /// ASCII or the machine's ANSI code page: a UTF-8 "×" in a room label
    /// arrives as "Ã—" and an em dash as "â€”". Typographic characters are
    /// therefore replaced with their drafting equivalents, accents are folded,
    /// and anything left over becomes "?" rather than silently vanishing.
    static func sanitizeText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for character in s {
            switch character {
            case "\n", "\r", "\t": out.append(" ")
            case "×": out.append("x")
            case "·", "•": out.append("-")
            case "—", "–", "−": out.append("-")
            case "‘", "’", "′": out.append("'")
            case "“", "”", "″": out.append("\"")
            case "½": out.append("1/2")
            case "¼": out.append("1/4")
            case "¾": out.append("3/4")
            case "⅛": out.append("1/8")
            case "⅜": out.append("3/8")
            case "⅝": out.append("5/8")
            case "⅞": out.append("7/8")
            case "°": out.append(" deg")
            case "…": out.append("...")
            default:
                if character.isASCII {
                    out.append(character)
                } else {
                    let folded = String(character).folding(options: .diacriticInsensitive, locale: nil)
                    out.append(folded.allSatisfy(\.isASCII) ? folded : "?")
                }
            }
        }
        return out
    }
}
