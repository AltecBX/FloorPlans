import Foundation

/// Generates the vector floor plan scene from canonical geometry (spec §14).
public enum PlanGenerator {

    public struct Options: Sendable {
        public var mode: PlanRenderMode = .existing
        public var showDimensions = true
        public var showRoomLabels = true
        /// "11' 5\" × 12' 0\"" under each room name (CubiCasa-style).
        public var showRoomDimensions = true
        public var showAreaLabels = true
        public var showFixtures = true
        public var showFurniture = false
        public var showAnnotations = true
        public var showScaleBar = true
        public var showNorthArrow = true
        public var formatter = UnitFormatter()
        /// Dimension text height in plan meters.
        public var dimensionTextHeight = 0.16
        public var labelTextHeight = 0.24
        /// Offset of dimension lines from the wall face, meters.
        public var dimensionOffset = 0.55
        /// Skip dimensioning walls shorter than this.
        public var minimumDimensionedWallLength = 0.45

        public init() {}
    }

    // MARK: - Element inclusion by mode

    static func includeElement(_ status: ChangeStatus, mode: PlanRenderMode) -> Bool {
        switch mode {
        case .existing:
            return status != .new
        case .proposed:
            return status != .demolish
        case .demolition:
            return status != .new
        case .overlay:
            return true
        }
    }

    static func wallPen(for status: ChangeStatus, mode: PlanRenderMode) -> PlanPen {
        switch (status, mode) {
        case (.demolish, .demolition), (.demolish, .overlay):
            return .wallDemolished
        case (.demolish, _):
            return .wallOutline // in pure existing view a to-demolish wall is just existing
        case (.new, _):
            return .wallNew
        case (.existing, _):
            return .wallOutline
        }
    }

    static func wallFill(for status: ChangeStatus, mode: PlanRenderMode) -> PlanFill {
        switch (status, mode) {
        case (.demolish, .demolition), (.demolish, .overlay):
            return .none
        case (.new, _):
            return .wallNewPoche
        default:
            return .wallPoche
        }
    }

    static func layerKind(for status: ChangeStatus, mode: PlanRenderMode) -> PlanLayerKind {
        switch status {
        case .demolish where mode == .demolition || mode == .overlay:
            return .demolition
        case .new:
            return .newConstruction
        default:
            return .walls
        }
    }

    // MARK: - Scene generation

    public static func scene(for level: LevelGeometry, options: Options = Options()) -> PlanScene {
        var layers: [PlanLayerKind: [PlanPrimitive]] = [:]
        func add(_ primitive: PlanPrimitive, to kind: PlanLayerKind) {
            layers[kind, default: []].append(primitive)
        }

        let mode = options.mode

        // ---- Walls with openings ----
        for wall in level.walls {
            guard includeElement(wall.changeStatus, mode: mode) else { continue }
            guard wall.length > 0.02 else { continue }
            let pen = wallPen(for: wall.changeStatus, mode: mode)
            let fill = wallFill(for: wall.changeStatus, mode: mode)
            let kind = layerKind(for: wall.changeStatus, mode: mode)
            emitWall(wall, pen: pen, fill: fill, mode: mode) { add($0, to: kind == .walls ? primitiveLayer(for: $0, default: kind) : kind) }
        }

        // ---- Room boundaries for rooms without wall references ----
        for room in level.rooms {
            guard includeElement(room.changeStatus, mode: mode) else { continue }
            guard room.polygon.count >= 3 else { continue }
            if level.walls(for: room).isEmpty {
                add(.polyline(points: room.polygon, closed: true, pen: .boundary), to: .walls)
            }
        }

        // ---- Fixtures & furniture ----
        for fixture in level.fixtures {
            guard includeElement(fixture.changeStatus, mode: mode) else { continue }
            let isFurniture = fixture.category.isFurniture
            if isFurniture && !options.showFurniture { continue }
            if !isFurniture && !options.showFixtures { continue }
            let layer: PlanLayerKind = fixture.changeStatus == .new
                ? .newConstruction
                : (fixture.changeStatus == .demolish && (mode == .demolition || mode == .overlay)
                    ? .demolition
                    : (isFurniture ? .furniture : .fixtures))
            let pen: PlanPen = fixture.changeStatus == .demolish && (mode == .demolition || mode == .overlay)
                ? .wallDemolished
                : (isFurniture ? .furniture : .fixture)
            emitFixture(fixture, pen: pen) { add($0, to: layer) }
        }

        // ---- Dimensions ----
        if options.showDimensions {
            let dimmed = dimensionPrimitives(level: level, options: options)
            for p in dimmed { add(p, to: .dimensions) }
        }

        // ---- Room labels (name / W×D / area, CubiCasa-style) ----
        if options.showRoomLabels {
            for room in level.rooms {
                guard includeElement(room.changeStatus, mode: mode) else { continue }
                guard room.polygon.count >= 3 else { continue }
                let at = room.labelPoint
                let name = room.name.uppercased()

                // Fit the name to the room: shrink until the estimated text
                // width fits (~0.62 × height per glyph for the system font),
                // and drop secondary lines for rooms too small to carry them.
                let bounds = room.bounds
                let maxWidth = max(bounds.width, 0.1) * 0.9
                var height = options.labelTextHeight
                let estimated = Double(max(name.count, 1)) * height * 0.62
                if estimated > maxWidth {
                    height = maxWidth / (Double(max(name.count, 1)) * 0.62)
                }
                guard height >= 0.07 else { continue }

                // Secondary lines in priority order: dimensions, then area.
                var lines: [(text: String, height: Double, pen: PlanPen)] = [
                    (name, height, .roomLabel)
                ]
                var budget = bounds.height / (height * 1.6) // rough line capacity
                if options.showRoomDimensions, height >= 0.10, budget > 2.5,
                   let dims = GeometryOps.orientedDimensions(room.polygon) {
                    lines.append((
                        "\(options.formatter.length(dims.width)) × \(options.formatter.length(dims.depth))",
                        height * 0.75, .areaLabel))
                    budget -= 1
                }
                if options.showAreaLabels, height >= 0.11, budget > 2.5 {
                    lines.append((options.formatter.area(room.floorArea), height * 0.68, .areaLabel))
                }

                // Stack the block centered on the label point.
                let spacing = 1.45
                let totalHeight = lines.reduce(0.0) { $0 + $1.height * spacing }
                var y = at.y + totalHeight / 2
                for line in lines {
                    y -= line.height * spacing / 2
                    add(.text(
                        string: line.text,
                        position: Vec2(at.x, y),
                        height: line.height,
                        rotation: 0,
                        anchor: .center,
                        pen: line.pen
                    ), to: .labels)
                    y -= line.height * spacing / 2
                }
            }
        }

        // ---- Annotations ----
        if options.showAnnotations {
            for annotation in level.annotations {
                switch annotation.kind {
                case .note:
                    add(.circle(center: annotation.position, radius: 0.05, pen: .annotation, filled: true), to: .annotations)
                    add(.text(
                        string: annotation.text,
                        position: annotation.position + Vec2(0.12, 0.12),
                        height: options.dimensionTextHeight,
                        rotation: 0,
                        anchor: .leftCenter,
                        pen: .annotation
                    ), to: .annotations)
                case .dimension:
                    if let a = annotation.pointA, let b = annotation.pointB {
                        let text = annotation.text.isEmpty
                            ? options.formatter.length(a.distance(to: b))
                            : annotation.text
                        emitDimension(from: a, to: b, offset: annotation.offset, text: text,
                                      textHeight: options.dimensionTextHeight) { add($0, to: .annotations) }
                    }
                }
            }
        }

        // ---- Bounds ----
        var bounds = level.bounds
        if bounds.isNull { bounds = Rect2(minX: 0, minY: 0, maxX: 1, maxY: 1) }
        bounds = bounds.expanded(by: options.showDimensions ? options.dimensionOffset + 0.8 : 0.6)

        // ---- Scale bar & north arrow ----
        if options.showScaleBar {
            emitScaleBar(at: Vec2(bounds.minX + 0.3, bounds.minY + 0.25),
                         formatter: options.formatter,
                         textHeight: options.dimensionTextHeight) { add($0, to: .decor) }
        }
        if options.showNorthArrow, let north = level.northAngle {
            emitNorthArrow(at: Vec2(bounds.maxX - 0.6, bounds.maxY - 0.6), angle: north,
                           textHeight: options.dimensionTextHeight) { add($0, to: .decor) }
        }

        let orderedKinds: [PlanLayerKind] = [
            .furniture, .fixtures, .walls, .demolition, .newConstruction,
            .openings, .dimensions, .labels, .annotations, .decor,
        ]
        let planLayers = orderedKinds.compactMap { kind -> PlanLayer? in
            guard let prims = layers[kind], !prims.isEmpty else { return nil }
            return PlanLayer(kind: kind, primitives: prims)
        }
        return PlanScene(layers: planLayers, bounds: bounds, levelName: level.name)
    }

    /// Routes wall-body primitives to .walls and opening symbols to .openings.
    private static func primitiveLayer(for primitive: PlanPrimitive, default kind: PlanLayerKind) -> PlanLayerKind {
        switch primitive {
        case .arc, .circle:
            return .openings
        case .line(_, _, let pen):
            switch pen {
            case .doorLeaf, .doorSwing, .windowGlazing, .openingJamb, .openingHead:
                return .openings
            default:
                return kind
            }
        default:
            return kind
        }
    }

    // MARK: - Wall emission

    /// Draws one wall as a filled double-line body with gaps at openings,
    /// plus door/window/opening symbols.
    static func emitWall(
        _ wall: Wall,
        pen: PlanPen,
        fill: PlanFill,
        mode: PlanRenderMode,
        emit: (PlanPrimitive) -> Void
    ) {
        let dir = wall.direction
        let perp = dir.perpendicular
        let ht = wall.thickness / 2
        let len = wall.length

        // Openings visible in this mode, sorted, clamped inside the wall.
        let openings = wall.openings
            .filter { includeElement($0.changeStatus, mode: mode) }
            .map { o -> WallOpening in
                var c = o
                c.centerOffset = min(max(o.centerOffset, o.width / 2), max(o.width / 2, len - o.width / 2))
                return c
            }
            .sorted { $0.startOffset < $1.startOffset }

        // Solid wall segments between openings.
        var segments: [(Double, Double)] = []
        var cursor = 0.0
        for o in openings {
            let s = max(0, o.startOffset)
            let e = min(len, o.endOffset)
            if s > cursor + 0.005 { segments.append((cursor, s)) }
            cursor = max(cursor, e)
        }
        if cursor < len - 0.005 { segments.append((cursor, len)) }
        if segments.isEmpty && openings.isEmpty { segments = [(0, len)] }

        // Extend outermost segment ends by half thickness so corners close.
        for (i, seg) in segments.enumerated() {
            var s = seg.0
            var e = seg.1
            if i == 0 && s <= 0.005 { s -= ht }
            if i == segments.count - 1 && e >= len - 0.005 { e += ht }
            let p1 = wall.start + dir * s
            let p2 = wall.start + dir * e
            let corners = [p1 + perp * ht, p2 + perp * ht, p2 - perp * ht, p1 - perp * ht]
            emit(.polygon(points: corners, fill: fill, outline: pen))
        }

        // Opening symbols.
        for o in openings {
            let s = max(0, o.startOffset)
            let e = min(len, o.endOffset)
            let pStart = wall.start + dir * s
            let pEnd = wall.start + dir * e
            let openingPen: PlanPen = o.changeStatus == .demolish && (mode == .demolition || mode == .overlay)
                ? .wallDemolished
                : .openingJamb

            // Jamb lines across the wall thickness.
            emit(.line(a: pStart + perp * ht, b: pStart - perp * ht, pen: openingPen))
            emit(.line(a: pEnd + perp * ht, b: pEnd - perp * ht, pen: openingPen))

            switch o.kind {
            case .door:
                let swing = o.swing ?? DoorSwing()
                let hinge = swing.hingeAtStart ? pStart : pEnd
                let leafDir = swing.hingeAtStart ? dir : -dir
                let side = swing.opensPositiveSide ? perp : -perp
                let width = e - s
                let leafEnd = hinge + side * width
                let leafPen: PlanPen = o.changeStatus == .demolish && (mode == .demolition || mode == .overlay)
                    ? .wallDemolished : .doorLeaf
                emit(.line(a: hinge, b: leafEnd, pen: leafPen))
                // Swing arc from leaf tip to the opposite jamb.
                let a0 = (leafEnd - hinge).angle
                let a1 = (leafDir * width).angle
                let (startA, endA) = shortestArc(from: a0, to: a1)
                emit(.arc(center: hinge, radius: width, startAngle: startA, endAngle: endA,
                          pen: o.changeStatus == .demolish && (mode == .demolition || mode == .overlay) ? .wallDemolished : .doorSwing))
            case .window:
                let glazePen: PlanPen = o.changeStatus == .demolish && (mode == .demolition || mode == .overlay)
                    ? .wallDemolished : .windowGlazing
                emit(.line(a: pStart + perp * ht, b: pEnd + perp * ht, pen: glazePen))
                emit(.line(a: pStart, b: pEnd, pen: glazePen))
                emit(.line(a: pStart - perp * ht, b: pEnd - perp * ht, pen: glazePen))
            case .opening:
                emit(.line(a: pStart + perp * ht, b: pEnd + perp * ht, pen: .openingHead))
                emit(.line(a: pStart - perp * ht, b: pEnd - perp * ht, pen: .openingHead))
            }
        }
    }

    /// Returns (start, end) covering the quarter-swing from a0 to a1 going the
    /// short way, normalized so end > start for counter-clockwise arcs.
    static func shortestArc(from a0: Double, to a1: Double) -> (Double, Double) {
        var delta = GeometryAngle.normalize(a1 - a0)
        if delta >= 0 {
            return (a0, a0 + delta)
        } else {
            delta = -delta
            return (a1, a1 + delta)
        }
    }

    // MARK: - Fixture emission

    static func emitFixture(_ fixture: FixtureItem, pen: PlanPen, emit: (PlanPrimitive) -> Void) {
        let corners = fixture.corners
        emit(.polygon(points: corners, fill: .fixtureFill, outline: pen))

        let center = fixture.center
        let rot = fixture.rotation
        func local(_ x: Double, _ y: Double) -> Vec2 {
            Vec2(x, y).rotated(by: rot) + center
        }
        let w = fixture.size.x
        let d = fixture.size.y

        switch fixture.category {
        case .toilet:
            // Tank against the wall edge + bowl.
            emit(.circle(center: local(0, -d * 0.15), radius: min(w, d) * 0.28, pen: pen, filled: false))
        case .sink, .vanity:
            emit(.circle(center: local(0, 0), radius: min(w, d) * 0.3, pen: pen, filled: false))
        case .bathtub, .shower:
            let iw = w * 0.38
            let id2 = d * 0.38
            emit(.polygon(points: [
                local(-iw, -id2), local(iw, -id2), local(iw, id2), local(-iw, id2),
            ], fill: .none, outline: pen))
        case .stove:
            let bx = w * 0.24
            let by = d * 0.24
            for (sx, sy) in [(-bx, -by), (bx, -by), (-bx, by), (bx, by)] {
                emit(.circle(center: local(sx, sy), radius: min(w, d) * 0.11, pen: pen, filled: false))
            }
        case .stairs:
            // Tread lines across the depth.
            let treads = max(2, Int(d / 0.28))
            for i in 1..<treads {
                let y = -d / 2 + d * Double(i) / Double(treads)
                emit(.line(a: local(-w / 2, y), b: local(w / 2, y), pen: pen))
            }
            emit(.line(a: local(0, -d / 2), b: local(0, d / 2), pen: pen))
        case .column:
            emit(.polygon(points: corners, fill: .wallPoche, outline: pen))
        case .refrigerator:
            emit(.polygon(points: [
                local(-w * 0.35, -d * 0.35), local(w * 0.35, -d * 0.35),
                local(w * 0.35, d * 0.35), local(-w * 0.35, d * 0.35),
            ], fill: .none, outline: pen))
        default:
            break
        }
    }

    // MARK: - Dimensions

    static func dimensionPrimitives(level: LevelGeometry, options: Options) -> [PlanPrimitive] {
        var out: [PlanPrimitive] = []
        let mode = options.mode

        for wall in level.walls {
            guard includeElement(wall.changeStatus, mode: mode) else { continue }
            guard wall.length >= options.minimumDimensionedWallLength else { continue }

            // Choose the offset side: prefer the side NOT inside a room
            // (exterior), falling back to the positive perpendicular.
            let perp = wall.direction.perpendicular
            let probeDistance = wall.thickness / 2 + 0.25
            let positiveProbe = wall.midpoint + perp * probeDistance
            let negativeProbe = wall.midpoint - perp * probeDistance
            let positiveRoom = level.rooms.first { GeometryOps.polygonContains($0.polygon, positiveProbe) }
            let negativeRoom = level.rooms.first { GeometryOps.polygonContains($0.polygon, negativeProbe) }
            // Short interior partitions (rooms on both sides) add clutter and
            // collide with room labels; their lengths remain one tap away.
            let isInterior = positiveRoom != nil && negativeRoom != nil
            if isInterior && wall.length < 1.0 { continue }
            let side: Double
            if positiveRoom != nil && negativeRoom == nil {
                side = -1 // dimension on the exterior side
            } else if negativeRoom != nil && positiveRoom == nil {
                side = 1
            } else if let p = positiveRoom, let n = negativeRoom {
                // Interior partition: put the dimension in the LARGER room,
                // where it is least likely to collide with labels/fixtures.
                side = p.floorArea >= n.floorArea ? 1 : -1
            } else {
                side = 1
            }

            let offsetMagnitude = wall.thickness / 2
                + options.dimensionOffset * (isInterior ? 0.62 : 1.0)
            let offset = offsetMagnitude * side
            let a = wall.start + perp * offset
            let b = wall.end + perp * offset
            let text = options.formatter.length(wall.length)
            emitDimension(from: wall.start, to: wall.end,
                          lineA: a, lineB: b,
                          text: text, textHeight: options.dimensionTextHeight) { out.append($0) }
        }
        return out
    }

    /// Dimension with explicit measured points and dimension-line points.
    static func emitDimension(
        from measuredA: Vec2, to measuredB: Vec2,
        lineA: Vec2, lineB: Vec2,
        text: String, textHeight: Double,
        emit: (PlanPrimitive) -> Void
    ) {
        // Extension lines from measured points to slightly past the dim line.
        let extDir = (lineA - measuredA)
        let extLen = extDir.length
        let extUnit = extLen > 1e-9 ? extDir / extLen : Vec2(0, 1)
        emit(.line(a: measuredA + extUnit * min(0.08, extLen), b: lineA + extUnit * 0.08, pen: .dimension))
        emit(.line(a: measuredB + extUnit * min(0.08, extLen), b: lineB + extUnit * 0.08, pen: .dimension))
        emit(.line(a: lineA, b: lineB, pen: .dimension))

        // Architectural tick marks.
        let axis = (lineB - lineA).normalized
        let tick = (axis + extUnit).normalized * 0.09
        emit(.line(a: lineA - tick, b: lineA + tick, pen: .dimension))
        emit(.line(a: lineB - tick, b: lineB + tick, pen: .dimension))

        // Text above the line, kept readable (never upside down).
        var rotation = axis.angle
        if rotation > .pi / 2 + 1e-9 || rotation < -.pi / 2 + 1e-9 {
            rotation = GeometryAngle.normalize(rotation + .pi)
        }
        let mid = lineA.midpoint(lineB) + extUnit * (textHeight * 0.75)
        emit(.text(string: text, position: mid, height: textHeight,
                   rotation: rotation, anchor: .center, pen: .text))
    }

    /// Dimension between two points with a perpendicular offset.
    static func emitDimension(
        from a: Vec2, to b: Vec2, offset: Double,
        text: String, textHeight: Double,
        emit: (PlanPrimitive) -> Void
    ) {
        let perp = (b - a).normalized.perpendicular
        emitDimension(from: a, to: b, lineA: a + perp * offset, lineB: b + perp * offset,
                      text: text, textHeight: textHeight, emit: emit)
    }

    // MARK: - Decor

    static func emitScaleBar(
        at origin: Vec2,
        formatter: UnitFormatter,
        textHeight: Double,
        emit: (PlanPrimitive) -> Void
    ) {
        // 0–10 ft (imperial) or 0–3 m (metric) alternating bar.
        let imperial = formatter.system == .feetInches || formatter.system == .decimalFeet
        let unitLen = imperial ? UnitConstants.metersPerFoot : 1.0
        let segments = imperial ? 10 : 3
        let tickHeight = 0.1
        var x = origin
        for i in 0..<segments {
            let next = x + Vec2(unitLen, 0)
            emit(.line(a: x, b: next, pen: .symbol))
            if i % 2 == 0 {
                // Filled block for alternating segments.
                emit(.polygon(points: [
                    x, next, next + Vec2(0, tickHeight * 0.6), x + Vec2(0, tickHeight * 0.6),
                ], fill: .wallPoche, outline: nil))
            }
            x = next
        }
        emit(.line(a: origin, b: origin + Vec2(0, tickHeight), pen: .symbol))
        emit(.line(a: origin + Vec2(unitLen * Double(segments), 0),
                   b: origin + Vec2(unitLen * Double(segments), tickHeight), pen: .symbol))
        let label = imperial ? "0        5'        10'" : "0     1m     2m     3m"
        emit(.text(string: label,
                   position: origin + Vec2(unitLen * Double(segments) / 2, tickHeight + textHeight),
                   height: textHeight * 0.9, rotation: 0, anchor: .center, pen: .symbol))
    }

    static func emitNorthArrow(
        at center: Vec2, angle: Double, textHeight: Double,
        emit: (PlanPrimitive) -> Void
    ) {
        let radius = 0.35
        emit(.circle(center: center, radius: radius, pen: .symbol, filled: false))
        let tip = center + Vec2(0, radius * 0.8).rotated(by: angle)
        let baseL = center + Vec2(-radius * 0.25, -radius * 0.3).rotated(by: angle)
        let baseR = center + Vec2(radius * 0.25, -radius * 0.3).rotated(by: angle)
        emit(.polygon(points: [tip, baseL, baseR], fill: .wallPoche, outline: nil))
        emit(.text(string: "N", position: center + Vec2(0, radius + textHeight).rotated(by: angle),
                   height: textHeight, rotation: 0, anchor: .center, pen: .symbol))
    }
}
