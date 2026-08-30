import Foundation

/// Generates the vector floor plan scene from canonical geometry (spec §14).
public enum PlanGenerator {

    public struct Options: Sendable {
        public var mode: PlanRenderMode = .existing
        /// Dimension chains. Off by default: a client sheet reads each room's
        /// size off its label, and the chains crowd small rooms. The plan editor
        /// and any drawing issued to a trade turn them on.
        public var showDimensions = false
        public var showRoomLabels = true
        /// "11' 5\" × 12' 0\"" under each room name (CubiCasa-style).
        public var showRoomDimensions = true
        /// Per-room area under the dimensions. Off by default: the totals
        /// belong in the title block, and a third line crowds a small room.
        public var showAreaLabels = false
        public var showFixtures = true
        public var showFurniture = false
        public var showAnnotations = true
        /// Room colour coding by type (bedrooms warm, wet rooms cool).
        public var showRoomColors = true
        /// Off by default: a client-facing sheet reads the room dimensions off
        /// the labels, and a graphic scale is meaningless once the sheet is
        /// resized. Turn it on for a drawing issued to a trade.
        public var showScaleBar = false
        public var showNorthArrow = false
        /// Sheet title block under the plan. Off by default: the on-screen plan
        /// and the PDF report carry their own headers, so only standalone
        /// exports (PNG/SVG/DXF) set one.
        public var titleBlock: PlanTitleBlock? = nil
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

    public static func scene(for rawLevel: LevelGeometry, options: Options = Options()) -> PlanScene {
        var layers: [PlanLayerKind: [PlanPrimitive]] = [:]
        func add(_ primitive: PlanPrimitive, to kind: PlanLayerKind) {
            layers[kind, default: []].append(primitive)
        }

        let mode = options.mode
        // Doors a scan could not read hinges for get their swing derived from
        // the rooms around them; a hand-set swing always wins.
        let level = DoorSwingInference.resolvingSwings(in: rawLevel)

        // ---- Room colour coding, under everything ----
        if options.showRoomColors {
            for room in level.rooms {
                guard includeElement(room.changeStatus, mode: mode) else { continue }
                guard room.polygon.count >= 3 else { continue }
                add(.polygon(points: room.polygon, fill: .roomTint(room.type), outline: nil),
                    to: .roomFills)
            }
        }

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

                // Fit the label to the room: shrink until it fits the room's
                // width with a visible margin from the walls, and never let a
                // small room carry a label sized for a large one — otherwise a
                // closet's name runs into its neighbour's and the two read as
                // one word. Secondary lines are dropped for rooms too small to
                // carry them.
                let bounds = room.bounds
                let maxWidth = max(bounds.width, 0.1) * 0.82
                var height = min(options.labelTextHeight, max(bounds.height, 0.1) * 0.20)
                if let fitting = PlanTextMetrics.heightToFit(name, maxWidth: maxWidth) {
                    height = min(height, fitting)
                }
                guard height >= 0.07 else { continue }

                // Secondary lines in priority order: dimensions, then area.
                // A line is only added when it also fits the room's width, so
                // labels never spill across walls into the next room.
                func fits(_ text: String, _ textHeight: Double) -> Bool {
                    PlanTextMetrics.width(text, height: textHeight) <= maxWidth
                }
                var lines: [(text: String, height: Double, pen: PlanPen)] = [
                    (name, height, .roomLabel)
                ]
                var budget = bounds.height / (height * 1.6) // rough line capacity
                if options.showRoomDimensions, height >= 0.10, budget > 2.5,
                   let extents = GeometryOps.orientedExtents(room.polygon) {
                    // "W × D" only describes a room honestly when the room fills
                    // its bounding box. For an L-shaped or irregular room the
                    // same numbers are overall extents — labelled so nobody
                    // multiplies them into an area the room does not have. If
                    // the honest version does not fit, no version is drawn.
                    let dims = "\(options.formatter.length(extents.width)) × \(options.formatter.length(extents.depth))"
                    let text = extents.fill >= 0.95 ? dims : dims + " overall"
                    let dimsHeight = height * 0.75
                    if fits(text, dimsHeight) {
                        lines.append((text, dimsHeight, .areaLabel))
                        budget -= 1
                    }
                }
                if options.showAreaLabels, height >= 0.11, budget > 2.5 {
                    let text = options.formatter.area(room.floorArea)
                    let areaHeight = height * 0.68
                    if fits(text, areaHeight) {
                        lines.append((text, areaHeight, .areaLabel))
                    }
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

        // ---- Title block (below the plan, never over it) ----
        if let block = options.titleBlock, !block.isEmpty {
            bounds = emitTitleBlock(block, planBounds: bounds) { add($0, to: .decor) }
        }

        let orderedKinds: [PlanLayerKind] = [
            .roomFills, .furniture, .fixtures, .walls, .demolition, .newConstruction,
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

    /// Rounded-rectangle outline in a fixture's local frame, as a polyline —
    /// enough segments to read as a curve at plan scale.
    static func roundedRectangle(
        halfWidth: Double, halfDepth: Double, radius: Double,
        local: (Double, Double) -> Vec2
    ) -> [Vec2] {
        let r = min(radius, min(halfWidth, halfDepth) * 0.95)
        let corners: [(Double, Double, Double)] = [
            (halfWidth - r, halfDepth - r, 0),           // +x +y
            (-halfWidth + r, halfDepth - r, .pi / 2),    // -x +y
            (-halfWidth + r, -halfDepth + r, .pi),       // -x -y
            (halfWidth - r, -halfDepth + r, 3 * .pi / 2), // +x -y
        ]
        var points: [Vec2] = []
        for (cx, cy, startAngle) in corners {
            for step in 0...4 {
                let angle = startAngle + (.pi / 2) * Double(step) / 4
                points.append(local(cx + r * cos(angle), cy + r * sin(angle)))
            }
        }
        return points
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

        // Fixture symbols follow the shapes a client recognises on a real estate
        // plan: a tub with its rolled rim and tap, a toilet as tank plus bowl,
        // a basin inside its counter. `local` places them in the fixture's own
        // frame, so every symbol rotates with the fixture.
        switch fixture.category {
        case .toilet:
            // Tank across the back, bowl in front of it.
            let tankDepth = d * 0.26
            emit(.polygon(points: [
                local(-w * 0.34, -d / 2 + 0.01), local(w * 0.34, -d / 2 + 0.01),
                local(w * 0.34, -d / 2 + tankDepth), local(-w * 0.34, -d / 2 + tankDepth),
            ], fill: .none, outline: pen))
            emit(.circle(center: local(0, d * 0.12), radius: min(w * 0.36, d * 0.30),
                         pen: pen, filled: false))
        case .sink, .vanity:
            // Basin inset in the counter, tap at the back.
            let basin = min(w, d) * 0.30
            emit(.circle(center: local(0, d * 0.04), radius: basin, pen: pen, filled: false))
            emit(.circle(center: local(0, -d * 0.30), radius: basin * 0.22, pen: pen, filled: true))
            emit(.line(a: local(-basin * 0.28, -d * 0.30), b: local(basin * 0.28, -d * 0.30), pen: pen))
        case .bathtub:
            // Rolled rim: an inner tub outline with rounded ends, plus the tap.
            emit(.polyline(points: roundedRectangle(
                halfWidth: w * 0.40, halfDepth: d * 0.38,
                radius: min(w, d) * 0.22, local: local), closed: true, pen: pen))
            emit(.circle(center: local(0, -d * 0.30), radius: min(w, d) * 0.06,
                         pen: pen, filled: false))
        case .shower:
            // Tray outline plus the drain and the diagonal that reads "shower".
            emit(.polygon(points: [
                local(-w * 0.40, -d * 0.40), local(w * 0.40, -d * 0.40),
                local(w * 0.40, d * 0.40), local(-w * 0.40, d * 0.40),
            ], fill: .none, outline: pen))
            emit(.line(a: local(-w * 0.40, -d * 0.40), b: local(w * 0.40, d * 0.40), pen: pen))
            emit(.circle(center: local(0, 0), radius: min(w, d) * 0.07, pen: pen, filled: false))
        case .stove:
            let bx = w * 0.22
            let by = d * 0.20
            for (sx, sy) in [(-bx, -by), (bx, -by), (-bx, by), (bx, by)] {
                emit(.circle(center: local(sx, sy), radius: min(w, d) * 0.10, pen: pen, filled: false))
            }
            // Control panel strip at the back.
            emit(.line(a: local(-w / 2, -d * 0.38), b: local(w / 2, -d * 0.38), pen: pen))
        case .bed:
            // Pillows across the head, coverlet fold across the foot.
            let pillowDepth = d * 0.18
            emit(.polygon(points: [
                local(-w * 0.42, -d * 0.44), local(w * 0.42, -d * 0.44),
                local(w * 0.42, -d * 0.44 + pillowDepth), local(-w * 0.42, -d * 0.44 + pillowDepth),
            ], fill: .none, outline: pen))
            emit(.line(a: local(0, -d * 0.44), b: local(0, -d * 0.44 + pillowDepth), pen: pen))
            emit(.line(a: local(-w / 2, d * 0.16), b: local(w / 2, d * 0.16), pen: pen))
        case .sofa:
            // Back cushion along one long edge, arms at each end.
            let back = d * 0.24
            emit(.line(a: local(-w / 2, -d / 2 + back), b: local(w / 2, -d / 2 + back), pen: pen))
            emit(.line(a: local(-w / 2 + w * 0.12, -d / 2 + back), b: local(-w / 2 + w * 0.12, d / 2), pen: pen))
            emit(.line(a: local(w / 2 - w * 0.12, -d / 2 + back), b: local(w / 2 - w * 0.12, d / 2), pen: pen))
        case .cabinetBase, .countertop, .island:
            // Counter edge line, the way cabinet runs are drawn.
            emit(.line(a: local(-w / 2, d * 0.34), b: local(w / 2, d * 0.34), pen: pen))
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
            var host: RoomShape? = nil
            if positiveRoom != nil && negativeRoom == nil {
                side = -1 // dimension on the exterior side
            } else if negativeRoom != nil && positiveRoom == nil {
                side = 1
            } else if let p = positiveRoom, let n = negativeRoom {
                // Interior partition: put the dimension in the LARGER room,
                // where it is least likely to collide with labels/fixtures.
                let inPositive = p.floorArea >= n.floorArea
                side = inPositive ? 1 : -1
                host = inPositive ? p : n
            } else {
                side = 1
            }

            // Even the larger of two small rooms cannot hold an interior
            // dimension clear of its own label: the line lands within a foot of
            // the wall, straight through the room name. Those walls are already
            // dimensioned on the exterior chains and in the room's W × D label.
            if let host, min(host.bounds.width, host.bounds.height) < 2.0 { continue }

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

    /// Draws the sheet title block in a strip below the plan and returns the
    /// bounds that now enclose both. Sizing is proportional to the plan so the
    /// block reads the same whether the sheet is a closet or a whole floor.
    static func emitTitleBlock(
        _ block: PlanTitleBlock,
        planBounds: Rect2,
        emit: (PlanPrimitive) -> Void
    ) -> Rect2 {
        let width = planBounds.width
        let textHeight = min(max(width * 0.020, 0.11), 0.34)
        let titleHeight = textHeight * 1.35
        let pad = textHeight * 1.1
        let spacing = 1.85

        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        if block.style == .centered {
            return emitCenteredTitleBlock(
                block, planBounds: planBounds,
                textHeight: textHeight, titleHeight: titleHeight,
                pad: pad, spacing: spacing, clean: clean, emit: emit)
        }

        // Left column reads as the sheet's identity, right column as its facts.
        typealias Row = (left: String, right: String, height: Double, leftPen: PlanPen, rightPen: PlanPen)
        var rows: [Row] = [
            (clean(block.projectName).uppercased(), clean(block.totalArea), titleHeight, .roomLabel, .roomLabel),
            (clean(block.address), clean(block.dateText), textHeight, .text, .text),
            (clean(block.planTitle), clean(block.preparedBy), textHeight, .text, .text),
            (clean(block.note), clean(block.contact), textHeight * 0.92, .annotation, .text),
        ]
        rows.removeAll { $0.left.isEmpty && $0.right.isEmpty }
        guard !rows.isEmpty else { return planBounds }

        let blockHeight = pad * 2 + rows.reduce(0.0) { $0 + $1.height * spacing }
        let top = planBounds.minY
        let bottom = top - blockHeight
        let dividerX = planBounds.minX + width * 0.62
        let leftColumn = dividerX - planBounds.minX - pad * 2
        let rightColumn = planBounds.maxX - dividerX - pad * 2

        emit(.polyline(points: [
            Vec2(planBounds.minX, bottom), Vec2(planBounds.maxX, bottom),
            Vec2(planBounds.maxX, top), Vec2(planBounds.minX, top),
        ], closed: true, pen: .symbol))
        emit(.line(a: Vec2(dividerX, bottom), b: Vec2(dividerX, top), pen: .symbol))

        // A long company or address line shrinks to its column rather than
        // running through the divider and out over the border.
        func fitted(_ text: String, _ height: Double, column: Double) -> Double {
            guard column > 0,
                  PlanTextMetrics.width(text, height: height) > column,
                  let fitting = PlanTextMetrics.heightToFit(text, maxWidth: column)
            else { return height }
            return max(fitting, height * 0.55)
        }

        var y = top - pad
        for row in rows {
            y -= row.height * spacing / 2
            if !row.left.isEmpty {
                emit(.text(string: row.left, position: Vec2(planBounds.minX + pad, y),
                           height: fitted(row.left, row.height, column: leftColumn),
                           rotation: 0, anchor: .leftCenter, pen: row.leftPen))
            }
            if !row.right.isEmpty {
                emit(.text(string: row.right, position: Vec2(dividerX + pad, y),
                           height: fitted(row.right, row.height, column: rightColumn),
                           rotation: 0, anchor: .leftCenter, pen: row.rightPen))
            }
            y -= row.height * spacing / 2
        }

        return Rect2(minX: planBounds.minX, minY: bottom,
                     maxX: planBounds.maxX, maxY: planBounds.maxY)
    }

    /// Centered, borderless block: who prepared the plan, then the area totals.
    /// The layout a client sees under a marketing floor plan.
    private static func emitCenteredTitleBlock(
        _ block: PlanTitleBlock,
        planBounds: Rect2,
        textHeight: Double,
        titleHeight: Double,
        pad: Double,
        spacing: Double,
        clean: (String) -> String,
        emit: (PlanPrimitive) -> Void
    ) -> Rect2 {
        var rows: [(text: String, height: Double, pen: PlanPen)] = []
        let heading = clean(block.preparedBy).isEmpty ? clean(block.projectName) : clean(block.preparedBy)
        if !heading.isEmpty { rows.append((heading, titleHeight, .roomLabel)) }
        for line in block.summaryLines where !clean(line).isEmpty {
            rows.append((clean(line), textHeight, .roomLabel))
        }
        let address = clean(block.address)
        if !address.isEmpty { rows.append((address, textHeight * 0.95, .text)) }
        let note = clean(block.note)
        if !note.isEmpty { rows.append((note, textHeight * 0.9, .annotation)) }
        guard !rows.isEmpty else { return planBounds }

        let blockHeight = pad + rows.reduce(0.0) { $0 + $1.height * spacing }
        let centerX = planBounds.center.x
        var y = planBounds.minY - pad
        for row in rows {
            y -= row.height * spacing / 2
            emit(.text(string: row.text, position: Vec2(centerX, y), height: row.height,
                       rotation: 0, anchor: .center, pen: row.pen))
            y -= row.height * spacing / 2
        }
        return Rect2(minX: planBounds.minX, minY: planBounds.minY - blockHeight,
                     maxX: planBounds.maxX, maxY: planBounds.maxY)
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
