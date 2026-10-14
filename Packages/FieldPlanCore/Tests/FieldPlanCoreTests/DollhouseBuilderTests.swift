import XCTest
@testable import FieldPlanCore

final class DollhouseBuilderTests: XCTestCase {

    // MARK: Helpers

    private func options(trim: Bool = false, mode: PlanRenderMode = .existing, cut: Double? = nil) -> DollhouseBuilder.Options {
        var o = DollhouseBuilder.Options()
        o.includeTrim = trim
        o.mode = mode
        o.cutHeight = cut
        return o
    }

    private func build(_ walls: [Wall], rooms: [RoomShape] = [], options: DollhouseBuilder.Options) -> DollhouseModel.Level {
        DollhouseBuilder.build(level: LevelGeometry(name: "L", walls: walls, rooms: rooms),
                               floorHeight: 0, options: options)
    }

    private func merged(_ level: DollhouseModel.Level, _ kind: DollhouseModel.Element.Kind) -> DollhouseMesh {
        var mesh = DollhouseMesh()
        for element in level.elements where element.kind == kind {
            mesh.append(element.mesh)
        }
        return mesh
    }

    private func wall(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                      height: Double = 2.5, thickness: Double = 0.1,
                      openings: [WallOpening] = [], status: ChangeStatus = .existing) -> Wall {
        Wall(start: Vec2(x0, y0), end: Vec2(x1, y1), height: height, thickness: thickness,
             openings: openings, changeStatus: status)
    }

    // MARK: Joints

    func testRightAngleCornerIsMitredWithNoGapOrOverlap() {
        let level = build([wall(0, 0, 4, 0), wall(0, 0, 0, 3)], options: options())
        let walls = merged(level, .wall)
        // The tops tile the union of the two thick segments exactly: an
        // overlap would count the corner twice, a notch would miss it.
        let union: Double = 4.05 * 0.1 + 3.05 * 0.1 - 0.01
        XCTAssertEqual(walls.area(of: .wallCap), union, accuracy: 1e-9)
        // The outside corner is a real corner, not a notch.
        let b = walls.bounds!
        XCTAssertEqual(b.min.x, -0.05, accuracy: 1e-9)
        XCTAssertEqual(b.max.z, 0.05, accuracy: 1e-9)
        // Faces: both sides of both walls plus the two free ends, from the
        // underside of the slab to the top. The mitre itself is hidden.
        let span = 2.5 + 0.08
        let length: Double = 3.95 + 4.05 + 0.1 + 3.05 + 2.95 + 0.1
        XCTAssertEqual(walls.area(of: .wall), length * span, accuracy: 1e-9)
    }

    func testClosedRoomHasNoEndFacesAndExactCaps() {
        let walls = [wall(0, 0, 4, 0), wall(4, 0, 4, 3), wall(4, 3, 0, 3), wall(0, 3, 0, 0)]
        let level = build(walls, options: options())
        let mesh = merged(level, .wall)
        XCTAssertEqual(mesh.area(of: .wallCap), 4.1 * 3.1 - 3.9 * 2.9, accuracy: 1e-9)
        let perimeters: Double = 2 * (4.1 + 3.1) + 2 * (3.9 + 2.9)
        XCTAssertEqual(mesh.area(of: .wall), perimeters * 2.58, accuracy: 1e-9)
    }

    func testThreeWayJunctionTilesTheNode() {
        let split = [wall(-2, 0, 0, 0), wall(0, 0, 2, 0), wall(0, 0, 0, 2)]
        let union = 4 * 0.1 + 1.95 * 0.1
        let a = merged(build(split, options: options()), .wall)
        XCTAssertEqual(a.area(of: .wallCap), union, accuracy: 1e-9)

        // The same T with the long wall never split: the stem stops at its face.
        let unsplit = [wall(-2, 0, 2, 0), wall(0, 0, 0, 2)]
        let b = merged(build(unsplit, options: options()), .wall)
        XCTAssertEqual(b.area(of: .wallCap), union, accuracy: 1e-9)
        // Its end is hidden against the long wall; only the far end shows.
        let faces: Double = 4 + 4 + 0.1 + 0.1 + 1.95 + 1.95 + 0.1
        XCTAssertEqual(b.area(of: .wall), faces * 2.58, accuracy: 1e-9)
    }

    func testTallerWallShowsItsEndAboveALowerNeighbour() {
        let level = build([wall(0, 0, 4, 0), wall(0, 0, 0, 3, height: 2.0)], options: options())
        let mesh = merged(level, .wall)
        let a: Double = (3.95 + 4.05 + 0.1) * 2.58
        let b: Double = (3.05 + 2.95 + 0.1) * 2.08
        let exposedMitre = 0.5 * (0.02).squareRoot()
        XCTAssertEqual(mesh.area(of: .wall), a + b + exposedMitre, accuracy: 1e-9)
    }

    // MARK: Openings

    private var roomAbove: RoomShape {
        RoomShape(name: "Room", type: .livingRoom, polygon: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)])
    }

    func testDoorHasJambsSaddleLeafAndCasing() {
        let door = WallOpening(kind: .door, centerOffset: 2, width: 0.9, height: 2.03,
                               swing: DoorSwing(hingeAtStart: true, opensPositiveSide: true))
        let level = build([wall(0, 0, 4, 0, openings: [door])], rooms: [roomAbove], options: options(trim: true))
        let walls = merged(level, .wall)
        XCTAssertEqual(walls.area(of: .threshold), 0.9 * 0.1, accuracy: 1e-9)
        // Jambs both sides from the saddle to the head, and the head soffit.
        XCTAssertEqual(walls.area(of: .trim), 2 * (2.03 - 0.008) * 0.1 + 0.9 * 0.1, accuracy: 1e-9)

        let opening = merged(level, .opening)
        XCTAssertGreaterThan(opening.area(of: .doorLeaf), 2 * 0.89 * 2.0)
        XCTAssertGreaterThan(opening.area(of: .hardware), 0)
        XCTAssertGreaterThan(opening.area(of: .trim), 0, "casings")
        // Open 90° into the room it swings to (plan +y is scene −z).
        let b = opening.bounds!
        XCTAssertLessThan(b.min.z, -0.85)
        XCTAssertEqual(b.max.y, 2.03 + 0.07, accuracy: 0.002, "head casing tops the door")

        // The baseboard runs on the room side only, stopping at the casing.
        XCTAssertGreaterThan(walls.area(of: .baseboard), 0)
        for sub in walls.submeshes where sub.material == .baseboard {
            for index in sub.indices {
                let p = walls.positions[Int(index)]
                XCTAssertLessThanOrEqual(p.z, -0.05 + 1e-9, "on the room side")
                XCTAssertFalse(p.x > 1.55 - 0.07 + 1e-6 && p.x < 2.45 + 0.07 - 1e-6, "not across the door")
            }
        }
    }

    func testClosedDoorStaysInTheOpening() {
        let door = WallOpening(kind: .door, centerOffset: 2, width: 0.9, height: 2.03)
        var o = options()
        o.doorsOpen = false
        let level = build([wall(0, 0, 4, 0, openings: [door])], options: o)
        let b = merged(level, .opening).bounds!
        XCTAssertGreaterThanOrEqual(b.min.x, 1.55 - 1e-9)
        XCTAssertLessThanOrEqual(b.max.x, 2.45 + 1e-9)
        XCTAssertLessThan(b.max.z - b.min.z, 0.1 + 1e-9, "within the wall thickness, handles aside")
    }

    func testWindowSitsTowardTheOutsideWithGlassFrameAndStool() {
        let window = WallOpening(kind: .window, centerOffset: 2, width: 1.5, height: 1.2, sillHeight: 0.9)
        let level = build([wall(0, 0, 4, 0, thickness: 0.2, openings: [window])], rooms: [roomAbove],
                          options: options(trim: true))
        let walls = merged(level, .wall)
        XCTAssertEqual(walls.area(of: .windowSill), 1.5 * 0.2, accuracy: 1e-9)
        // Drywall returns: two sides and the head.
        let faces: Double = 8 * 2.58 + 2 * 0.2 * 2.58 - 2 * 1.5 * 1.2
        let returns: Double = 2 * 1.2 * 0.2 + 1.5 * 0.2
        XCTAssertEqual(walls.area(of: .wall) - faces, returns, accuracy: 1e-9)

        let opening = merged(level, .opening)
        XCTAssertGreaterThan(opening.area(of: .glass), 2 * 1.3 * 1.0)
        XCTAssertGreaterThan(opening.area(of: .windowFrame), 0)
        XCTAssertGreaterThan(opening.area(of: .windowSill), 0, "stool inside, nose outside")
        // The room is on the left (+y), so the outside is −y: the glass sits
        // past the centreline toward it (scene +z).
        for sub in opening.submeshes where sub.material == .glass {
            for index in sub.indices {
                XCTAssertEqual(opening.positions[Int(index)].z, 0.05, accuracy: 1e-9)
            }
        }
    }

    func testCutawayLowersEverythingToTheCut() {
        let door = WallOpening(kind: .door, centerOffset: 1, width: 0.8, height: 2.03)
        let window = WallOpening(kind: .window, centerOffset: 3, width: 1, height: 1.2, sillHeight: 0.9)
        let level = build([wall(0, 0, 4, 0, openings: [door, window])], rooms: [roomAbove],
                          options: options(trim: true, cut: 1.2))
        for element in level.elements {
            XCTAssertLessThanOrEqual(element.mesh.bounds!.max.y, 1.2 + 1e-9, "\(element.kind)")
        }
        let walls = merged(level, .wall)
        // The cut top covers the footprint except where the door and the
        // window (whose head is above the cut) open through it.
        let footprint = 4 * 0.1
        let holes = (0.8 + 1.0) * 0.1
        XCTAssertEqual(walls.area(of: .wallCap), footprint - holes, accuracy: 1e-9)
        XCTAssertEqual(walls.area(of: .windowSill), 1.0 * 0.1, accuracy: 1e-9)
        XCTAssertEqual(level.wallHeight, 1.2, accuracy: 1e-12)

        // A cut under the sill leaves the window out entirely.
        let low = build([wall(0, 0, 4, 0, openings: [window])], options: options(cut: 0.6))
        XCTAssertTrue(low.elements.filter { $0.kind == .opening }.isEmpty)
        XCTAssertEqual(merged(low, .wall).area(of: .windowSill), 0)
    }

    // MARK: Modes

    func testModesHideAndTintLikeThePlan() {
        let gone = wall(0, 0, 4, 0, status: .demolish)
        let added = wall(0, 1, 4, 1, status: .new)
        let kept = wall(0, 2, 4, 2)
        func tints(_ mode: PlanRenderMode) -> [DollhouseTint] {
            build([gone, added, kept], options: options(mode: mode)).elements
                .filter { $0.kind == .wall }.map(\.tint)
        }
        XCTAssertEqual(tints(.existing), [.none, .none], "the wall to come down is drawn as it stands")
        XCTAssertEqual(tints(.proposed), [.new, .none])
        XCTAssertEqual(tints(.demolition), [.demolish, .none])
        XCTAssertEqual(tints(.overlay), [.demolish, .new, .none])

        // A door to be filled in is a solid wall in the proposed model.
        let filled = WallOpening(kind: .door, centerOffset: 2, width: 0.9, height: 2.03, changeStatus: .demolish)
        let proposed = build([wall(0, 0, 4, 0, openings: [filled])], options: options(mode: .proposed))
        XCTAssertEqual(merged(proposed, .wall).area(of: .threshold), 0)
        let demolition = build([wall(0, 0, 4, 0, openings: [filled])], options: options(mode: .demolition))
        XCTAssertEqual(demolition.elements.first { $0.kind == .opening }?.tint, .demolish)
    }

    // MARK: Whole plans

    func testSampleApartmentIsWellFormed() {
        let level = SampleFixtures.apartment()
        var o = DollhouseBuilder.Options()
        o.includeFixtures = true
        o.includeFurniture = true
        o.includeCeilings = true
        let model = DollhouseBuilder.build(levels: [level], options: o)
        XCTAssertEqual(model.levels.count, 1)
        let built = model.levels[0]
        XCTAssertEqual(built.rooms.count, level.rooms.count)
        XCTAssertEqual(built.elements.filter { $0.kind == .wall }.count, level.walls.count)
        XCTAssertGreaterThan(built.elements.filter { $0.kind == .opening }.count, 3)
        XCTAssertGreaterThan(model.triangleCount, 1000)

        // Every triangle faces the way its normal says, nothing is NaN, and
        // every vertex is used.
        for element in built.elements {
            let mesh = element.mesh
            XCTAssertEqual(mesh.positions.count, mesh.normals.count)
            XCTAssertEqual(mesh.positions.count, mesh.uvs.count)
            var used = Set<Int32>()
            for sub in mesh.submeshes {
                XCTAssertEqual(sub.indices.count % 3, 0)
                var i = 0
                while i + 2 < sub.indices.count {
                    let a = mesh.positions[Int(sub.indices[i])]
                    let b = mesh.positions[Int(sub.indices[i + 1])]
                    let c = mesh.positions[Int(sub.indices[i + 2])]
                    let n = mesh.normals[Int(sub.indices[i])]
                    XCTAssertGreaterThan((b - a).cross(c - a).dot(n), 0, "\(element.kind) \(sub.material.name)")
                    i += 3
                }
                used.formUnion(sub.indices)
            }
            XCTAssertEqual(used.count, mesh.positions.count)
            XCTAssertTrue(mesh.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            XCTAssertTrue(mesh.normals.allSatisfy { abs($0.length - 1) < 1e-9 })
        }

        // The model sits on the plan: x and −z span the plan's bounds, give
        // or take a wall's half thickness.
        let plan = level.bounds
        let b = model.bounds!
        XCTAssertEqual(b.min.x, plan.minX, accuracy: 0.2)
        XCTAssertEqual(b.max.x, plan.maxX, accuracy: 0.2)
        XCTAssertEqual(-b.max.z, plan.minY, accuracy: 0.2)
        XCTAssertEqual(-b.min.z, plan.maxY, accuracy: 0.2)
    }

    func testFloorsGetAFinishByRoomType() {
        XCTAssertEqual(FloorFinish.for(.bathroom), .tile)
        XCTAssertEqual(FloorFinish.for(.bedroom), .carpet)
        XCTAssertEqual(FloorFinish.for(.garage), .concrete)
        XCTAssertEqual(FloorFinish.for(.livingRoom), .wood)
        let level = build([], rooms: [RoomShape(name: "Bath", type: .bathroom,
                                                polygon: [Vec2(0, 0), Vec2(2, 0), Vec2(2, 2), Vec2(0, 2)])],
                          options: options())
        let floor = merged(level, .floor)
        XCTAssertEqual(floor.area(of: .floor(.tile)), 4, accuracy: 1e-9)
        XCTAssertEqual(floor.area(of: .ceiling), 4, accuracy: 1e-9, "underside")
        XCTAssertEqual(level.rooms.first?.name, "Bath")
        XCTAssertEqual(level.rooms.first?.position.y ?? 0, 0.01, accuracy: 1e-12)
    }

    func testLevelsStackOnTheWallsBelowOrAtMeasuredHeights() {
        var lower = LevelGeometry(name: "1", storyIndex: 0, walls: [wall(0, 0, 4, 0, height: 2.5)])
        var upper = LevelGeometry(name: "2", storyIndex: 1, walls: [wall(0, 0, 4, 0, height: 2.4)])

        // Unmeasured: on the walls below plus a floor structure, the slab
        // filling it so nothing floats.
        let stacked = DollhouseBuilder.placements(for: [upper, lower])
        XCTAssertEqual(stacked[lower.id], .init(floorHeight: 0, slab: 0.08))
        XCTAssertEqual(stacked[upper.id]?.floorHeight ?? 0, 2.8, accuracy: 1e-12)
        XCTAssertEqual(stacked[upper.id]?.slab ?? 0, 0.3, accuracy: 1e-12)
        let model = DollhouseBuilder.build(levels: [lower, upper])
        XCTAssertEqual(model.levels.map(\.name), ["1", "2"])
        let upperWalls = model.levels[1].elements.first { $0.kind == .wall }!.mesh.bounds!
        XCTAssertEqual(upperWalls.min.y, 2.5, accuracy: 1e-12, "the upper walls run down to the ones below")

        // A fixed spacing, when asked for.
        var spaced = DollhouseBuilder.Options()
        spaced.levelSpacing = 3.4
        XCTAssertEqual(DollhouseBuilder.floorHeights(for: [lower, upper], options: spaced)[upper.id], 3.4)

        // Measured: the scanned heights, the lowest at zero.
        lower.elevation = 10.0
        upper.elevation = 12.9
        let measured = DollhouseBuilder.placements(for: [lower, upper])
        XCTAssertEqual(measured[lower.id]?.floorHeight, 0)
        XCTAssertEqual(measured[upper.id]?.floorHeight ?? 0, 2.9, accuracy: 1e-12)
        XCTAssertEqual(measured[upper.id]?.slab ?? 0, 0.4, accuracy: 1e-12)
    }

    // MARK: Fixtures

    func testFixturesSitAtTheirScannedHeight() {
        var cabinet = FixtureItem(category: .cabinetUpper, center: .zero, size: Vec2(1, 0.35), height: 0.7)
        XCTAssertEqual(FixtureMounting.extent(of: cabinet).bottom, 1.4, "typical when not scanned")
        cabinet.elevation = 1.52
        XCTAssertEqual(FixtureMounting.extent(of: cabinet).bottom, 1.52)
        XCTAssertEqual(FixtureMounting.extent(of: cabinet).top, 2.22, accuracy: 1e-12)

        var sofa = FixtureItem(category: .sofa, center: .zero, size: Vec2(2, 0.9), height: 0.8)
        sofa.elevation = 0.04
        XCTAssertEqual(FixtureMounting.extent(of: sofa).bottom, 0, "scanner wobble is the floor")

        let mesh = DollhouseBuilder.fixtureMesh(cabinet, base: 3)
        XCTAssertEqual(mesh.bounds!.min.y, 4.52, accuracy: 1e-12)
        XCTAssertEqual(mesh.area(of: .fixture), 2 * 0.35 + 2 * (1 + 0.35) * 0.7, accuracy: 1e-9)

        // Older saved fixtures decode without the field.
        let legacy = #"{"id":"8D7C2E52-3F0E-4E0F-9C55-1D2B6A1E4A11","category":"sofa","center":{"x":0,"y":0},"size":{"x":2,"y":1},"rotation":0,"changeStatus":"existing","source":"manualEntry","confidence":"medium"}"#
        let decoded = try? JSONDecoder().decode(FixtureItem.self, from: Data(legacy.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.elevation)
    }
}
