import SwiftUI
import UIKit
import FieldPlanCore

// MARK: - View transform

/// Maps plan coordinates (meters, +Y up) to view points with pan/zoom/rotate.
struct PlanViewTransform {
    /// Points per meter.
    var scale: CGFloat = 60
    /// View-space translation applied after scaling.
    var offset: CGPoint = .zero
    /// View rotation in radians (about the view center).
    var rotation: CGFloat = 0
    var viewCenter: CGPoint = .zero

    var transform: CGAffineTransform {
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: viewCenter.x, y: viewCenter.y)
        t = t.rotated(by: rotation)
        t = t.translatedBy(x: -viewCenter.x, y: -viewCenter.y)
        t = t.translatedBy(x: offset.x, y: offset.y)
        t = t.scaledBy(x: scale, y: -scale)
        return t
    }

    func toView(_ p: Vec2) -> CGPoint {
        CGPoint(x: p.x, y: p.y).applying(transform)
    }

    func toPlan(_ p: CGPoint) -> Vec2 {
        let inverted = p.applying(transform.inverted())
        return Vec2(Double(inverted.x), Double(inverted.y))
    }

    /// Screen angle (radians, clockwise-positive in view space) for a plan
    /// direction, accounting for the Y flip and view rotation.
    func viewAngle(forPlanAngle angle: Double) -> CGFloat {
        let a = toView(Vec2(0, 0))
        let b = toView(Vec2(cos(angle), sin(angle)))
        return atan2(b.y - a.y, b.x - a.x)
    }

    /// Fits the given plan bounds into a view size with padding.
    static func fitting(bounds: Rect2, in size: CGSize, padding: CGFloat = 24) -> PlanViewTransform {
        var t = PlanViewTransform()
        t.viewCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        guard !bounds.isNull, bounds.width > 0.01, bounds.height > 0.01,
              size.width > 2 * padding, size.height > 2 * padding else {
            t.offset = t.viewCenter
            return t
        }
        let sx = (size.width - 2 * padding) / CGFloat(bounds.width)
        let sy = (size.height - 2 * padding) / CGFloat(bounds.height)
        t.scale = min(sx, sy)
        // Center the bounds: offset such that bounds center maps to view center.
        let c = bounds.center
        t.offset = CGPoint(
            x: t.viewCenter.x - CGFloat(c.x) * t.scale,
            y: t.viewCenter.y + CGFloat(c.y) * t.scale)
        return t
    }
}

// MARK: - Pen styling

struct PlanPenStyle {
    var color: UIColor
    var width: CGFloat        // points, zoom-independent
    var dash: [CGFloat]?

    static func style(for pen: PlanPen, dark: Bool) -> PlanPenStyle {
        let ink: UIColor = dark ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.1, alpha: 1)
        let mid: UIColor = dark ? UIColor(white: 0.65, alpha: 1) : UIColor(white: 0.42, alpha: 1)
        switch pen {
        case .wallOutline: return .init(color: ink, width: 2.2, dash: nil)
        case .wallDemolished: return .init(color: .systemRed, width: 1.8, dash: [7, 4])
        case .wallNew: return .init(color: .systemBlue, width: 2.6, dash: nil)
        case .openingJamb: return .init(color: ink, width: 1.5, dash: nil)
        case .windowGlazing: return .init(color: ink, width: 1.0, dash: nil)
        case .doorLeaf: return .init(color: ink, width: 1.3, dash: nil)
        case .doorSwing: return .init(color: mid, width: 0.8, dash: [3, 3])
        case .openingHead: return .init(color: mid, width: 1.0, dash: [5, 4])
        case .fixture: return .init(color: dark ? UIColor(white: 0.8, alpha: 1) : UIColor(white: 0.25, alpha: 1), width: 1.1, dash: nil)
        case .furniture: return .init(color: mid.withAlphaComponent(0.7), width: 0.9, dash: nil)
        case .dimension: return .init(color: mid, width: 0.8, dash: nil)
        case .text: return .init(color: ink.withAlphaComponent(0.85), width: 0.8, dash: nil)
        case .roomLabel: return .init(color: ink, width: 1, dash: nil)
        case .areaLabel: return .init(color: mid, width: 0.8, dash: nil)
        case .annotation: return .init(color: .systemOrange, width: 1, dash: nil)
        case .boundary: return .init(color: mid, width: 1.2, dash: [8, 5])
        case .symbol: return .init(color: ink, width: 1, dash: nil)
        }
    }

    static func fillColor(for fill: PlanFill, dark: Bool) -> UIColor? {
        switch fill {
        case .wallPoche: return dark ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.13, alpha: 1)
        case .wallNewPoche: return UIColor.systemBlue.withAlphaComponent(0.55)
        case .fixtureFill: return dark ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 0, alpha: 0.045)
        case .roomTint(let type):
            let tint = type.planTint
            let color = UIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
            // On a dark sheet the same hues read as a wash over the background
            // rather than as paper colour.
            return dark ? color.withAlphaComponent(0.22) : color
        case .none: return nil
        }
    }
}

// MARK: - SwiftUI Canvas renderer

enum PlanSceneRenderer {

    /// Draws a scene into a SwiftUI Canvas graphics context.
    static func draw(
        _ scene: PlanScene,
        in context: GraphicsContext,
        transform: PlanViewTransform,
        visibleLayers: Set<PlanLayerKind>? = nil,
        dark: Bool,
        overlay: [PlanPrimitive] = []
    ) {
        for layer in scene.layers {
            if let visibleLayers, !visibleLayers.contains(layer.kind) { continue }
            for primitive in layer.primitives {
                drawPrimitive(primitive, in: context, transform: transform, dark: dark)
            }
        }
        for primitive in overlay {
            drawPrimitive(primitive, in: context, transform: transform, dark: dark, isOverlay: true)
        }
    }

    private static func drawPrimitive(
        _ primitive: PlanPrimitive,
        in context: GraphicsContext,
        transform: PlanViewTransform,
        dark: Bool,
        isOverlay: Bool = false
    ) {
        func stroked(_ path: Path, _ pen: PlanPen) {
            var style = PlanPenStyle.style(for: pen, dark: dark)
            if isOverlay {
                style.color = UIColor.systemBlue
                style.width += 1.5
            }
            let strokeStyle = StrokeStyle(
                lineWidth: style.width,
                lineCap: .round, lineJoin: .round,
                dash: style.dash ?? [])
            context.stroke(path, with: .color(Color(style.color)), style: strokeStyle)
        }

        switch primitive {
        case .line(let a, let b, let pen):
            var path = Path()
            path.move(to: transform.toView(a))
            path.addLine(to: transform.toView(b))
            stroked(path, pen)

        case .polyline(let points, let closed, let pen):
            guard points.count >= 2 else { return }
            var path = Path()
            path.move(to: transform.toView(points[0]))
            for p in points.dropFirst() { path.addLine(to: transform.toView(p)) }
            if closed { path.closeSubpath() }
            stroked(path, pen)

        case .polygon(let points, let fill, let outline):
            guard points.count >= 3 else { return }
            var path = Path()
            path.move(to: transform.toView(points[0]))
            for p in points.dropFirst() { path.addLine(to: transform.toView(p)) }
            path.closeSubpath()
            if let fillColor = PlanPenStyle.fillColor(for: fill, dark: dark) {
                context.fill(path, with: .color(Color(fillColor)))
            }
            if let outline {
                stroked(path, outline)
            }

        case .circle(let center, let radius, let pen, let filled):
            let path = circlePath(center: center, radius: radius, transform: transform)
            let style = PlanPenStyle.style(for: pen, dark: dark)
            if filled {
                context.fill(path, with: .color(Color(style.color)))
            }
            stroked(path, pen)

        case .arc(let center, let radius, let a0, let a1, let pen):
            var path = Path()
            let steps = 24
            for i in 0...steps {
                let angle = a0 + (a1 - a0) * Double(i) / Double(steps)
                let p = center + Vec2(cos(angle), sin(angle)) * radius
                let vp = transform.toView(p)
                if i == 0 { path.move(to: vp) } else { path.addLine(to: vp) }
            }
            stroked(path, pen)

        case .text(let string, let position, let height, let rotation, let anchor, let pen):
            guard !string.isEmpty else { return }
            let style = PlanPenStyle.style(for: pen, dark: dark)
            let fontSize = max(4, CGFloat(height) * transform.scale)
            guard fontSize < 400 else { return }
            let viewPoint = transform.toView(position)
            let screenAngle = transform.viewAngle(forPlanAngle: rotation)
            let weight: Font.Weight = pen == .roomLabel ? .semibold : .regular
            let text = Text(string)
                .font(.system(size: fontSize, weight: weight))
                .foregroundColor(Color(style.color))
            var ctx = context
            ctx.translateBy(x: viewPoint.x, y: viewPoint.y)
            ctx.rotate(by: Angle(radians: Double(screenAngle)))
            let unit: UnitPoint = {
                switch anchor {
                case .center: return .center
                case .bottomCenter: return .bottom
                case .topCenter: return .top
                case .leftCenter: return .leading
                }
            }()
            ctx.draw(text, at: .zero, anchor: unit)
        }
    }

    private static func circlePath(center: Vec2, radius: Double, transform: PlanViewTransform) -> Path {
        var path = Path()
        let steps = 32
        for i in 0...steps {
            let angle = 2 * Double.pi * Double(i) / Double(steps)
            let p = center + Vec2(cos(angle), sin(angle)) * radius
            let vp = transform.toView(p)
            if i == 0 { path.move(to: vp) } else { path.addLine(to: vp) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - CGContext renderer (PDF / PNG exports)

enum PlanImageRenderer {

    /// Renders the scene to a UIImage (always print style: dark on white).
    static func image(for scene: PlanScene, maxDimension: CGFloat = 2400, transparent: Bool = false) -> UIImage {
        let bounds = scene.bounds
        let aspect = bounds.isNull || bounds.height < 0.01
            ? 1 : CGFloat(bounds.width / bounds.height)
        let size: CGSize = aspect >= 1
            ? CGSize(width: maxDimension, height: maxDimension / aspect)
            : CGSize(width: maxDimension * aspect, height: maxDimension)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !transparent
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let cg = rendererContext.cgContext
            if !transparent {
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
            }
            draw(scene, in: cg, rect: CGRect(origin: .zero, size: size))
        }
    }

    /// Draws the scene into a CGContext rect (used by the PDF builder).
    /// UIKit coordinate space (origin top-left, +y down) is assumed.
    static func draw(_ scene: PlanScene, in cg: CGContext, rect: CGRect, visibleLayers: Set<PlanLayerKind>? = nil) {
        var transform = PlanViewTransform.fitting(
            bounds: scene.bounds,
            in: rect.size,
            padding: min(rect.width, rect.height) * 0.03)
        transform.offset.x += rect.minX
        transform.offset.y += rect.minY
        transform.viewCenter = CGPoint(x: rect.midX, y: rect.midY)

        for layer in scene.layers {
            if let visibleLayers, !visibleLayers.contains(layer.kind) { continue }
            for primitive in layer.primitives {
                drawPrimitive(primitive, cg: cg, transform: transform)
            }
        }
    }

    private static func drawPrimitive(_ primitive: PlanPrimitive, cg: CGContext, transform: PlanViewTransform) {
        func apply(_ pen: PlanPen) {
            let style = PlanPenStyle.style(for: pen, dark: false)
            cg.setStrokeColor(style.color.cgColor)
            cg.setLineWidth(style.width)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            if let dash = style.dash {
                cg.setLineDash(phase: 0, lengths: dash)
            } else {
                cg.setLineDash(phase: 0, lengths: [])
            }
        }

        func addPolyline(_ points: [Vec2], closed: Bool) {
            guard let first = points.first else { return }
            cg.beginPath()
            cg.move(to: transform.toView(first))
            for p in points.dropFirst() { cg.addLine(to: transform.toView(p)) }
            if closed { cg.closePath() }
        }

        switch primitive {
        case .line(let a, let b, let pen):
            apply(pen)
            cg.beginPath()
            cg.move(to: transform.toView(a))
            cg.addLine(to: transform.toView(b))
            cg.strokePath()

        case .polyline(let points, let closed, let pen):
            guard points.count >= 2 else { return }
            apply(pen)
            addPolyline(points, closed: closed)
            cg.strokePath()

        case .polygon(let points, let fill, let outline):
            guard points.count >= 3 else { return }
            if let fillColor = PlanPenStyle.fillColor(for: fill, dark: false) {
                cg.setFillColor(fillColor.cgColor)
                addPolyline(points, closed: true)
                cg.fillPath()
            }
            if let outline {
                apply(outline)
                addPolyline(points, closed: true)
                cg.strokePath()
            }

        case .circle(let center, let radius, let pen, let filled):
            let points = (0...32).map { i -> Vec2 in
                let angle = 2 * Double.pi * Double(i) / 32
                return center + Vec2(cos(angle), sin(angle)) * radius
            }
            let style = PlanPenStyle.style(for: pen, dark: false)
            if filled {
                cg.setFillColor(style.color.cgColor)
                addPolyline(points, closed: true)
                cg.fillPath()
            }
            apply(pen)
            addPolyline(points, closed: true)
            cg.strokePath()

        case .arc(let center, let radius, let a0, let a1, let pen):
            apply(pen)
            let points = (0...24).map { i -> Vec2 in
                let angle = a0 + (a1 - a0) * Double(i) / 24
                return center + Vec2(cos(angle), sin(angle)) * radius
            }
            addPolyline(points, closed: false)
            cg.strokePath()

        case .text(let string, let position, let height, let rotation, let anchor, let pen):
            guard !string.isEmpty else { return }
            let style = PlanPenStyle.style(for: pen, dark: false)
            let fontSize = max(2, CGFloat(height) * transform.scale)
            let font = UIFont.systemFont(ofSize: fontSize, weight: pen == .roomLabel ? .semibold : .regular)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: style.color,
            ]
            let attributed = NSAttributedString(string: string, attributes: attributes)
            let textSize = attributed.size()
            let viewPoint = transform.toView(position)
            let screenAngle = transform.viewAngle(forPlanAngle: rotation)

            cg.saveGState()
            cg.translateBy(x: viewPoint.x, y: viewPoint.y)
            cg.rotate(by: screenAngle)
            let origin: CGPoint
            switch anchor {
            case .center: origin = CGPoint(x: -textSize.width / 2, y: -textSize.height / 2)
            case .bottomCenter: origin = CGPoint(x: -textSize.width / 2, y: -textSize.height)
            case .topCenter: origin = CGPoint(x: -textSize.width / 2, y: 0)
            case .leftCenter: origin = CGPoint(x: 0, y: -textSize.height / 2)
            }
            UIGraphicsPushContext(cg)
            attributed.draw(at: origin)
            UIGraphicsPopContext()
            cg.restoreGState()
        }
    }
}

// MARK: - Hit testing

enum PlanHit: Equatable {
    case corner(wallID: UUID, isStart: Bool, position: Vec2)
    case opening(wallID: UUID, openingID: UUID)
    case wall(UUID)
    case fixture(UUID)
    case annotation(UUID)
    case room(UUID)
    case none
}

enum PlanHitTester {
    /// Finds what's under a plan-space point. `tolerance` in meters (derive
    /// from tap radius / current zoom so touch targets stay finger-sized).
    static func hit(_ point: Vec2, level: LevelGeometry, tolerance: Double) -> PlanHit {
        // Corners take priority (they're the hardest to grab).
        for wall in level.walls {
            if wall.start.distance(to: point) <= tolerance {
                return .corner(wallID: wall.id, isStart: true, position: wall.start)
            }
            if wall.end.distance(to: point) <= tolerance {
                return .corner(wallID: wall.id, isStart: false, position: wall.end)
            }
        }
        // Openings (measured along their wall).
        for wall in level.walls {
            let distance = GeometryOps.distanceToSegment(point, wall.start, wall.end)
            guard distance <= max(tolerance, wall.thickness / 2 + tolerance / 2) else { continue }
            let along = (point - wall.start).dot(wall.direction)
            for opening in wall.openings {
                if along >= opening.startOffset - tolerance / 2, along <= opening.endOffset + tolerance / 2 {
                    return .opening(wallID: wall.id, openingID: opening.id)
                }
            }
        }
        // Walls.
        var bestWall: (UUID, Double)? = nil
        for wall in level.walls {
            let distance = GeometryOps.distanceToSegment(point, wall.start, wall.end)
            let reach = max(tolerance, wall.thickness / 2 + tolerance / 2)
            if distance <= reach, distance < (bestWall?.1 ?? .greatestFiniteMagnitude) {
                bestWall = (wall.id, distance)
            }
        }
        if let bestWall { return .wall(bestWall.0) }
        // Fixtures.
        for fixture in level.fixtures {
            if GeometryOps.polygonContains(fixture.corners, point) {
                return .fixture(fixture.id)
            }
        }
        // Annotations.
        for annotation in level.annotations {
            if annotation.position.distance(to: point) <= tolerance * 1.5 {
                return .annotation(annotation.id)
            }
        }
        // Rooms.
        for room in level.rooms where room.polygon.count >= 3 {
            if GeometryOps.polygonContains(room.polygon, point) {
                return .room(room.id)
            }
        }
        return .none
    }
}
