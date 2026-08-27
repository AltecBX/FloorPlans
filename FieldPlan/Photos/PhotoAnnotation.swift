import SwiftUI
import UIKit
import FieldPlanCore

// MARK: - Annotation model
//
// Shapes are stored in normalized image coordinates (0…1) so annotations
// stay put at any display size. The original photo file is NEVER modified;
// annotations are a separate layer (flattened copies are generated only for
// reports/sharing).

struct PhotoAnnotationDocument: Codable {
    struct Shape: Codable, Identifiable {
        enum Kind: String, Codable {
            case arrow, circle, rectangle, freehand, text
        }

        var id: UUID = UUID()
        var kind: Kind
        /// Normalized points. arrow: [start, end]; circle/rect: [corner, corner];
        /// freehand: the path; text: [anchor].
        var points: [CGPoint]
        var text: String = ""
        var colorName: String = "red"

        var color: Color {
            switch colorName {
            case "yellow": return .yellow
            case "blue": return .blue
            case "green": return .green
            case "white": return .white
            default: return .red
            }
        }

        var uiColor: UIColor {
            switch colorName {
            case "yellow": return .systemYellow
            case "blue": return .systemBlue
            case "green": return .systemGreen
            case "white": return .white
            default: return .systemRed
            }
        }
    }

    var shapes: [Shape] = []

    static func decode(_ data: Data?) -> PhotoAnnotationDocument {
        guard let data else { return PhotoAnnotationDocument() }
        return (try? JSONDecoder().decode(PhotoAnnotationDocument.self, from: data)) ?? PhotoAnnotationDocument()
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

// MARK: - Shape drawing (shared by live view and flattening)

enum AnnotationDrawing {

    static func draw(_ document: PhotoAnnotationDocument, in context: GraphicsContext, size: CGSize) {
        for shape in document.shapes {
            draw(shape, in: context, size: size)
        }
    }

    static func draw(_ shape: PhotoAnnotationDocument.Shape, in context: GraphicsContext, size: CGSize) {
        let lineWidth = max(2.5, size.width / 220)
        func denorm(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        let color = shape.color

        switch shape.kind {
        case .arrow:
            guard shape.points.count >= 2 else { return }
            let a = denorm(shape.points[0])
            let b = denorm(shape.points[1])
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let headLength = max(14, size.width / 40)
            for side in [-1.0, 1.0] {
                let wing = angle + .pi + side * 0.45
                path.move(to: b)
                path.addLine(to: CGPoint(
                    x: b.x + cos(wing) * headLength,
                    y: b.y + sin(wing) * headLength))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

        case .circle:
            guard shape.points.count >= 2 else { return }
            let rect = CGRect(p1: denorm(shape.points[0]), p2: denorm(shape.points[1]))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: lineWidth)

        case .rectangle:
            guard shape.points.count >= 2 else { return }
            let rect = CGRect(p1: denorm(shape.points[0]), p2: denorm(shape.points[1]))
            context.stroke(Path(rect), with: .color(color), lineWidth: lineWidth)

        case .freehand:
            guard shape.points.count >= 2 else { return }
            var path = Path()
            path.move(to: denorm(shape.points[0]))
            for p in shape.points.dropFirst() {
                path.addLine(to: denorm(p))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

        case .text:
            guard let anchor = shape.points.first, !shape.text.isEmpty else { return }
            let fontSize = max(15, size.width / 26)
            let resolved = context.resolve(
                Text(shape.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(shape.colorName == "white" ? .black : .white))
            let textSize = resolved.measure(in: size)
            let position = denorm(anchor)
            let background = CGRect(
                x: position.x - 6, y: position.y - textSize.height / 2 - 4,
                width: textSize.width + 12, height: textSize.height + 8)
            context.fill(Path(roundedRect: background, cornerRadius: 6), with: .color(shape.color.opacity(0.9)))
            context.draw(resolved, at: CGPoint(x: position.x + textSize.width / 2, y: position.y), anchor: .center)
        }
    }

    /// Flattens the photo + annotations into a single image for reports.
    static func flatten(image: UIImage, document: PhotoAnnotationDocument) -> UIImage {
        guard !document.shapes.isEmpty else { return image }
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            let lineWidth = max(3, size.width / 220)
            func denorm(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * size.width, y: p.y * size.height)
            }
            for shape in document.shapes {
                cg.setStrokeColor(shape.uiColor.cgColor)
                cg.setLineWidth(lineWidth)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                switch shape.kind {
                case .arrow:
                    guard shape.points.count >= 2 else { continue }
                    let a = denorm(shape.points[0])
                    let b = denorm(shape.points[1])
                    cg.beginPath()
                    cg.move(to: a)
                    cg.addLine(to: b)
                    let angle = atan2(b.y - a.y, b.x - a.x)
                    let headLength = max(18, size.width / 40)
                    for side in [-1.0, 1.0] {
                        let wing = angle + .pi + side * 0.45
                        cg.move(to: b)
                        cg.addLine(to: CGPoint(x: b.x + cos(wing) * headLength, y: b.y + sin(wing) * headLength))
                    }
                    cg.strokePath()
                case .circle:
                    guard shape.points.count >= 2 else { continue }
                    cg.strokeEllipse(in: CGRect(p1: denorm(shape.points[0]), p2: denorm(shape.points[1])))
                case .rectangle:
                    guard shape.points.count >= 2 else { continue }
                    cg.stroke(CGRect(p1: denorm(shape.points[0]), p2: denorm(shape.points[1])))
                case .freehand:
                    guard shape.points.count >= 2 else { continue }
                    cg.beginPath()
                    cg.move(to: denorm(shape.points[0]))
                    for p in shape.points.dropFirst() { cg.addLine(to: denorm(p)) }
                    cg.strokePath()
                case .text:
                    guard let anchor = shape.points.first, !shape.text.isEmpty else { continue }
                    let fontSize = max(24, size.width / 26)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                        .foregroundColor: shape.colorName == "white" ? UIColor.black : UIColor.white,
                        .backgroundColor: shape.uiColor.withAlphaComponent(0.9),
                    ]
                    let attributed = NSAttributedString(string: " \(shape.text) ", attributes: attributes)
                    let textSize = attributed.size()
                    let position = denorm(anchor)
                    attributed.draw(at: CGPoint(x: position.x, y: position.y - textSize.height / 2))
                }
            }
        }
    }
}

private extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(
            x: min(p1.x, p2.x), y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }
}

// MARK: - Read-only annotated photo view

struct AnnotatedPhotoView: View {
    let image: UIImage
    let annotationData: Data?

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                Canvas { context, _ in
                    var ctx = context
                    ctx.translateBy(x: fitted.minX, y: fitted.minY)
                    AnnotationDrawing.draw(
                        PhotoAnnotationDocument.decode(annotationData),
                        in: ctx, size: fitted.size)
                }
            }
        }
        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
    }

    private func fittedRect(in container: CGSize) -> CGRect {
        let scale = min(container.width / image.size.width, container.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}

// MARK: - Annotation editor

/// Draw arrows, circles, rectangles, freehand and text over a photo
/// (spec §20). The base photo is untouched; shapes are a separate layer.
struct PhotoAnnotationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let existing: Data?
    let onSave: (Data?) -> Void

    enum Tool: String, CaseIterable {
        case arrow, circle, rectangle, freehand, text

        var icon: String {
            switch self {
            case .arrow: return "arrow.up.right"
            case .circle: return "circle"
            case .rectangle: return "rectangle"
            case .freehand: return "scribble"
            case .text: return "textformat"
            }
        }
    }

    @State private var document = PhotoAnnotationDocument()
    @State private var tool: Tool = .arrow
    @State private var colorName = "red"
    @State private var inProgress: PhotoAnnotationDocument.Shape? = nil
    @State private var textPrompt: CGPoint? = nil
    @State private var textDraft = ""

    private let colors = ["red", "yellow", "blue", "green", "white"]

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fitted = fittedRect(in: geo.size)
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                    Canvas { context, _ in
                        var ctx = context
                        ctx.translateBy(x: fitted.minX, y: fitted.minY)
                        AnnotationDrawing.draw(document, in: ctx, size: fitted.size)
                        if let inProgress {
                            AnnotationDrawing.draw(inProgress, in: ctx, size: fitted.size)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(drawGesture(fitted: fitted))
                }
            }
            .navigationTitle("Annotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(document.shapes.isEmpty ? nil : document.encoded())
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        ForEach(Tool.allCases, id: \.self) { t in
                            Button {
                                tool = t
                            } label: {
                                Image(systemName: t.icon)
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(tool == t ? Color.accentColor.opacity(0.3) : Color(.systemGray5)))
                            }
                            .accessibilityLabel(t.rawValue)
                        }
                        Divider().frame(height: 30)
                        ForEach(colors, id: \.self) { name in
                            Button {
                                colorName = name
                            } label: {
                                Circle()
                                    .fill(PhotoAnnotationDocument.Shape(kind: .arrow, points: [], colorName: name).color)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: colorName == name ? 2.5 : 0))
                            }
                            .accessibilityLabel("\(name) color")
                        }
                        Divider().frame(height: 30)
                        Button {
                            if !document.shapes.isEmpty {
                                document.shapes.removeLast()
                            }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Undo last shape")
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .alert("Add Text", isPresented: Binding(
                get: { textPrompt != nil },
                set: { if !$0 { textPrompt = nil } })) {
                TextField("Label", text: $textDraft)
                Button("Add") {
                    if let anchor = textPrompt, !textDraft.isEmpty {
                        document.shapes.append(.init(
                            kind: .text, points: [anchor], text: textDraft, colorName: colorName))
                    }
                    textDraft = ""
                    textPrompt = nil
                }
                Button("Cancel", role: .cancel) {
                    textDraft = ""
                    textPrompt = nil
                }
            }
            .onAppear {
                document = PhotoAnnotationDocument.decode(existing)
            }
        }
    }

    private func fittedRect(in container: CGSize) -> CGRect {
        let scale = min(container.width / image.size.width, container.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width, height: size.height)
    }

    private func drawGesture(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = normalize(value.startLocation, fitted: fitted)
                let current = normalize(value.location, fitted: fitted)
                switch tool {
                case .text:
                    break // handled on end
                case .freehand:
                    if inProgress == nil {
                        inProgress = .init(kind: .freehand, points: [start], colorName: colorName)
                    }
                    inProgress?.points.append(current)
                case .arrow:
                    inProgress = .init(kind: .arrow, points: [start, current], colorName: colorName)
                case .circle:
                    inProgress = .init(kind: .circle, points: [start, current], colorName: colorName)
                case .rectangle:
                    inProgress = .init(kind: .rectangle, points: [start, current], colorName: colorName)
                }
            }
            .onEnded { value in
                let start = normalize(value.startLocation, fitted: fitted)
                let end = normalize(value.location, fitted: fitted)
                switch tool {
                case .text:
                    textPrompt = end
                default:
                    if var shape = inProgress {
                        // Ignore accidental micro-drags.
                        if shape.kind != .freehand {
                            shape.points = [start, end]
                            let dx = abs(end.x - start.x)
                            let dy = abs(end.y - start.y)
                            if dx > 0.01 || dy > 0.01 {
                                document.shapes.append(shape)
                            }
                        } else if shape.points.count > 3 {
                            document.shapes.append(shape)
                        }
                    }
                }
                inProgress = nil
            }
    }

    private func normalize(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - fitted.minX) / max(fitted.width, 1), 0), 1),
            y: min(max((point.y - fitted.minY) / max(fitted.height, 1), 0), 1))
    }
}
