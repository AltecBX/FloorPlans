import Foundation

/// Renders a PlanScene to true vector SVG (spec §38). Geometry stays vector —
/// nothing is rasterized. Coordinates are scaled to pixels with Y flipped for
/// SVG's top-left origin.
public enum SVGExporter {

    public struct Options: Sendable {
        /// Pixels per meter.
        public var scale: Double = 100
        public var background: String? = "#FFFFFF"
        public var visibleLayers: Set<PlanLayerKind>? = nil
        public var title: String = ""

        public init() {}
    }

    public static func svg(for scene: PlanScene, options: Options = Options()) -> String {
        let s = options.scale
        let bounds = scene.bounds
        let width = bounds.width * s
        let height = bounds.height * s

        func X(_ p: Vec2) -> Double { (p.x - bounds.minX) * s }
        func Y(_ p: Vec2) -> Double { (bounds.maxY - p.y) * s }
        func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
        func pt(_ p: Vec2) -> String { "\(fmt(X(p))),\(fmt(Y(p)))" }

        var body = ""

        func styleAttrs(for pen: PlanPen) -> String {
            let style = penStyle(pen, scale: s)
            var attrs = "stroke=\"\(style.color)\" stroke-width=\"\(fmt(style.width))\" fill=\"none\""
            if let dash = style.dash {
                attrs += " stroke-dasharray=\"\(dash)\""
            }
            attrs += " stroke-linecap=\"round\" stroke-linejoin=\"round\""
            return attrs
        }

        func fillColor(_ fill: PlanFill) -> String? {
            switch fill {
            case .wallPoche: return "#1A1A1A"
            case .wallNewPoche: return "#8A8A8A"
            case .fixtureFill: return "#F2F2F2"
            case .none: return nil
            }
        }

        for layer in scene.layers {
            if let visible = options.visibleLayers, !visible.contains(layer.kind) { continue }
            body += "  <g id=\"\(layer.kind.rawValue)\">\n"
            for primitive in layer.primitives {
                switch primitive {
                case .line(let a, let b, let pen):
                    body += "    <line x1=\"\(fmt(X(a)))\" y1=\"\(fmt(Y(a)))\" x2=\"\(fmt(X(b)))\" y2=\"\(fmt(Y(b)))\" \(styleAttrs(for: pen))/>\n"
                case .polyline(let points, let closed, let pen):
                    guard points.count >= 2 else { continue }
                    let coords = points.map(pt).joined(separator: " ")
                    let tag = closed ? "polygon" : "polyline"
                    body += "    <\(tag) points=\"\(coords)\" \(styleAttrs(for: pen))/>\n"
                case .polygon(let points, let fill, let outline):
                    guard points.count >= 3 else { continue }
                    let coords = points.map(pt).joined(separator: " ")
                    let fillAttr = fillColor(fill) ?? "none"
                    if let outline {
                        let style = penStyle(outline, scale: s)
                        var attrs = "stroke=\"\(style.color)\" stroke-width=\"\(fmt(style.width))\""
                        if let dash = style.dash { attrs += " stroke-dasharray=\"\(dash)\"" }
                        body += "    <polygon points=\"\(coords)\" fill=\"\(fillAttr)\" \(attrs) stroke-linejoin=\"round\"/>\n"
                    } else {
                        body += "    <polygon points=\"\(coords)\" fill=\"\(fillAttr)\"/>\n"
                    }
                case .circle(let center, let radius, let pen, let filled):
                    let style = penStyle(pen, scale: s)
                    let fillAttr = filled ? style.color : "none"
                    body += "    <circle cx=\"\(fmt(X(center)))\" cy=\"\(fmt(Y(center)))\" r=\"\(fmt(radius * s))\" fill=\"\(fillAttr)\" stroke=\"\(style.color)\" stroke-width=\"\(fmt(style.width))\"/>\n"
                case .arc(let center, let radius, let startAngle, let endAngle, let pen):
                    // SVG arc path; note Y flip reverses sweep direction.
                    let a0 = startAngle
                    let a1 = endAngle
                    let p0 = center + Vec2(cos(a0), sin(a0)) * radius
                    let p1 = center + Vec2(cos(a1), sin(a1)) * radius
                    let largeArc = abs(a1 - a0) > .pi ? 1 : 0
                    // Counter-clockwise in plan space becomes sweep=0 after Y flip.
                    body += "    <path d=\"M \(fmt(X(p0))) \(fmt(Y(p0))) A \(fmt(radius * s)) \(fmt(radius * s)) 0 \(largeArc) 0 \(fmt(X(p1))) \(fmt(Y(p1)))\" \(styleAttrs(for: pen))/>\n"
                case .text(let string, let position, let heightM, let rotation, let anchor, let pen):
                    let style = penStyle(pen, scale: s)
                    let fontSize = heightM * s
                    let anchorAttr: String
                    let baseline: String
                    switch anchor {
                    case .center: anchorAttr = "middle"; baseline = "central"
                    case .bottomCenter: anchorAttr = "middle"; baseline = "auto"
                    case .topCenter: anchorAttr = "middle"; baseline = "hanging"
                    case .leftCenter: anchorAttr = "start"; baseline = "central"
                    }
                    let x = X(position)
                    let y = Y(position)
                    // Plan-space CCW rotation appears clockwise after Y flip.
                    let deg = -GeometryAngle.degrees(rotation)
                    let transform = abs(deg) > 0.01 ? " transform=\"rotate(\(fmt(deg)) \(fmt(x)) \(fmt(y)))\"" : ""
                    body += "    <text x=\"\(fmt(x))\" y=\"\(fmt(y))\" font-size=\"\(fmt(fontSize))\" font-family=\"Helvetica, Arial, sans-serif\" fill=\"\(style.color)\" text-anchor=\"\(anchorAttr)\" dominant-baseline=\"\(baseline)\"\(transform)>\(escapeXML(string))</text>\n"
                }
            }
            body += "  </g>\n"
        }

        var svg = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        svg += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(fmt(width))\" height=\"\(fmt(height))\" viewBox=\"0 0 \(fmt(width)) \(fmt(height))\">\n"
        if !options.title.isEmpty {
            svg += "  <title>\(escapeXML(options.title))</title>\n"
        }
        if let bg = options.background {
            svg += "  <rect x=\"0\" y=\"0\" width=\"\(fmt(width))\" height=\"\(fmt(height))\" fill=\"\(bg)\"/>\n"
        }
        svg += body
        svg += "</svg>\n"
        return svg
    }

    // MARK: - Styles

    struct PenStyle {
        var color: String
        var width: Double  // px
        var dash: String?  // SVG dash array
    }

    static func penStyle(_ pen: PlanPen, scale: Double) -> PenStyle {
        // Stroke widths tuned for 100 px/m; scale proportionally.
        let k = scale / 100
        switch pen {
        case .wallOutline: return PenStyle(color: "#1A1A1A", width: 2.2 * k, dash: nil)
        case .wallDemolished: return PenStyle(color: "#B3261E", width: 1.8 * k, dash: "\(8 * k),\(5 * k)")
        case .wallNew: return PenStyle(color: "#0B57D0", width: 2.6 * k, dash: nil)
        case .openingJamb: return PenStyle(color: "#1A1A1A", width: 1.6 * k, dash: nil)
        case .windowGlazing: return PenStyle(color: "#1A1A1A", width: 1.1 * k, dash: nil)
        case .doorLeaf: return PenStyle(color: "#1A1A1A", width: 1.4 * k, dash: nil)
        case .doorSwing: return PenStyle(color: "#6B6B6B", width: 0.8 * k, dash: "\(3 * k),\(3 * k)")
        case .openingHead: return PenStyle(color: "#6B6B6B", width: 1.0 * k, dash: "\(6 * k),\(4 * k)")
        case .fixture: return PenStyle(color: "#3C3C3C", width: 1.1 * k, dash: nil)
        case .furniture: return PenStyle(color: "#9A9A9A", width: 0.9 * k, dash: nil)
        case .dimension: return PenStyle(color: "#4A4A4A", width: 0.8 * k, dash: nil)
        case .text: return PenStyle(color: "#2A2A2A", width: 0.8 * k, dash: nil)
        case .roomLabel: return PenStyle(color: "#111111", width: 1.0 * k, dash: nil)
        case .areaLabel: return PenStyle(color: "#555555", width: 0.8 * k, dash: nil)
        case .annotation: return PenStyle(color: "#8A4B00", width: 0.9 * k, dash: nil)
        case .boundary: return PenStyle(color: "#7A7A7A", width: 1.2 * k, dash: "\(10 * k),\(6 * k)")
        case .symbol: return PenStyle(color: "#2A2A2A", width: 1.0 * k, dash: nil)
        }
    }

    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
