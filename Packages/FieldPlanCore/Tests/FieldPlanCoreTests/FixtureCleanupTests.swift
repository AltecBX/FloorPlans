import XCTest
@testable import FieldPlanCore

final class FixtureCleanupTests: XCTestCase {

    private func storage(bottom: Double, height: Double, x: Double, z: Double) -> ScannedObjectDTO {
        ScannedObjectDTO(categoryName: "storage", center: Vec3(1, bottom + height / 2, -1),
                         xAxis: Vec3(1, 0, 0), dimensions: Vec3(x, height, z), confidenceLevel: 2)
    }

    func testStorageIsReadFromItsBox() {
        XCTAssertEqual(FixtureCleanup.storageCategory(storage(bottom: 1.4, height: 0.7, x: 0.9, z: 0.35), floorY: 0), .cabinetUpper)
        XCTAssertEqual(FixtureCleanup.storageCategory(storage(bottom: 0.0, height: 0.9, x: 1.2, z: 0.6), floorY: 0), .cabinetBase)
        XCTAssertEqual(FixtureCleanup.storageCategory(storage(bottom: 0.0, height: 2.0, x: 1.0, z: 0.6), floorY: 0), .storage,
                       "a tall pantry stays storage")
        // The floor is not at world zero: heights are read from the floor.
        XCTAssertEqual(FixtureCleanup.storageCategory(storage(bottom: -1.4 + 1.5, height: 0.7, x: 0.9, z: 0.35), floorY: -1.4), .cabinetUpper)
    }

    func testRunsJoinAndIslandsAreFound() {
        func base(_ x: Double, _ y: Double, length: Double = 1.0, rotation: Double = 0) -> FixtureItem {
            FixtureItem(category: .cabinetBase, center: Vec2(x, y), size: Vec2(length, 0.6), rotation: rotation,
                        height: 0.9, source: .lidarScanned, confidence: .high)
        }
        // A wall along y = 0; two cabinets end to end against it, a third
        // continuing after a 10 cm gap, one standing in the middle of the room.
        let wall = Wall(start: Vec2(0, 0), end: Vec2(6, 0), source: .lidarScanned)
        let fixtures = [
            base(1.0, 0.3), base(2.05, 0.3), base(3.15, 0.3),
            base(4.0, 2.5, length: 1.8),
            FixtureItem(category: .cabinetBase, center: Vec2(5.5, 0.3), size: Vec2(0.6, 0.6), source: .manualEntry),
        ]
        let cleaned = FixtureCleanup.mergeCabinetRuns(fixtures, walls: [wall])
        let runs = cleaned.filter { $0.category == .cabinetBase && $0.source == .lidarScanned }
        XCTAssertEqual(runs.count, 1, "three boxes became one run")
        XCTAssertEqual(runs[0].size.x, 3.15 + 0.5 - 0.5, accuracy: 1e-9, "from 0.5 to 3.65")
        XCTAssertEqual(runs[0].center.x, (0.5 + 3.65) / 2, accuracy: 1e-9)
        XCTAssertEqual(runs[0].size.y, 0.6, accuracy: 1e-9)
        let islands = cleaned.filter { $0.category == .island }
        XCTAssertEqual(islands.count, 1)
        XCTAssertEqual(islands[0].center, Vec2(4.0, 2.5))
        XCTAssertEqual(cleaned.filter { $0.source == .manualEntry }.count, 1, "hand-placed pieces are left alone")
    }

    func testRunsDoNotJoinAcrossACornerOrAWideGap() {
        func base(_ x: Double, _ y: Double, rotation: Double = 0) -> FixtureItem {
            FixtureItem(category: .cabinetBase, center: Vec2(x, y), size: Vec2(1.0, 0.6), rotation: rotation,
                        source: .lidarScanned)
        }
        let walls = [Wall(start: Vec2(0, 0), end: Vec2(6, 0)), Wall(start: Vec2(0, 0), end: Vec2(0, 4))]
        let cleaned = FixtureCleanup.mergeCabinetRuns(
            [base(1.0, 0.3), base(0.3, 1.2, rotation: .pi / 2), base(3.0, 0.3)], walls: walls)
        XCTAssertEqual(cleaned.filter { $0.category == .cabinetBase }.count, 3)
    }
}
