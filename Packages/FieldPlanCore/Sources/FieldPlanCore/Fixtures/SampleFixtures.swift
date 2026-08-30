import Foundation

/// SAMPLE DATA fixtures (spec §59). These let the plan editor, takeoff,
/// export and reporting systems be developed and tested without scanning a
/// property. Every element is tagged `source: .sampleData` so fixtures can
/// NEVER be confused with real field measurements, and generated projects
/// are named with a SAMPLE prefix.
public enum SampleFixtures {

    static let ft = UnitConstants.metersPerFoot
    static let ceiling8: Double = 8 * 0.3048
    static let interiorThickness = 0.1143  // 4 1/2"
    static let exteriorThickness = 0.1524  // 6"

    // MARK: - Wall helpers

    static func wall(
        _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
        height: Double = SampleFixtures.ceiling8,
        thickness: Double = SampleFixtures.interiorThickness,
        openings: [WallOpening] = []
    ) -> Wall {
        Wall(
            start: Vec2(x1 * ft, y1 * ft),
            end: Vec2(x2 * ft, y2 * ft),
            height: height,
            thickness: thickness,
            openings: openings,
            source: .sampleData,
            confidence: .high
        )
    }

    /// Opening positioned in FEET along the wall.
    static func door(atFeet offset: Double, widthFeet: Double = 2.5, height: Double = 2.0320) -> WallOpening {
        WallOpening(
            kind: .door, centerOffset: offset * ft, width: widthFeet * ft,
            height: height, swing: nil, source: .sampleData, confidence: .high
        )
    }

    static func window(atFeet offset: Double, widthFeet: Double = 3.0, heightFeet: Double = 4.0, sillFeet: Double = 2.5) -> WallOpening {
        WallOpening(
            kind: .window, centerOffset: offset * ft, width: widthFeet * ft,
            height: heightFeet * ft, sillHeight: sillFeet * ft,
            source: .sampleData, confidence: .high
        )
    }

    static func passage(atFeet offset: Double, widthFeet: Double = 4.0) -> WallOpening {
        WallOpening(
            kind: .opening, centerOffset: offset * ft, width: widthFeet * ft,
            height: 2.0320, source: .sampleData, confidence: .high
        )
    }

    static func polygonFeet(_ points: [(Double, Double)]) -> [Vec2] {
        points.map { Vec2($0.0 * ft, $0.1 * ft) }
    }

    static func fixture(
        _ category: FixtureCategory,
        centerFeet: (Double, Double),
        sizeFeet: (Double, Double),
        rotation: Double = 0,
        label: String? = nil
    ) -> FixtureItem {
        FixtureItem(
            category: category,
            label: label,
            center: Vec2(centerFeet.0 * ft, centerFeet.1 * ft),
            size: Vec2(sizeFeet.0 * ft, sizeFeet.1 * ft),
            rotation: rotation,
            source: .sampleData,
            confidence: .high
        )
    }

    /// A simple rectangular room level: 4 walls, 1 room. Origin at (0,0),
    /// dimensions in FEET. Used heavily by unit tests.
    public static func rectangularRoom(
        widthFeet: Double,
        depthFeet: Double,
        name: String = "Room",
        type: RoomType = .other,
        ceilingHeightFeet: Double = 8
    ) -> LevelGeometry {
        let w = widthFeet
        let d = depthFeet
        let h = ceilingHeightFeet * ft
        let south = wall(0, 0, w, 0, height: h)
        let east = wall(w, 0, w, d, height: h)
        let north = wall(w, d, 0, d, height: h)
        let west = wall(0, d, 0, 0, height: h)
        let room = RoomShape(
            name: name,
            type: type,
            polygon: polygonFeet([(0, 0), (w, 0), (w, d), (0, d)]),
            ceilingHeight: h,
            ceilingHeightSource: .sampleData,
            wallIDs: [south.id, east.id, north.id, west.id]
        )
        return LevelGeometry(
            name: "Level",
            walls: [south, east, north, west],
            rooms: [room]
        )
    }

    // MARK: - Single-room fixtures

    /// 12' × 15' bedroom: entry door, two windows, bed + storage.
    public static func simpleBedroom() -> LevelGeometry {
        var level = rectangularRoom(widthFeet: 12, depthFeet: 15, name: "Bedroom", type: .bedroom)
        // Door on the south wall, windows on the north wall.
        level.walls[0].openings = [door(atFeet: 2.5, widthFeet: 2.5)]
        level.walls[2].openings = [window(atFeet: 3.5), window(atFeet: 8.5)]
        level.name = "SAMPLE Bedroom"
        level.fixtures = [
            fixture(.bed, centerFeet: (6, 9), sizeFeet: (5, 6.6)),
            fixture(.storage, centerFeet: (10.8, 3), sizeFeet: (2, 5), label: "Dresser"),
        ]
        return level
    }

    /// 5' × 8' bathroom: tub, toilet, vanity, door, window.
    public static func bathroom() -> LevelGeometry {
        var level = rectangularRoom(widthFeet: 5, depthFeet: 8, name: "Bathroom", type: .bathroom)
        level.name = "SAMPLE Bathroom"
        level.walls[0].openings = [door(atFeet: 1.6, widthFeet: 2.33)]
        level.walls[1].openings = [window(atFeet: 5.5, widthFeet: 2, heightFeet: 3, sillFeet: 3.5)]
        level.fixtures = [
            fixture(.bathtub, centerFeet: (2.5, 7.0), sizeFeet: (5, 2.5), label: "Tub"),
            fixture(.toilet, centerFeet: (1.2, 4.2), sizeFeet: (1.6, 2.3)),
            fixture(.vanity, centerFeet: (3.9, 3.5), sizeFeet: (2.0, 1.8)),
        ]
        return level
    }

    /// 10' × 12' kitchen with cabinet run and appliances.
    public static func kitchen() -> LevelGeometry {
        var level = rectangularRoom(widthFeet: 10, depthFeet: 12, name: "Kitchen", type: .kitchen)
        level.name = "SAMPLE Kitchen"
        level.walls[0].openings = [passage(atFeet: 5, widthFeet: 4)]
        level.walls[2].openings = [window(atFeet: 5, widthFeet: 3)]
        level.fixtures = [
            fixture(.cabinetBase, centerFeet: (1.05, 6.0), sizeFeet: (2.1, 9.0), rotation: 0, label: "Base Run"),
            fixture(.cabinetUpper, centerFeet: (0.6, 6.0), sizeFeet: (1.2, 9.0), rotation: 0, label: "Upper Run"),
            fixture(.refrigerator, centerFeet: (8.4, 10.4), sizeFeet: (3.0, 2.8)),
            fixture(.stove, centerFeet: (1.05, 2.6), sizeFeet: (2.5, 2.1)),
            fixture(.sink, centerFeet: (1.05, 8.6), sizeFeet: (2.1, 1.8)),
            fixture(.dishwasher, centerFeet: (1.05, 10.6), sizeFeet: (2.0, 2.1)),
        ]
        return level
    }

    /// Irregular room with a 45° angled wall (tests non-orthogonal support).
    public static func irregularRoom() -> LevelGeometry {
        // Pentagon: rectangle with one corner cut at 45°.
        let a = (0.0, 0.0)
        let b = (14.0, 0.0)
        let c = (14.0, 8.0)
        let d = (8.0, 14.0)   // angled wall from c to d
        let e = (0.0, 14.0)
        let w1 = wall(a.0, a.1, b.0, b.1)
        let w2 = wall(b.0, b.1, c.0, c.1)
        let w3 = wall(c.0, c.1, d.0, d.1) // angled
        let w4 = wall(d.0, d.1, e.0, e.1)
        let w5 = wall(e.0, e.1, a.0, a.1)
        var walls = [w1, w2, w3, w4, w5]
        walls[0].openings = [door(atFeet: 3)]
        walls[3].openings = [window(atFeet: 4)]
        let room = RoomShape(
            name: "Studio",
            type: .other,
            polygon: polygonFeet([a, b, c, d, e]),
            ceilingHeight: ceiling8,
            ceilingHeightSource: .sampleData,
            wallIDs: walls.map(\.id)
        )
        return LevelGeometry(name: "SAMPLE Irregular", walls: walls, rooms: [room])
    }

    // MARK: - Apartment fixtures

    /// One-bedroom apartment, 20' × 28' envelope, seven rooms. Walls are
    /// segmented at every room junction so each room's wall set exactly
    /// matches its perimeter; a shared partition segment exists ONCE and is
    /// referenced by the rooms on both sides. Pass `twoBedroom: true` to
    /// relabel the office as Bedroom 2.
    public static func apartment(twoBedroom: Bool = false) -> LevelGeometry {
        // ---- Exterior wall segments ----
        var s1 = wall(0, 0, 12, 0, thickness: exteriorThickness)      // LR south
        var s2 = wall(12, 0, 20, 0, thickness: exteriorThickness)     // kitchen south
        var e1 = wall(20, 0, 20, 10, thickness: exteriorThickness)    // kitchen east
        var e2 = wall(20, 10, 20, 16, thickness: exteriorThickness)   // bath east
        let e3 = wall(20, 16, 20, 20, thickness: exteriorThickness)   // closet east
        var e4 = wall(20, 20, 20, 28, thickness: exteriorThickness)   // office east
        var n1 = wall(20, 28, 13, 28, thickness: exteriorThickness)   // office north
        var n2 = wall(13, 28, 0, 28, thickness: exteriorThickness)    // bedroom north
        let w1 = wall(0, 28, 0, 16, thickness: exteriorThickness)     // bedroom west
        let w2 = wall(0, 16, 0, 0, thickness: exteriorThickness)      // LR west

        s1.openings = [window(atFeet: 4), door(atFeet: 10, widthFeet: 3, height: 2.0320)] // entry
        s2.openings = [window(atFeet: 4.5, widthFeet: 2.5)]
        e1.openings = [window(atFeet: 5, widthFeet: 3)]
        e2.openings = [window(atFeet: 3, widthFeet: 2, heightFeet: 3, sillFeet: 3.5)]
        e4.openings = [window(atFeet: 4, widthFeet: 3)]
        n1.openings = [window(atFeet: 4, widthFeet: 3)]            // x = 16
        n2.openings = [window(atFeet: 4, widthFeet: 3.5), window(atFeet: 9, widthFeet: 3.5)]

        // ---- Interior partition segments (each shared segment exists once) ----
        var i1a = wall(12, 0, 12, 10)   // LR | kitchen
        i1a.openings = [passage(atFeet: 5, widthFeet: 4)]
        var i1b = wall(12, 10, 12, 16)  // LR | hall
        i1b.openings = [door(atFeet: 3, widthFeet: 2.5)]
        var i2a = wall(12, 10, 15, 10)  // kitchen | hall
        i2a.openings = [passage(atFeet: 1.5, widthFeet: 3)]
        let i2b = wall(15, 10, 20, 10)  // kitchen | bath
        var i3 = wall(15, 10, 15, 16)   // hall | bath
        i3.openings = [door(atFeet: 3, widthFeet: 2.33)]
        var i4a = wall(0, 16, 12, 16)   // LR | bedroom
        i4a.openings = [door(atFeet: 6, widthFeet: 2.5)]
        let i4b = wall(12, 16, 13, 16)  // hall | bedroom
        let i4c = wall(13, 16, 15, 16)  // hall | closet
        let i4d = wall(15, 16, 20, 16)  // bath | closet
        var i5a = wall(13, 16, 13, 20)  // bedroom | closet
        i5a.openings = [door(atFeet: 2, widthFeet: 2)]
        var i5b = wall(13, 20, 13, 28)  // bedroom | office
        i5b.openings = [door(atFeet: 4, widthFeet: 2.5)]
        let i6 = wall(13, 20, 20, 20)   // closet | office

        let walls = [s1, s2, e1, e2, e3, e4, n1, n2, w1, w2,
                     i1a, i1b, i2a, i2b, i3, i4a, i4b, i4c, i4d, i5a, i5b, i6]

        let livingRoom = RoomShape(
            name: "Living Room", type: .livingRoom,
            polygon: polygonFeet([(0, 0), (12, 0), (12, 16), (0, 16)]),
            ceilingHeight: ceiling8, ceilingHeightSource: .sampleData,
            wallIDs: [s1.id, i1a.id, i1b.id, i4a.id, w2.id]
        )
        let kitchenRoom = RoomShape(
            name: "Kitchen", type: .kitchen,
            polygon: polygonFeet([(12, 0), (20, 0), (20, 10), (12, 10)]),
            ceilingHeight: ceiling8, ceilingHeightSource: .sampleData,
            wallIDs: [s2.id, e1.id, i2b.id, i2a.id, i1a.id]
        )
        let hall = RoomShape(
            name: "Hallway", type: .hallway,
            polygon: polygonFeet([(12, 10), (15, 10), (15, 16), (12, 16)]),
            ceilingHeight: ceiling8, ceilingHeightSource: .sampleData,
            wallIDs: [i2a.id, i3.id, i4c.id, i4b.id, i1b.id]
        )
        let bath = RoomShape(
            name: "Bathroom", type: .bathroom,
            polygon: polygonFeet([(15, 10), (20, 10), (20, 16), (15, 16)]),
            ceilingHeight: ceiling8, ceilingHeightSource: .sampleData,
            wallIDs: [i2b.id, e2.id, i4d.id, i3.id]
        )
        let bedroom = RoomShape(
            name: "Bedroom", type: .bedroom,
            polygon: polygonFeet([(0, 16), (13, 16), (13, 28), (0, 28)]),
            ceilingHeight: ceiling8, ceilingHeightSource: .sampleData,
            wallIDs: [i4a.id, i4b.id, i5a.id, i5b.id, n2.id, w1.id]
        )
        let closet = RoomShape(
            name: "Closet", type: .closet,
            polygon: polygonFeet([(13, 16), (20, 16), (20, 20), (13, 20)]),
            ceilingHeight: ceiling8, ceilingHeightSource: .sampleData,
            wallIDs: [i4c.id, i4d.id, e3.id, i6.id, i5a.id]
        )
        let office = RoomShape(
            name: twoBedroom ? "Bedroom 2" : "Office",
            type: twoBedroom ? .bedroom : .office,
            polygon: polygonFeet([(13, 20), (20, 20), (20, 28), (13, 28)]),
            ceilingHeight: ceiling8, ceilingHeightSource: .sampleData,
            wallIDs: [i6.id, e4.id, n1.id, i5b.id]
        )

        let fixtures = [
            fixture(.sofa, centerFeet: (5, 8), sizeFeet: (7, 3)),
            fixture(.table, centerFeet: (5, 12.5), sizeFeet: (4, 3), label: "Dining"),
            fixture(.cabinetBase, centerFeet: (18.9, 5), sizeFeet: (2.1, 8), label: "Base Run"),
            fixture(.refrigerator, centerFeet: (13.6, 8.4), sizeFeet: (3, 2.8)),
            fixture(.stove, centerFeet: (18.9, 1.6), sizeFeet: (2.5, 2.1)),
            fixture(.sink, centerFeet: (18.9, 7), sizeFeet: (2.1, 1.8)),
            fixture(.bathtub, centerFeet: (17.5, 15), sizeFeet: (5, 2.5), label: "Tub"),
            fixture(.toilet, centerFeet: (16, 11.5), sizeFeet: (1.6, 2.3)),
            fixture(.vanity, centerFeet: (19, 11.5), sizeFeet: (2, 1.8)),
            fixture(.bed, centerFeet: (6, 22), sizeFeet: (5, 6.6)),
        ]

        return LevelGeometry(
            name: twoBedroom ? "SAMPLE Two Bedroom" : "SAMPLE One Bedroom",
            walls: walls,
            rooms: [livingRoom, kitchenRoom, hall, bath, bedroom, closet, office],
            fixtures: fixtures
        )
    }

    /// Two-story house: first floor (living/kitchen/stairs), second floor
    /// (two bedrooms + bath). Exercises multi-level features.
    public static func multiFloorHouse() -> [LevelGeometry] {
        var first = apartment(twoBedroom: false)
        first.name = "First Floor"
        first.storyIndex = 0
        first.fixtures.append(fixture(.stairs, centerFeet: (2, 14.5), sizeFeet: (3, 10)))

        var second = apartment(twoBedroom: true)
        second.name = "Second Floor"
        second.storyIndex = 1
        // Fresh identities so the two levels don't share element IDs.
        second = reidentified(second)
        second.fixtures.append(fixture(.stairs, centerFeet: (2, 14.5), sizeFeet: (3, 10)))
        return [first, second]
    }

    /// Deep-copies a level with new UUIDs for every element.
    static func reidentified(_ level: LevelGeometry) -> LevelGeometry {
        var result = level
        result.id = UUID()
        var wallIDMap: [UUID: UUID] = [:]
        for i in result.walls.indices {
            let newID = UUID()
            wallIDMap[result.walls[i].id] = newID
            result.walls[i].id = newID
            for j in result.walls[i].openings.indices {
                result.walls[i].openings[j].id = UUID()
            }
        }
        for i in result.rooms.indices {
            result.rooms[i].id = UUID()
            result.rooms[i].wallIDs = result.rooms[i].wallIDs.compactMap { wallIDMap[$0] }
        }
        for i in result.fixtures.indices {
            result.fixtures[i].id = UUID()
        }
        return result
    }

    // MARK: - Complete sample project

    /// A complete SAMPLE project archive for development.
    public static func sampleProject() -> ProjectArchive {
        let levels = [apartment()]
        let existing = PlanSnapshot(
            name: "Existing Conditions",
            kind: .existingConditions,
            isLocked: true,
            levels: levels
        )
        var meta = ProjectMeta(name: "SAMPLE — One Bedroom Renovation")
        meta.clientName = "Sample Client"
        meta.address = "123 Sample Street"
        meta.unit = "4B"
        meta.jobType = .fullApartment
        meta.status = .measured

        let bathRoomID = levels[0].rooms.first { $0.type == .bathroom }?.id
        let measurements = [
            FieldMeasurementModel(
                name: "Tub Length", category: .tub, kind: .length,
                value: 5 * ft, source: .sampleData, isCritical: true,
                roomID: bathRoomID, levelID: levels[0].id
            ),
            FieldMeasurementModel(
                name: "Refrigerator Opening", category: .applianceOpening, kind: .width,
                value: 3 * ft, source: .sampleData, isCritical: true,
                levelID: levels[0].id
            ),
        ]

        return ProjectArchive(
            meta: meta,
            snapshots: [existing],
            activeSnapshotID: existing.id,
            measurements: measurements,
            notes: [NoteMeta(text: "SAMPLE DATA — replace flooring throughout.")]
        )
    }
}
