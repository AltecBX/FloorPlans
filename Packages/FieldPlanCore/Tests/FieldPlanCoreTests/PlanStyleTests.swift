import XCTest
@testable import FieldPlanCore

// MARK: - How the plan reads (listing-sheet styling)
//
// The look a floor plan is expected to have: the room's name set as written,
// its size under it in the tight form, sleeping areas warm and wet areas cool,
// and labels that sit on clear floor rather than across a wall or a bathtub.

final class PlanStyleTests: XCTestCase {

    private func labels(_ scene: PlanScene) -> [(text: String, at: Vec2, rotation: Double)] {
        (scene.layer(.labels)?.primitives ?? []).compactMap {
            if case .text(let s, let p, _, let r, _, _) = $0 { return (s, p, r) }
            return nil
        }
    }

    // MARK: The size line

    func testRoomSizeUsesTheTightFloorPlanForm() {
        let formatter = UnitFormatter()
        // 14'0" x 12'5" — whole inches, lowercase x, no space inside the feet.
        XCTAssertEqual(formatter.roomDimensions(14 * 0.3048, 12 * 0.3048 + 5 * 0.0254),
                       "14'0\" x 12'5\"")
        // An eighth of an inch is noise on a room label: it rounds away.
        XCTAssertEqual(formatter.roomDimension(12 * 0.3048 + 5.44 * 0.0254), "12'5\"")
        // 11.6 inches rounds up and carries into the next foot.
        XCTAssertEqual(formatter.roomDimension(11.6 * 0.0254 + 3 * 0.3048), "4'0\"")
    }

    func testMetricRoomSizeMatchesTheMetricSheet() {
        let formatter = UnitFormatter(system: .meters)
        XCTAssertEqual(formatter.roomDimensions(4.284, 3.792), "4.28 m x 3.79 m")
    }

    func testTheLabelCarriesTheNameAsWrittenAndItsSize() {
        let level = SampleFixtures.rectangularRoom(
            widthFeet: 14, depthFeet: 12, name: "Primary Bedroom", type: .bedroom)
        let texts = labels(PlanGenerator.scene(for: level)).map(\.text)
        XCTAssertTrue(texts.contains("Primary Bedroom"), "\(texts)")
        XCTAssertTrue(texts.contains("14'0\" x 12'0\""), "\(texts)")
    }

    func testUppercaseIsAvailableForADrawingIssuedToATrade() {
        let level = SampleFixtures.rectangularRoom(
            widthFeet: 14, depthFeet: 12, name: "Primary Bedroom", type: .bedroom)
        var options = PlanGenerator.Options()
        options.roomNameStyle = .uppercase
        let texts = labels(PlanGenerator.scene(for: level, options: options)).map(\.text)
        XCTAssertTrue(texts.contains("PRIMARY BEDROOM"), "\(texts)")
    }

    // MARK: Colour

    func testListingPaletteWarmsBedroomsAndCoolsWetRooms() {
        let palette = RoomPalette.staging
        XCTAssertEqual(palette.tint(for: .bedroom).hex, "#EFD3BD")
        // Bath and laundry are the same cool tint — both are wet rooms.
        XCTAssertEqual(palette.tint(for: .bathroom).hex, palette.tint(for: .laundry).hex)
        XCTAssertEqual(palette.tint(for: .powderRoom).hex, palette.tint(for: .bathroom).hex)
    }

    func testListingPaletteKeepsTheOpenPlanOneColour() {
        // Colouring a kitchen differently from the dining room beside it makes
        // an open plan look partitioned. On a listing sheet they match.
        let palette = RoomPalette.staging
        let cream = palette.tint(for: .livingRoom).hex
        for type in [RoomType.kitchen, .diningRoom, .familyRoom, .hallway, .foyer, .office] {
            XCTAssertEqual(palette.tint(for: type).hex, cream, "\(type) should share the cream")
        }
        // Outdoor space and the garage still stand apart.
        XCTAssertNotEqual(palette.tint(for: .balcony).hex, cream)
        XCTAssertNotEqual(palette.tint(for: .garage).hex, cream)
    }

    func testByRoomTypeIsStillAvailableForWorkingOnThePlan() {
        XCTAssertNotEqual(RoomPalette.byCategory.tint(for: .kitchen).hex,
                          RoomPalette.byCategory.tint(for: .livingRoom).hex)
    }

    func testTheGeneratorResolvesTheColourSoEveryRendererAgrees() {
        let level = SampleFixtures.rectangularRoom(
            widthFeet: 12, depthFeet: 10, name: "Bedroom", type: .bedroom)
        var options = PlanGenerator.Options()
        options.roomPalette = .staging
        let fills = (PlanGenerator.scene(for: level, options: options).layer(.roomFills)?.primitives ?? [])
            .compactMap { primitive -> PlanColor? in
                if case .polygon(_, .roomTint(let color), _) = primitive { return color }
                return nil
            }
        XCTAssertEqual(fills.first?.hex, RoomPalette.staging.tint(for: .bedroom).hex)
    }

    // MARK: Turning a label only when it will not fit

    func testAWideRoomKeepsItsLabelHorizontal() {
        let level = SampleFixtures.rectangularRoom(
            widthFeet: 14, depthFeet: 12, name: "Bedroom", type: .bedroom)
        for label in labels(PlanGenerator.scene(for: level)) {
            XCTAssertEqual(label.rotation, 0, accuracy: 1e-12, "\"\(label.text)\" should lie down")
        }
    }

    func testATallNarrowRoomTurnsItsLabelInsteadOfCrossingTheWall() {
        // A galley bath: 4' wide, 13' deep. "Primary Bath" cannot be read
        // across four feet at any useful size, so it reads bottom-to-top —
        // which is what a floor plan does with a room this shape.
        let level = SampleFixtures.rectangularRoom(
            widthFeet: 4, depthFeet: 13, name: "Primary Bath", type: .bathroom)
        let name = labels(PlanGenerator.scene(for: level)).first { $0.text == "Primary Bath" }
        XCTAssertNotNil(name, "the room is labelled")
        XCTAssertEqual(name?.rotation ?? 0, .pi / 2, accuracy: 1e-9,
                       "a room this narrow turns its label rather than overrunning the wall")
    }

    func testATurnedLabelStaysInsideItsRoom() {
        let level = SampleFixtures.rectangularRoom(
            widthFeet: 4, depthFeet: 13, name: "Primary Bath", type: .bathroom)
        let bounds = level.rooms[0].bounds
        for label in labels(PlanGenerator.scene(for: level)) {
            XCTAssertGreaterThan(label.at.x, bounds.minX, "\"\(label.text)\" ran out of the room")
            XCTAssertLessThan(label.at.x, bounds.maxX, "\"\(label.text)\" ran out of the room")
        }
    }

    // MARK: Labels and fixtures

    func testAnUndrawnBedDoesNotShoveTheBedroomLabelIntoAWall() {
        // Furniture is off by default. It must not move a label that nothing
        // on the sheet is actually covering.
        var level = SampleFixtures.rectangularRoom(
            widthFeet: 14, depthFeet: 12, name: "Bedroom", type: .bedroom)
        let room = level.rooms[0]
        level.fixtures.append(FixtureItem(
            category: .bed, center: room.labelPoint, size: Vec2(1.5, 2.0),
            rotation: 0, roomID: room.id))

        var options = PlanGenerator.Options()
        options.showFurniture = false
        let placed = PlanGenerator.labelAnchor(for: room, in: level, options: options)
        XCTAssertEqual(placed.point.x, room.labelPoint.x, accuracy: 1e-9)
        XCTAssertEqual(placed.point.y, room.labelPoint.y, accuracy: 1e-9)

        // Turn furniture on and the same bed does move it.
        options.showFurniture = true
        let avoided = PlanGenerator.labelAnchor(for: room, in: level, options: options)
        XCTAssertGreaterThan(avoided.point.distance(to: room.labelPoint), 0.1)
    }

    func testALabelMovesOffABathtub() {
        var level = SampleFixtures.rectangularRoom(
            widthFeet: 10, depthFeet: 8, name: "Bath", type: .bathroom)
        let room = level.rooms[0]
        level.fixtures.append(FixtureItem(
            category: .bathtub, center: room.labelPoint, size: Vec2(1.7, 0.8),
            rotation: 0, roomID: room.id))

        let placed = PlanGenerator.labelAnchor(for: room, in: level, options: PlanGenerator.Options())
        XCTAssertGreaterThan(placed.clearance, 0.2, "the label found clear floor")
        XCTAssertTrue(GeometryOps.polygonContains(room.polygon, placed.point),
                      "and stayed inside its own room")
    }

    func testACrowdedRoomDropsExtraLinesRatherThanStackingOverFixtures() {
        // A small bath packed with fixtures: the name and the size are worth
        // printing, a third line over the tub is not.
        var level = SampleFixtures.rectangularRoom(
            widthFeet: 6, depthFeet: 5, name: "Bath", type: .bathroom)
        let room = level.rooms[0]
        let centre = room.bounds.center
        level.fixtures.append(FixtureItem(category: .bathtub, center: Vec2(centre.x, centre.y + 0.5),
                                          size: Vec2(1.7, 0.75), rotation: 0, roomID: room.id))
        level.fixtures.append(FixtureItem(category: .toilet, center: Vec2(centre.x - 0.5, centre.y - 0.4),
                                          size: Vec2(0.4, 0.7), rotation: 0, roomID: room.id))
        level.fixtures.append(FixtureItem(category: .sink, center: Vec2(centre.x + 0.5, centre.y - 0.4),
                                          size: Vec2(0.5, 0.5), rotation: 0, roomID: room.id))

        var options = PlanGenerator.Options()
        options.showCeilingHeights = true
        let texts = labels(PlanGenerator.scene(for: level, options: options)).map(\.text)
        XCTAssertTrue(texts.contains("Bath"), "the room is still named: \(texts)")
        XCTAssertFalse(texts.contains { $0.hasPrefix("Ceiling") },
                       "a crowded room drops the ceiling line: \(texts)")
    }

    func testAnEmptyRoomStillCarriesEveryLineItAsksFor() {
        let level = SampleFixtures.rectangularRoom(
            widthFeet: 16, depthFeet: 13, name: "Living Room", type: .livingRoom)
        var options = PlanGenerator.Options()
        options.showCeilingHeights = true
        options.showAreaLabels = true
        let texts = labels(PlanGenerator.scene(for: level, options: options)).map(\.text)
        XCTAssertTrue(texts.contains("Living Room"), "\(texts)")
        XCTAssertTrue(texts.contains("16'0\" x 13'0\""), "\(texts)")
        XCTAssertTrue(texts.contains { $0.hasPrefix("Ceiling") }, "\(texts)")
    }
}

// MARK: - The area block under the sheet

final class PlanAreaSummaryTests: XCTestCase {

    private func level(_ name: String, _ storyIndex: Int, squareFeet: Double) -> LevelGeometry {
        let side = (squareFeet * UnitConstants.squareMetersPerSquareFoot).squareRoot()
        var level = LevelGeometry(name: name, storyIndex: storyIndex)
        level.rooms = [RoomShape(
            name: "Room", polygon: [Vec2(0, 0), Vec2(side, 0), Vec2(side, side), Vec2(0, side)])]
        return level
    }

    func testASingleFloorReportsOneTotal() {
        let lines = PlanAreaSummary.lines(levels: [level("1st Floor", 0, squareFeet: 842)])
        XCTAssertEqual(lines, ["Measured Floor Area: 842 sq ft"])
    }

    func testEveryFloorIsListedUnderTheTotalLowestFirst() {
        let lines = PlanAreaSummary.lines(levels: [
            level("1st Floor", 0, squareFeet: 842),
            level("Basement", -1, squareFeet: 613),
        ])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Measured Floor Area: 1,455 sq ft")
        XCTAssertEqual(lines[1], "Basement: 613 sq ft  ·  1st Floor: 842 sq ft")
    }

    func testAnEmptyPlanClaimsNoArea() {
        XCTAssertTrue(PlanAreaSummary.lines(levels: []).isEmpty)
        XCTAssertTrue(PlanAreaSummary.lines(levels: [LevelGeometry(name: "Empty")]).isEmpty)
    }

    func testSheetAreasAreWholeUnitsWithThousandsSeparated() {
        let formatter = UnitFormatter()
        XCTAssertEqual(formatter.sheetArea(1455.4 * UnitConstants.squareMetersPerSquareFoot), "1,455 sq ft")
        XCTAssertEqual(formatter.sheetArea(94.6 * UnitConstants.squareMetersPerSquareFoot), "95 sq ft")
        XCTAssertEqual(UnitFormatter(system: .meters).sheetArea(135.2), "135 m²")
        // The takeoff keeps its tenth — only the sheet rounds.
        XCTAssertEqual(formatter.area(94.6 * UnitConstants.squareMetersPerSquareFoot), "94.6 sq ft")
    }
}
