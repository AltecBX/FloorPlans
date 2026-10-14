import XCTest
@testable import FieldPlanCore

/// Fixes for the problems the owner reported from the phone: a hallway typed
/// as a closet, and every room carrying its size twice.
final class PlanReadabilityTests: XCTestCase {

    private let ft = UnitConstants.metersPerFoot

    // MARK: Hallway versus closet

    func testWalkedThroughSpaceIsAHallwayNotACloset() {
        // Same small empty space; the only difference is a second way out.
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: [], floorArea: 2.3, doorwayCount: 1), .closet)
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: [], floorArea: 2.3, doorwayCount: 3), .hallway)
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: [], floorArea: 2.3, doorwayCount: 2), .hallway)
        // With the doorways unknown, a long thin space still reads as a corridor.
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: [], floorArea: 2.3, narrowness: 3.5), .hallway)
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: [], floorArea: 2.3, narrowness: 1.2), .closet)
        // A reach-in closet stays a closet: one door, roughly square.
        XCTAssertEqual(ScanConversion.inferRoomType(objectNames: ["storage"], floorArea: 2.0, doorwayCount: 1), .closet)
        // Big rooms are unaffected.
        XCTAssertNil(ScanConversion.inferRoomType(objectNames: [], floorArea: 20, doorwayCount: 1))
    }

    func testSplitRoomsTypeTheThroughSpaceAsHallway() {
        // A 2.4 m x 1.2 m space between two rooms, with a doorway at each end,
        // is the hallway that used to come back as a closet.
        func wall(_ a: Vec2, _ b: Vec2) -> Wall {
            Wall(start: a, end: b, height: 2.44, thickness: 0.1,
                 source: .lidarScanned, thicknessSource: .assumed)
        }
        var walls = [
            wall(Vec2(0, 0), Vec2(6, 0)), wall(Vec2(6, 0), Vec2(6, 5)),
            wall(Vec2(6, 5), Vec2(0, 5)), wall(Vec2(0, 5), Vec2(0, 0)),
            wall(Vec2(0, 1.9), Vec2(6, 1.9)),
            wall(Vec2(0, 3.1), Vec2(6, 3.1)),
        ]
        // A door at each end of the middle strip: you walk through it.
        walls[4].openings = [WallOpening(kind: .door, centerOffset: 1.0, width: 0.8, height: 2.03)]
        walls[5].openings = [WallOpening(kind: .door, centerOffset: 5.0, width: 0.8, height: 2.03)]
        let whole = RoomShape(name: "Scan", polygon: [Vec2(0, 0), Vec2(6, 0), Vec2(6, 5), Vec2(0, 5)],
                              wallIDs: walls.map(\.id))
        let split = ScanConversion.splitIntoRooms(LevelGeometry(name: "L", walls: walls, rooms: [whole]))
        XCTAssertEqual(split.rooms.count, 3)
        let middle = split.rooms.min { $0.floorArea < $1.floorArea }
        XCTAssertEqual(middle?.type, .hallway, "the strip with a door at each end")
    }

    // MARK: One statement of a room's size, not two

    func testRoomSizeIsStatedOnceOnThePlan() {
        var level = SampleFixtures.rectangularRoom(widthFeet: 13, depthFeet: 10, name: "Bedroom", type: .bedroom)
        // An L-shaped room, which used to draw interior chains as well as
        // carrying its size in the label.
        let w = 13 * ft, d = 10 * ft
        level.rooms[0].polygon = [Vec2(0, 0), Vec2(w, 0), Vec2(w, d * 0.6),
                                  Vec2(w * 0.6, d * 0.6), Vec2(w * 0.6, d), Vec2(0, d)]
        var options = PlanGenerator.Options()
        options.showDimensions = true
        options.showRoomLabels = true
        options.showRoomDimensions = true

        func texts(_ scene: PlanScene, _ layer: PlanLayerKind) -> [String] {
            scene.layer(layer)?.primitives.compactMap {
                if case .text(let s, _, _, _, _, _) = $0 { return s }
                return nil
            } ?? []
        }

        let scene = PlanGenerator.scene(for: level, options: options)
        let labels = texts(scene, .labels)
        let dims = texts(scene, .dimensions)
        XCTAssertTrue(labels.contains { $0.contains(" x ") }, "the label states the size: \(labels)")
        // Only the overall extents outside the plan — no per-edge chain
        // repeating what the label already says.
        XCTAssertEqual(dims.count, 2, "\(dims)")

        // Turn the label's size off and the chains come back for the drawing
        // that goes to a trade.
        options.showRoomDimensions = false
        XCTAssertGreaterThan(texts(PlanGenerator.scene(for: level, options: options), .dimensions).count, 2)
    }

    func testRoomLabelsAreHorizontalWhereverTheyFit() {
        // Sideways text is harder to read, so a room that can hold its label
        // lying down always gets it that way. Every room in the sample
        // apartment can, so nothing here is turned.
        let level = SampleFixtures.apartment()
        var options = PlanGenerator.Options()
        options.showRoomLabels = true
        let scene = PlanGenerator.scene(for: level, options: options)
        for primitive in scene.layer(.labels)?.primitives ?? [] {
            if case .text(let string, _, _, let rotation, _, _) = primitive {
                XCTAssertEqual(rotation, 0, accuracy: 1e-12, "\"\(string)\" is not horizontal")
            }
        }
    }
}
