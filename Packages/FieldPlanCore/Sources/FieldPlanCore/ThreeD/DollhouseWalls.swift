import Foundation

// MARK: - Wall solids
//
// Each wall is its joint-resolved footprint (see WallJoints) cut into
// intervals along its length at every opening. An interval is drawn as one
// or more horizontal layers ("spans"): a plain run is floor-slab to top; a
// door is a saddle and a header; a window a sill block and a header. Faces
// are only drawn where they can be seen — the side of a span shows where the
// interval next to it is open (that is a jamb, a reveal), and a wall's end
// shows only above the neighbour that hides it — so nothing in the model is
// drawn twice and nothing flickers.

/// A wall's own frame: `u` along it, `n` to its left, measured from its start.
struct WallFrame {
    let origin: Vec2
    let u: Vec2
    let n: Vec2
    let half: Double
    let length: Double

    init(_ wall: Wall) {
        origin = wall.start
        u = wall.direction
        n = wall.direction.perpendicular
        half = max(wall.thickness, 0.02) / 2
        length = wall.length
    }

    /// Distance along the wall from its start.
    func s(_ p: Vec2) -> Double { (p - origin).dot(u) }
    /// Distance to the left of the centreline.
    func offset(_ p: Vec2) -> Double { (p - origin).dot(n) }
    func point(_ s: Double, _ offset: Double) -> Vec2 { origin + u * s + n * offset }
}

/// One opening as it is cut into its wall.
struct PlacedOpening {
    var opening: WallOpening
    /// Along the wall, clamped to where both faces run straight.
    var s0: Double
    var s1: Double
    /// Top of the solid below the opening (saddle, floor or sill), above the
    /// finished floor.
    var lower: Double
    /// Underside of the header; the wall's (cut) top when there is none.
    var head: Double
    /// False when a cut hides the head, so no head rail or casing is drawn.
    var hasHead: Bool
    var lowerMaterial: DollhouseMaterial
    var soffitMaterial: DollhouseMaterial

    var width: Double { s1 - s0 }
    /// A door, a cased opening or a window down to the floor: the baseboard
    /// stops at its casing.
    var reachesFloor: Bool { lower < 0.1 }
}

/// What an edge of a clipped wall footprint is.
enum FootprintEdge: Equatable {
    /// A wall face.
    case side
    /// Across an end, hidden up to the neighbour's height.
    case end(WallEnd.EndFace)
    /// The boundary between interval `index` and `index + 1`.
    case cut(Int)
}

struct LabelledPolygon {
    var points: [Vec2] = []
    /// `roles[i]` describes the edge from `points[i]` to the next point.
    var roles: [FootprintEdge] = []

    mutating func append(_ p: Vec2, _ role: FootprintEdge) {
        points.append(p)
        roles.append(role)
    }

    /// Keeps the part where `inside(p) ≥ 0` (a half-plane), labelling the new
    /// edge along the clip line `cut`. Sutherland–Hodgman; the footprint is
    /// only ever clipped where it is a straight strip, so it stays simple.
    func clipped(_ inside: (Vec2) -> Double, cut: FootprintEdge) -> LabelledPolygon {
        var out = LabelledPolygon()
        let count = points.count
        for i in 0..<count {
            let p = points[i]
            let q = points[(i + 1) % count]
            let fp = inside(p)
            let fq = inside(q)
            if fp >= 0 {
                out.append(p, roles[i])
                if fq < 0 {
                    out.append(p + (q - p) * (fp / (fp - fq)), cut)
                }
            } else if fq >= 0 {
                out.append(p + (q - p) * (fp / (fp - fq)), roles[i])
            }
        }
        return out.deduplicated()
    }

    /// Drops zero-length edges.
    func deduplicated() -> LabelledPolygon {
        guard points.count > 1 else { return self }
        var out = LabelledPolygon()
        for i in points.indices {
            let next = points[(i + 1) % points.count]
            if points[i].distance(to: next) > 1e-9 {
                out.append(points[i], roles[i])
            }
        }
        return out
    }
}

/// Everything about one level that walls need to know about each other.
struct WallContext {
    let walls: [Wall]
    let rooms: [RoomShape]
    let base: Double
    let options: DollhouseBuilder.Options
    let frames: [WallFrame]
    let joints: [WallJointSet]
    /// Joints for the baseboard's front line, a board's depth off each face.
    let trimJoints: [WallJointSet]
    /// The room on each side of each wall (left, right), if any.
    let sideRooms: [(left: RoomShape?, right: RoomShape?)]

    init(walls: [Wall], rooms: [RoomShape], base: Double, options: DollhouseBuilder.Options) {
        self.walls = walls
        self.rooms = rooms
        self.base = base
        self.options = options
        let frames = walls.map(WallFrame.init)
        self.frames = frames
        joints = WallJoints.resolve(walls)
        trimJoints = WallJoints.resolve(walls) {
            max($0.thickness, 0.02) / 2 + DollhouseBuilder.baseboardDepth
        }
        sideRooms = frames.map { frame in
            func room(_ side: Double) -> RoomShape? {
                for t in [0.5, 0.25, 0.75] {
                    let p = frame.point(frame.length * t, side * (frame.half + 0.12))
                    if let room = rooms.first(where: { GeometryOps.polygonContains($0.polygon, p) }) {
                        return room
                    }
                }
                return nil
            }
            return (room(1), room(-1))
        }
    }

    /// A wall's drawn top above its floor: its height, or the cut.
    func top(of index: Int) -> Double {
        let height = max(walls[index].height, 0.05)
        guard let cut = options.cutHeight else { return height }
        return max(min(height, cut), 0.05)
    }

    func ceilingFallback(for room: RoomShape) -> Double {
        let ids = Set(room.wallIDs)
        let own = walls.filter { ids.contains($0.id) }.map(\.height)
        return own.max() ?? walls.map(\.height).max() ?? 2.44
    }

    func room(onSide side: Double, of index: Int) -> RoomShape? {
        side > 0 ? sideRooms[index].left : sideRooms[index].right
    }

    /// The side (+1 left, −1 right) with a room on it when the other has
    /// none — that other side is outdoors. Nil for interior walls.
    func exteriorSide(of index: Int) -> Double? {
        switch (sideRooms[index].left != nil, sideRooms[index].right != nil) {
        case (true, false): return -1
        case (false, true): return 1
        default: return nil
        }
    }

    /// The stretch along the wall where the face on `side` runs.
    func faceRange(of index: Int, side: Double) -> (lo: Double, hi: Double) {
        let f = frames[index]
        let j = joints[index]
        return side > 0
            ? (f.s(j.start.left), f.s(j.end.left))
            : (f.s(j.start.right), f.s(j.end.right))
    }

    // MARK: Building one wall

    struct Built {
        var wall: DollhouseModel.Element
        var openings: [DollhouseModel.Element]
    }

    func build(wall index: Int) -> Built {
        let wall = walls[index]
        let tint = DollhouseTint.for(wall.changeStatus, mode: options.mode)
        let placed = placeOpenings(of: index)

        var mesh = DollhouseMesh()
        addSolid(index, placed: placed, to: &mesh)
        if options.includeTrim {
            addBaseboards(index, placed: placed, to: &mesh)
        }

        var openings: [DollhouseModel.Element] = []
        for opening in placed {
            let detail = openingMesh(opening, wall: index)
            guard !detail.isEmpty else { continue }
            // An opening goes with its wall: a demolished wall's door is
            // demolished too, and a new wall's window is new.
            let own = DollhouseTint.for(opening.opening.changeStatus, mode: options.mode)
            openings.append(.init(kind: .opening, id: opening.opening.id,
                                  tint: tint != .none ? tint : own, mesh: detail))
        }
        return Built(wall: .init(kind: .wall, id: wall.id, tint: tint, mesh: mesh), openings: openings)
    }

    /// The wall's openings in this mode, clamped to the straight part of the
    /// wall and to each other, with what the cut leaves of them.
    func placeOpenings(of index: Int) -> [PlacedOpening] {
        let wall = walls[index]
        let f = frames[index]
        let j = joints[index]
        let lo = max(f.s(j.start.left), f.s(j.start.right), j.start.center.map(f.s) ?? -.infinity) + 0.005
        let hi = min(f.s(j.end.left), f.s(j.end.right), j.end.center.map(f.s) ?? .infinity) - 0.005
        let wallTop = top(of: index)

        var result: [PlacedOpening] = []
        let openings = wall.openings
            .filter { PlanGenerator.includeElement($0.changeStatus, mode: options.mode) }
            .sorted { $0.startOffset < $1.startOffset }
        for opening in openings {
            var s0 = max(opening.startOffset, lo)
            let s1 = min(opening.endOffset, hi)
            if let last = result.last { s0 = max(s0, last.s1) }
            guard s1 - s0 > 0.05 else { continue }

            let lower: Double
            let lowerMaterial: DollhouseMaterial
            let soffit: DollhouseMaterial
            switch opening.kind {
            case .door:
                lower = DollhouseBuilder.thresholdHeight
                lowerMaterial = .threshold
                soffit = .trim
            case .opening:
                lower = DollhouseBuilder.openingFloorHeight
                let side = room(at: (s0 + s1) / 2, side: 1, of: index) ?? room(at: (s0 + s1) / 2, side: -1, of: index)
                lowerMaterial = .floor(side.map { FloorFinish.for($0.type) } ?? .wood)
                soffit = .trim
            case .window:
                lower = max(opening.sillHeight, DollhouseBuilder.openingFloorHeight)
                lowerMaterial = .windowSill
                soffit = .wall
            }
            // Wholly above the cut: the wall is solid as far as it is drawn.
            guard lower < wallTop - 0.01 else { continue }

            let rawHead = opening.kind == .door
                ? max(opening.sillHeight, 0) + opening.height
                : opening.sillHeight + opening.height
            let head = min(max(rawHead, lower + 0.05), wallTop)
            let clippedByCut = options.cutHeight != nil && rawHead >= wallTop - 0.005
            result.append(PlacedOpening(
                opening: opening, s0: s0, s1: s1, lower: lower, head: head,
                hasHead: !clippedByCut, lowerMaterial: lowerMaterial, soffitMaterial: soffit))
        }
        return result
    }

    /// The room just beyond the wall face on `side` at `s`.
    func room(at s: Double, side: Double, of index: Int) -> RoomShape? {
        let f = frames[index]
        let p = f.point(s, side * (f.half + 0.12))
        return rooms.first { GeometryOps.polygonContains($0.polygon, p) }
    }

    // MARK: Solid

    struct Span {
        var lo: Double
        var hi: Double
        var top: DollhouseMaterial
        /// Nil when the underside is never seen (it sits under the floor).
        var bottom: DollhouseMaterial?
    }

    struct Interval {
        var start: Double?
        var end: Double?
        var spans: [Span]
        var opening: PlacedOpening?
    }

    /// The footprint as resolved by the joints, edges labelled. Falls back to
    /// square ends when a very short wall at a sharp corner would fold over
    /// itself.
    func footprint(of index: Int) -> LabelledPolygon {
        let j = joints[index]
        var polygon = LabelledPolygon()
        func ends(_ end: WallEnd, from first: Vec2) {
            if let center = end.center, end.faces.count == 2 {
                polygon.append(first, .end(end.faces[0]))
                polygon.append(center, .end(end.faces[1]))
            } else {
                polygon.append(first, .end(end.faces.first
                    ?? WallEnd.EndFace(from: first, to: first, neighbour: nil)))
            }
        }
        polygon.append(j.start.right, .side)
        ends(j.end, from: j.end.right)
        polygon.append(j.end.left, .side)
        ends(j.start, from: j.start.left)

        if GeometryOps.signedArea(polygon.points) > 1e-6, !GeometryOps.polygonSelfIntersects(polygon.points) {
            return polygon
        }
        let wall = walls[index]
        let half = frames[index].half
        let start = WallJoints.squareEnd(wall, isStart: true, half: half)
        let end = WallJoints.squareEnd(wall, isStart: false, half: half)
        var square = LabelledPolygon()
        square.append(start.right, .side)
        square.append(end.right, .end(end.faces[0]))
        square.append(end.left, .side)
        square.append(start.left, .end(start.faces[0]))
        return square
    }

    func intervals(of index: Int, placed: [PlacedOpening]) -> [Interval] {
        let bottom = -options.slabThickness
        let wallTop = top(of: index)
        let solid = [Span(lo: bottom, hi: wallTop, top: .wallCap, bottom: nil)]
        var result: [Interval] = []
        var cursor: Double? = nil
        for opening in placed {
            if cursor.map({ opening.s0 - $0 > 1e-4 }) ?? true {
                result.append(Interval(start: cursor, end: opening.s0, spans: solid, opening: nil))
            }
            var spans = [Span(lo: bottom, hi: opening.lower, top: opening.lowerMaterial, bottom: nil)]
            if opening.head < wallTop - 0.005 {
                spans.append(Span(lo: opening.head, hi: wallTop, top: .wallCap, bottom: opening.soffitMaterial))
            }
            result.append(Interval(start: opening.s0, end: opening.s1, spans: spans, opening: opening))
            cursor = opening.s1
        }
        result.append(Interval(start: cursor, end: nil, spans: solid, opening: nil))
        return result
    }

    func addSolid(_ index: Int, placed: [PlacedOpening], to mesh: inout DollhouseMesh) {
        let frame = frames[index]
        let outline = footprint(of: index)
        let intervals = self.intervals(of: index, placed: placed)
        let uvAngle = frame.u.angle

        for (i, interval) in intervals.enumerated() {
            var piece = outline
            if let a = interval.start {
                piece = piece.clipped({ frame.s($0) - a }, cut: .cut(i - 1))
            }
            if let b = interval.end {
                piece = piece.clipped({ b - frame.s($0) }, cut: .cut(i))
            }
            guard piece.points.count >= 3, GeometryOps.area(piece.points) > 1e-8 else { continue }

            for span in interval.spans where span.hi - span.lo > 1e-5 {
                mesh.addHorizontal(piece.points, y: base + span.hi, facingUp: true,
                                   material: span.top, uvAngle: uvAngle)
                if let underside = span.bottom {
                    mesh.addHorizontal(piece.points, y: base + span.lo, facingUp: false,
                                       material: underside, uvAngle: uvAngle)
                }
                for k in piece.points.indices {
                    let p = piece.points[k]
                    let q = piece.points[(k + 1) % piece.points.count]
                    let edge = q - p
                    guard edge.length > 1e-6 else { continue }
                    let outward = Vec2(edge.y, -edge.x)
                    var ranges: [(Double, Double)]
                    var material = DollhouseMaterial.wall
                    switch piece.roles[k] {
                    case .side:
                        ranges = [(span.lo, span.hi)]
                    case .end(let face):
                        let hidden = face.neighbour.map { top(of: $0) } ?? -.infinity
                        ranges = [(max(span.lo, hidden), span.hi)]
                    case .cut(let boundary):
                        let other = boundary == i - 1 ? i - 1 : i + 1
                        guard intervals.indices.contains(other) else { continue }
                        ranges = Self.subtract((span.lo, span.hi), intervals[other].spans)
                        let kind = (intervals[other].opening ?? interval.opening)?.opening.kind
                        material = kind == .window || kind == nil ? .wall : .trim
                    }
                    for (lo, hi) in ranges where hi - lo > 1e-5 {
                        mesh.addVertical(from: p, to: q, bottom: base + lo, top: base + hi,
                                         outward: outward, material: material)
                    }
                }
            }
        }
    }

    /// What is left of `range` once `spans` are taken out of it.
    static func subtract(_ range: (Double, Double), _ spans: [Span]) -> [(Double, Double)] {
        var pieces = [range]
        for span in spans {
            pieces = pieces.flatMap { piece -> [(Double, Double)] in
                if span.hi <= piece.0 || span.lo >= piece.1 { return [piece] }
                var out: [(Double, Double)] = []
                if span.lo > piece.0 { out.append((piece.0, span.lo)) }
                if span.hi < piece.1 { out.append((span.hi, piece.1)) }
                return out
            }
        }
        return pieces
    }

    // MARK: Baseboards

    /// A baseboard along every face that looks into a room, mitred at the
    /// corners the way the wall is, stopping at door casings.
    func addBaseboards(_ index: Int, placed: [PlacedOpening], to mesh: inout DollhouseMesh) {
        let frame = frames[index]
        let height = min(DollhouseBuilder.baseboardHeight, top(of: index) - 0.002)
        guard height > 0.02 else { return }
        let casing = DollhouseBuilder.casingWidth

        // Gaps where something reaches the floor.
        var gaps = placed.filter(\.reachesFloor).map { ($0.s0 - casing, $0.s1 + casing) }
        gaps.sort { $0.0 < $1.0 }

        for side in [1.0, -1.0] where room(onSide: side, of: index) != nil {
            let j = joints[index]
            let t = trimJoints[index]
            let back = (start: side > 0 ? j.start.left : j.start.right,
                        end: side > 0 ? j.end.left : j.end.right)
            let front = (start: side > 0 ? t.start.left : t.start.right,
                         end: side > 0 ? t.end.left : t.end.right)
            // The back corners sit where the face meets the line the front
            // corner's mitre runs along, so neighbouring boards close exactly.
            let startFace = side > 0 ? t.start.faces.first : t.start.faces.last
            let endFace = side > 0 ? t.end.faces.last : t.end.faces.first
            let faceLine = frame.point(0, side * frame.half)
            func backCorner(_ frontCorner: Vec2, _ face: WallEnd.EndFace?, fallback: Vec2) -> Vec2 {
                guard let face else { return fallback }
                let along = face.to - face.from
                guard along.length > 1e-6 else { return fallback }
                return WallJoints.intersect(frontCorner, along.normalized, faceLine, frame.u, limit: 0.5) ?? fallback
            }
            let board = LabelledPolygon(
                points: [backCorner(front.start, startFace, fallback: back.start),
                         backCorner(front.end, endFace, fallback: back.end),
                         front.end, front.start],
                roles: [.side, .side, .side, .side])

            var cursor: Double? = nil
            for gap in gaps + [(Double.infinity, Double.infinity)] {
                var piece = board
                if let a = cursor {
                    piece = piece.clipped({ frame.s($0) - a }, cut: .side)
                }
                if gap.0.isFinite {
                    piece = piece.clipped({ gap.0 - frame.s($0) }, cut: .side)
                }
                if piece.points.count >= 3, GeometryOps.area(piece.points) > 1e-7 {
                    mesh.addPrism(piece.points, bottom: base, top: base + height,
                                  material: .baseboard, skipBottom: true)
                }
                cursor = max(cursor ?? -.infinity, gap.1)
            }
        }
    }
}
