import Foundation

// MARK: - Doors, windows and cased openings
//
// The wall solid already has the hole, its jambs, head and sill. This adds
// what sits in and around it: door leaves of the plan's style (hinged and
// double drawn open on their swing side, sliding, pocket, bi-fold, garage),
// lever handles, window frames with glass, mullions and a meeting rail, and
// the trim — casings on each face, a stool and apron under a window inside, a
// sill nose outside.

extension WallContext {

    func openingMesh(_ placed: PlacedOpening, wall index: Int) -> DollhouseMesh {
        var mesh = DollhouseMesh()
        switch placed.opening.kind {
        case .door:
            addDoor(placed, wall: index, to: &mesh)
            if options.includeTrim && placed.opening.resolvedStyle != .garage {
                for side in [1.0, -1.0] {
                    addCasing(placed, wall: index, side: side, from: 0, to: &mesh)
                }
            }
        case .opening:
            if options.includeTrim {
                for side in [1.0, -1.0] {
                    addCasing(placed, wall: index, side: side, from: 0, to: &mesh)
                }
            }
        case .window:
            addWindow(placed, wall: index, to: &mesh)
        }
        return mesh
    }

    /// An upright board in the wall's frame: along-wall range `s`, offset
    /// range across the wall, heights above this level's floor.
    func addBoard(
        _ mesh: inout DollhouseMesh, wall index: Int,
        s: (Double, Double), across: (Double, Double), y: (Double, Double),
        material: DollhouseMaterial
    ) {
        let f = frames[index]
        let s0 = min(s.0, s.1), s1 = max(s.0, s.1)
        let o0 = min(across.0, across.1), o1 = max(across.0, across.1)
        guard s1 - s0 > 1e-4, o1 - o0 > 1e-4, y.1 - y.0 > 1e-4 else { return }
        mesh.addPrism([f.point(s0, o0), f.point(s1, o0), f.point(s1, o1), f.point(s0, o1)],
                      bottom: base + y.0, top: base + y.1, material: material,
                      skipBottom: y.0 < 1e-4)
    }

    // MARK: Casing

    /// Flat casing round the opening on one face: two legs from `bottom` up
    /// to the head and a head piece across both. Kept inside the face, so it
    /// never runs into the wall round a corner, and under the wall's top.
    func addCasing(
        _ placed: PlacedOpening, wall index: Int, side: Double, from bottom: Double,
        to mesh: inout DollhouseMesh
    ) {
        let f = frames[index]
        let width = DollhouseBuilder.casingWidth
        let depth = DollhouseBuilder.casingDepth
        let face = faceRange(of: index, side: side)
        let across = (side * f.half, side * (f.half + depth))
        let ceiling = top(of: index) - 0.0005
        let legTop = min(placed.head, ceiling)
        let outerStart = max(placed.s0 - width, face.lo + 0.002)
        let outerEnd = min(placed.s1 + width, face.hi - 0.002)

        if placed.s0 - outerStart > 0.02 {
            addBoard(&mesh, wall: index, s: (outerStart, placed.s0), across: across,
                     y: (bottom, legTop), material: .trim)
        }
        if outerEnd - placed.s1 > 0.02 {
            addBoard(&mesh, wall: index, s: (placed.s1, outerEnd), across: across,
                     y: (bottom, legTop), material: .trim)
        }
        let headTop = min(placed.head + width, ceiling)
        if placed.hasHead, headTop - placed.head > 0.01 {
            addBoard(&mesh, wall: index, s: (outerStart, outerEnd), across: across,
                     y: (placed.head, headTop), material: .trim)
        }
    }

    // MARK: Doors

    func addDoor(_ placed: PlacedOpening, wall index: Int, to mesh: inout DollhouseMesh) {
        let f = frames[index]
        let opening = placed.opening
        let swing = opening.swing ?? DoorSwing()
        let side: Double = swing.opensPositiveSide ? 1 : -1
        let bottom = DollhouseBuilder.thresholdHeight + 0.004
        let top = min(placed.head, top(of: index)) - 0.003
        guard top - bottom > 0.2 else { return }
        let thickness = min(0.04, f.half * 1.6)
        // The closed leaf sits towards the face it swings to.
        let plane = side * max(0, f.half - thickness / 2 - 0.006)

        /// A hinged leaf `width` wide from the jamb at `hinge`, running
        /// into the opening along `toward` (±1 along the wall), turned
        /// `angle` toward the swing side.
        func hingedLeaf(hinge: Double, toward: Double, width: Double, angle: Double) {
            let shift = 0.003 + (thickness / 2) * sin(angle)
            let pivot = f.point(hinge + toward * shift, plane)
            let along = f.u * (toward * cos(angle)) + f.n * (side * sin(angle))
            let center = pivot + along * (width / 2)
            mesh.addBox(center: center, axis: along, width: width, depth: thickness,
                        bottom: base + bottom, top: base + top, material: .doorLeaf)
            if top > 1.2 {
                addLever(&mesh, latch: pivot + along * (width - 0.065), along: along,
                         thickness: thickness)
            }
        }

        let width = placed.width
        let open = options.doorsOpen ? Double.pi / 2 : 0
        switch opening.resolvedStyle {
        case .hinged:
            hingedLeaf(hinge: swing.hingeAtStart ? placed.s0 : placed.s1,
                       toward: swing.hingeAtStart ? 1 : -1,
                       width: width - 0.006, angle: open)
        case .doubleHinged:
            hingedLeaf(hinge: placed.s0, toward: 1, width: width / 2 - 0.004, angle: open)
            hingedLeaf(hinge: placed.s1, toward: -1, width: width / 2 - 0.004, angle: open)
        case .sliding:
            addSlidingPanels(placed, wall: index, bottom: bottom, top: top, to: &mesh)
        case .pocket:
            // The leaf slides out of the wall from one jamb; most of it is
            // inside the pocket when open.
            let jamb = swing.hingeAtStart ? placed.s0 : placed.s1
            let into: Double = swing.hingeAtStart ? 1 : -1
            let showing = options.doorsOpen ? width * 0.35 : width - 0.004
            let leaf = min(0.035, f.half * 1.2)
            addBoard(&mesh, wall: index, s: (jamb, jamb + into * showing),
                     across: (-leaf / 2, leaf / 2), y: (bottom, top), material: .doorLeaf)
        case .bifold:
            let fold = options.doorsOpen ? 50 * Double.pi / 180 : 0
            let panel = width / 4 - 0.003
            let leaf = min(0.025, f.half * 1.2)
            for (jamb, toward) in [(placed.s0, 1.0), (placed.s1, -1.0)] {
                let hinge = f.point(jamb + toward * 0.003, plane)
                let first = f.u * (toward * cos(fold)) + f.n * (side * sin(fold))
                let second = f.u * (toward * cos(fold)) - f.n * (side * sin(fold))
                let knee = hinge + first * panel
                mesh.addBox(center: hinge + first * (panel / 2), axis: first, width: panel, depth: leaf,
                            bottom: base + bottom, top: base + top, material: .doorLeaf)
                mesh.addBox(center: knee + second * (panel / 2), axis: second, width: panel, depth: leaf,
                            bottom: base + bottom, top: base + top, material: .doorLeaf)
            }
        case .garage:
            // A sectional door, closed, toward the outside.
            let leaf = min(0.045, f.half * 1.4)
            let outside = exteriorSide(of: index) ?? side
            let center = outside * max(0, f.half - leaf / 2 - 0.01)
            let sections = 4
            let gap = 0.008
            let step = (top - bottom) / Double(sections)
            for k in 0..<sections {
                let y0 = bottom + step * Double(k) + (k == 0 ? 0 : gap / 2)
                let y1 = bottom + step * Double(k + 1) - (k == sections - 1 ? 0 : gap / 2)
                addBoard(&mesh, wall: index, s: (placed.s0 + 0.002, placed.s1 - 0.002),
                         across: (center - leaf / 2, center + leaf / 2), y: (y0, y1), material: .doorLeaf)
            }
            // A thin backer so the grooves read as shadow, not as holes.
            addBoard(&mesh, wall: index, s: (placed.s0 + 0.004, placed.s1 - 0.004),
                     across: (center - leaf * 0.2, center + leaf * 0.2), y: (bottom, top), material: .hardware)
        }
    }

    /// A lever and rose on both faces of a leaf, at the usual 0.95 m.
    func addLever(_ mesh: inout DollhouseMesh, latch: Vec2, along: Vec2, thickness: Double) {
        let across = along.perpendicular
        for face in [1.0, -1.0] {
            let rose = latch + across * (face * (thickness / 2 + 0.006))
            mesh.addBox(center: rose, axis: along, width: 0.05, depth: 0.012,
                        bottom: base + 0.925, top: base + 0.975, material: .hardware)
            let lever = latch + across * (face * (thickness / 2 + 0.021)) - along * 0.045
            mesh.addBox(center: lever, axis: along, width: 0.12, depth: 0.018,
                        bottom: base + 0.94, top: base + 0.96, material: .hardware)
        }
    }

    /// Two panels on two tracks, closed and overlapping in the middle. Glass
    /// in a frame on an outside wall (a patio door); solid inside (a closet).
    func addSlidingPanels(
        _ placed: PlacedOpening, wall index: Int, bottom: Double, top: Double,
        to mesh: inout DollhouseMesh
    ) {
        let f = frames[index]
        let glazed = exteriorSide(of: index) != nil
        let panelWidth = placed.width * 0.52
        let thickness = min(0.035, f.half * 0.7)
        let track = min(0.022, max(f.half - thickness / 2 - 0.004, thickness / 2 + 0.001))
        let panels: [(s: (Double, Double), offset: Double)] = [
            ((placed.s0 + 0.002, placed.s0 + panelWidth), track),
            ((placed.s1 - panelWidth, placed.s1 - 0.002), -track),
        ]
        for panel in panels {
            let across = (panel.offset - thickness / 2, panel.offset + thickness / 2)
            guard glazed else {
                addBoard(&mesh, wall: index, s: panel.s, across: across, y: (bottom, top), material: .doorLeaf)
                continue
            }
            let stile = 0.06
            let lowRail = 0.1
            let (a, b) = panel.s
            addBoard(&mesh, wall: index, s: (a, a + stile), across: across, y: (bottom, top), material: .windowFrame)
            addBoard(&mesh, wall: index, s: (b - stile, b), across: across, y: (bottom, top), material: .windowFrame)
            addBoard(&mesh, wall: index, s: (a + stile, b - stile), across: across,
                     y: (bottom, bottom + lowRail), material: .windowFrame)
            addBoard(&mesh, wall: index, s: (a + stile, b - stile), across: across,
                     y: (top - stile, top), material: .windowFrame)
            addGlass(&mesh, wall: index, s: (a + stile, b - stile), offset: panel.offset,
                     y: (bottom + lowRail, top - stile))
        }
    }

    /// One pane, seen from both sides.
    func addGlass(_ mesh: inout DollhouseMesh, wall index: Int, s: (Double, Double), offset: Double,
                  y: (Double, Double)) {
        let f = frames[index]
        guard s.1 - s.0 > 0.01, y.1 - y.0 > 0.01 else { return }
        let a = f.point(s.0, offset)
        let b = f.point(s.1, offset)
        mesh.addVertical(from: a, to: b, bottom: base + y.0, top: base + y.1, outward: f.n, material: .glass)
        mesh.addVertical(from: b, to: a, bottom: base + y.0, top: base + y.1, outward: -f.n, material: .glass)
    }

    // MARK: Windows

    func addWindow(_ placed: PlacedOpening, wall index: Int, to mesh: inout DollhouseMesh) {
        let f = frames[index]
        let exterior = exteriorSide(of: index)
        let depth = min(0.07, max(0.02, 2 * f.half - 0.01))
        // Set toward the outside face, as windows are; centred in an
        // interior wall.
        let center = exterior.map { $0 * max(0, f.half - depth / 2 - 0.015) } ?? 0
        let across = (center - depth / 2, center + depth / 2)
        let inner = (center - depth * 0.4, center + depth * 0.4)
        let member = 0.045
        let rail = 0.035
        let bottom = placed.lower
        let top = min(placed.head, self.top(of: index))
        guard top - bottom > 0.1 else { return }
        let a = placed.s0 + 0.001
        let b = placed.s1 - 0.001
        let glassTop = placed.hasHead ? top - member : top

        // Outer frame.
        addBoard(&mesh, wall: index, s: (a, a + member), across: across, y: (bottom, top), material: .windowFrame)
        addBoard(&mesh, wall: index, s: (b - member, b), across: across, y: (bottom, top), material: .windowFrame)
        addBoard(&mesh, wall: index, s: (a + member, b - member), across: across,
                 y: (bottom, bottom + member), material: .windowFrame)
        if placed.hasHead {
            addBoard(&mesh, wall: index, s: (a + member, b - member), across: across,
                     y: (top - member, top), material: .windowFrame)
        }

        // Mullions keep panes under about a metre; a meeting rail splits a
        // tall window like a double-hung sash.
        let innerWidth = (b - a) - 2 * member
        let columns = max(1, Int((innerWidth / 1.0).rounded(.up)))
        for k in 1..<columns {
            let s = a + member + innerWidth * Double(k) / Double(columns)
            addBoard(&mesh, wall: index, s: (s - rail / 2, s + rail / 2), across: inner,
                     y: (bottom + member, glassTop), material: .windowFrame)
        }
        let innerHeight = top - bottom - 2 * member
        if placed.hasHead, innerHeight > 0.9, bottom > 0.1 {
            let mid = bottom + member + innerHeight / 2
            addBoard(&mesh, wall: index, s: (a + member, b - member), across: inner,
                     y: (mid - rail / 2, mid + rail / 2), material: .windowFrame)
        }
        addGlass(&mesh, wall: index, s: (a + member, b - member), offset: center,
                 y: (bottom + member, glassTop))

        guard options.includeTrim else { return }

        // Inside: stool, apron and casing on every face that looks into a
        // room (both faces of a window with no room on either side).
        var faces = [1.0, -1.0].filter { room(onSide: $0, of: index) != nil }
        if faces.isEmpty { faces = [1, -1] }
        let hasStool = placed.lower >= 0.1
        let range = { (side: Double) in self.faceRange(of: index, side: side) }
        for side in faces {
            let face = range(side)
            var legBottom = 0.0
            if hasStool {
                let stool = 0.025
                let ears = (max(placed.s0 - 0.04, face.lo + 0.002), min(placed.s1 + 0.04, face.hi - 0.002))
                addBoard(&mesh, wall: index, s: ears,
                         across: (center + side * depth / 2, side * (f.half + 0.03)),
                         y: (placed.lower, placed.lower + stool), material: .windowSill)
                let apron = (max(placed.s0 - DollhouseBuilder.casingWidth, face.lo + 0.002),
                             min(placed.s1 + DollhouseBuilder.casingWidth, face.hi - 0.002))
                addBoard(&mesh, wall: index, s: apron,
                         across: (side * f.half, side * (f.half + DollhouseBuilder.casingDepth)),
                         y: (max(0.02, placed.lower - 0.08), placed.lower), material: .trim)
                legBottom = placed.lower + stool
            }
            addCasing(placed, wall: index, side: side, from: legBottom, to: &mesh)
        }

        // Outside: a sill nose that sheds water past the face.
        if let outside = exterior, hasStool {
            let face = range(outside)
            addBoard(&mesh, wall: index,
                     s: (max(placed.s0 - 0.03, face.lo + 0.002), min(placed.s1 + 0.03, face.hi - 0.002)),
                     across: (outside * f.half, outside * (f.half + 0.04)),
                     y: (placed.lower - 0.05, placed.lower), material: .windowSill)
        }
    }
}
