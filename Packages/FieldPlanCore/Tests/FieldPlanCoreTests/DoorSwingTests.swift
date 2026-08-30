import XCTest
@testable import FieldPlanCore

/// A scan cannot see hinges, so the swing is derived. These lock the rules a
/// drafter applies, because a plan that swings a door the wrong way is worse
/// than one that shows no swing at all.
final class DoorSwingTests: XCTestCase {

    /// Every door in the sample apartment, and the room its leaf must open into.
    func testSampleApartmentSwingsFollowTheRules() {
        let level = SampleFixtures.apartment()
        var openInto: [String: String] = [:]

        for wall in level.walls {
            for opening in wall.openings where opening.kind == .door {
                let swing = DoorSwingInference.swing(for: opening, on: wall, in: level)
                let perpendicular = wall.direction.perpendicular
                let center = wall.start + wall.direction * opening.centerOffset
                let reach = wall.thickness / 2 + DoorSwingInference.probeDistance
                let side = swing.opensPositiveSide ? perpendicular : -perpendicular
                let room = level.rooms.first {
                    GeometryOps.polygonContains($0.polygon, center + side * reach)
                }
                let key = level.rooms
                    .filter { room in
                        [perpendicular, -perpendicular].contains { probe in
                            GeometryOps.polygonContains(room.polygon, center + probe * reach)
                        }
                    }
                    .map(\.name).sorted().joined(separator: "/")
                openInto[key] = room?.name ?? "outside"
            }
        }

        // Front door swings in, not out onto the landing.
        XCTAssertEqual(openInto["Living Room"], "Living Room")
        // Never back into the circulation space.
        XCTAssertEqual(openInto["Hallway/Living Room"], "Living Room")
        XCTAssertEqual(openInto["Bathroom/Hallway"], "Bathroom")
        // Between two rooms, into the smaller/more private one.
        XCTAssertEqual(openInto["Bedroom/Living Room"], "Bedroom")
        XCTAssertEqual(openInto["Bedroom/Office"], "Office")
        // Out of a closet — there is no floor inside for a leaf.
        XCTAssertEqual(openInto["Bedroom/Closet"], "Bedroom")
    }

    func testExteriorDoorSwingsInward() {
        let level = SampleFixtures.rectangularRoom(widthFeet: 12, depthFeet: 12,
                                                   name: "Room", type: .livingRoom)
        var wall = level.walls[0]
        let opening = WallOpening(kind: .door, centerOffset: wall.length / 2,
                                  width: 0.9, height: 2.0, sillHeight: 0)
        wall.openings = [opening]
        var edited = level
        edited.walls[0] = wall

        let swing = DoorSwingInference.swing(for: opening, on: wall, in: edited)
        let side = swing.opensPositiveSide ? wall.direction.perpendicular : -wall.direction.perpendicular
        let probe = wall.midpoint + side * (wall.thickness / 2 + DoorSwingInference.probeDistance)
        XCTAssertTrue(GeometryOps.polygonContains(edited.rooms[0].polygon, probe),
                      "an exterior door must open into the room")
    }

    /// The scan pipeline must not invent a swing — that is what made every door
    /// on a scanned plan hinge the same way regardless of the room around it.
    func testScanConversionLeavesSwingUnset() {
        let wall = ScannedSurfaceDTO(
            kind: .wall, center: Vec3(2, 1.25, 0), xAxis: Vec3(1, 0, 0),
            width: 4, height: 2.5, confidenceLevel: 2)
        let door = ScannedSurfaceDTO(
            kind: .door, center: Vec3(2, 1.0, 0), xAxis: Vec3(1, 0, 0),
            width: 0.9, height: 2.0, confidenceLevel: 2)
        let converted = ScanConversion.convert(rooms: [
            ScannedRoomDTO(suggestedName: "Room", suggestedType: nil,
                           surfaces: [wall, door], objects: [])
        ])
        let openings = converted.walls.flatMap(\.openings).filter { $0.kind == .door }
        XCTAssertFalse(openings.isEmpty, "expected the scanned door to convert")
        XCTAssertTrue(openings.allSatisfy { $0.swing == nil },
                      "a scan cannot see hinges; the swing must stay derivable")
    }

    func testPlanDrawsTheDerivedSwingSide() {
        // The generator resolves swings before emitting, so the arc lands on the
        // side the rules chose rather than on a fixed default.
        let level = SampleFixtures.apartment()
        let resolved = DoorSwingInference.resolvingSwings(in: level)
        XCTAssertTrue(
            resolved.walls.flatMap(\.openings).filter { $0.kind == .door }.allSatisfy { $0.swing != nil },
            "every door should carry a resolved swing")
        // Hand-set swings survive resolution.
        var handSet = level
        for wallIndex in handSet.walls.indices {
            for openingIndex in handSet.walls[wallIndex].openings.indices
            where handSet.walls[wallIndex].openings[openingIndex].kind == .door {
                handSet.walls[wallIndex].openings[openingIndex].swing =
                    DoorSwing(hingeAtStart: false, opensPositiveSide: false)
            }
        }
        let afterResolve = DoorSwingInference.resolvingSwings(in: handSet)
        XCTAssertTrue(
            afterResolve.walls.flatMap(\.openings).filter { $0.kind == .door }
                .allSatisfy { $0.swing == DoorSwing(hingeAtStart: false, opensPositiveSide: false) },
            "a hand-set swing must never be overwritten")
    }
}
