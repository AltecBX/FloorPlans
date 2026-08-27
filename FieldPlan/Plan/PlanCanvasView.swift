import SwiftUI
import FieldPlanCore

/// Interactive plan canvas: pan, pinch zoom, two-finger rotate, tap and
/// drag callbacks in plan space. Shared by the viewer and the editor.
struct PlanCanvasView: View {
    let scene: PlanScene
    var visibleLayers: Set<PlanLayerKind>? = nil
    var overlay: [PlanPrimitive] = []
    /// Tap in plan coordinates (meters) + current tolerance in meters.
    var onTap: ((Vec2, Double) -> Void)? = nil
    /// Element drag support. Called with phase; return true to consume the
    /// gesture (element move) or false to let the canvas pan instead.
    var onDragStart: ((Vec2, Double) -> Bool)? = nil
    var onDragChanged: ((Vec2) -> Void)? = nil
    var onDragEnded: ((Vec2) -> Void)? = nil
    var showGrid = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var transform = PlanViewTransform()
    @State private var didFit = false
    @State private var baseScale: CGFloat? = nil
    @State private var baseRotation: CGFloat? = nil
    @State private var basePan: CGPoint? = nil
    @State private var dragConsumed: Bool? = nil

    /// Tap tolerance: 22 pt converted to meters at the current zoom.
    private var toleranceMeters: Double {
        Double(22 / max(transform.scale, 1))
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                if showGrid {
                    drawGrid(context: context, size: size)
                }
                PlanSceneRenderer.draw(
                    scene, in: context,
                    transform: transform,
                    visibleLayers: visibleLayers,
                    dark: colorScheme == .dark,
                    overlay: overlay)
            }
            .background(Color(colorScheme == .dark ? .black : .systemBackground))
            .contentShape(Rectangle())
            .gesture(combinedGesture)
            .onTapGesture { location in
                onTap?(transform.toPlan(location), toleranceMeters)
            }
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.25)) {
                    fit(size: geo.size)
                }
            }
            .onAppear {
                if !didFit {
                    fit(size: geo.size)
                    didFit = true
                }
            }
            .onChange(of: geo.size) { _, newSize in
                transform.viewCenter = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
            }
        }
        .clipped()
    }

    private func fit(size: CGSize) {
        transform = PlanViewTransform.fitting(bounds: scene.bounds, in: size)
    }

    // MARK: - Gestures

    private var combinedGesture: some Gesture {
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragConsumed == nil {
                    let planStart = transform.toPlan(value.startLocation)
                    dragConsumed = onDragStart?(planStart, toleranceMeters) ?? false
                }
                if dragConsumed == true {
                    onDragChanged?(transform.toPlan(value.location))
                } else {
                    if basePan == nil { basePan = transform.offset }
                    // Pan in view space, honoring the current rotation.
                    let t = value.translation
                    let r = -transform.rotation
                    let dx = t.width * cos(r) - t.height * sin(r)
                    let dy = t.width * sin(r) + t.height * cos(r)
                    transform.offset = CGPoint(
                        x: (basePan?.x ?? 0) + dx,
                        y: (basePan?.y ?? 0) + dy)
                }
            }
            .onEnded { value in
                if dragConsumed == true {
                    onDragEnded?(transform.toPlan(value.location))
                }
                dragConsumed = nil
                basePan = nil
            }

        let zoom = MagnifyGesture()
            .onChanged { value in
                if baseScale == nil { baseScale = transform.scale }
                let newScale = min(max((baseScale ?? 60) * value.magnification, 4), 2000)
                // Keep the view center fixed while zooming.
                let factor = newScale / transform.scale
                transform.offset = CGPoint(
                    x: transform.viewCenter.x + (transform.offset.x - transform.viewCenter.x) * factor,
                    y: transform.viewCenter.y + (transform.offset.y - transform.viewCenter.y) * factor)
                transform.scale = newScale
            }
            .onEnded { _ in baseScale = nil }

        let rotate = RotateGesture()
            .onChanged { value in
                if baseRotation == nil { baseRotation = transform.rotation }
                transform.rotation = (baseRotation ?? 0) + CGFloat(value.rotation.radians)
            }
            .onEnded { _ in baseRotation = nil }

        return drag.simultaneously(with: zoom).simultaneously(with: rotate)
    }

    // MARK: - Grid

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        // 1 ft grid, fading out when cells get tiny.
        let step = CGFloat(UnitConstants.metersPerFoot) * transform.scale
        guard step > 8 else { return }
        let color = Color(UIColor.systemGray.withAlphaComponent(step > 24 ? 0.22 : 0.12))

        // Grid is drawn in plan space between the visible plan corners; with
        // rotation active we simply cover the bounding plan region.
        let corners = [
            transform.toPlan(.zero),
            transform.toPlan(CGPoint(x: size.width, y: 0)),
            transform.toPlan(CGPoint(x: 0, y: size.height)),
            transform.toPlan(CGPoint(x: size.width, y: size.height)),
        ]
        let bounds = Rect2(containing: corners)
        let ft = UnitConstants.metersPerFoot
        let startX = (bounds.minX / ft).rounded(.down) * ft
        let startY = (bounds.minY / ft).rounded(.down) * ft
        var path = Path()
        var x = startX
        while x <= bounds.maxX {
            path.move(to: transform.toView(Vec2(x, bounds.minY)))
            path.addLine(to: transform.toView(Vec2(x, bounds.maxY)))
            x += ft
        }
        var y = startY
        while y <= bounds.maxY {
            path.move(to: transform.toView(Vec2(bounds.minX, y)))
            path.addLine(to: transform.toView(Vec2(bounds.maxX, y)))
            y += ft
        }
        context.stroke(path, with: .color(color), lineWidth: 0.5)
    }
}
