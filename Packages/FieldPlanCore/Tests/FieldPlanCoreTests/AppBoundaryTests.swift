import XCTest
@testable import FieldPlanCore

/// A compile fence for the app→core boundary.
///
/// The iOS layer cannot be compiled in this repository's CI environment
/// (no Xcode, no iOS SDK), so a wrong argument label or type in a call from
/// `FieldPlan/` into `FieldPlanCore` used to surface only on the owner's Mac,
/// a build cycle later. This mirrors those calls — the same labels, the same
/// types the app binds them to — so the mistake fails here instead.
///
/// It asserts almost nothing about behaviour on purpose: the other suites do
/// that. When the app starts calling something new, add the call here.
final class AppBoundaryTests: XCTestCase {

    func testCallsTheAppMakes() throws {
        var level = SampleFixtures.apartment()
        level.elevation = 0
        let levels = [level]
        let formatter = UnitFormatter()

        // ProjectStore.loadSnapshot / existingConditions
        let snapshot = PlanSnapshot(
            name: "Existing Conditions", kind: .existingConditions, isLocked: false,
            levels: [LevelGeometry(name: "First Floor", storyIndex: 0)],
            schemaVersion: GeometryMigration.currentSchemaVersion)
        let migrated = GeometryMigration.migrate(snapshot)
        let version: Int = migrated.schemaVersion ?? GeometryMigration.currentSchemaVersion
        XCTAssertEqual(version, GeometryMigration.currentSchemaVersion)

        // ScanFlowView.finishLevel
        let dtos: [ScannedRoomDTO] = []
        let groups = LevelAssignment.groupByFloor(dtos)
        for group in groups {
            let _: Double = group.elevation
            let _: [ScannedRoomDTO] = group.rooms
        }
        if let assignment = LevelAssignment.assign(
            elevation: 0, selectedLevelID: level.id, levels: levels) {
            let _: UUID = assignment.levelID
            let _: LevelGeometry? = assignment.createdLevel
            let _: String? = assignment.message
        }
        let chunks: [MeshChunk] = []
        let poses: [PoseSample] = []
        let grid = CoverageGrid.build(chunks: chunks, poses: poses, floorElevation: 0)
        let scored = EvidenceAttachment.attach(
            to: level, grid: grid, chunks: chunks,
            trackingNormalFraction: 0.9, sessionID: UUID())
        XCTAssertEqual(scored.rooms.count, level.rooms.count)
        let conversion = ScanConversion.convert(rooms: dtos)
        _ = ScanConversion.merge(conversion, into: level)
        _ = NorthEstimator.northAngle(from: [])
        _ = MissingSpaceDetector.findings(for: level, levels: levels)

        // LevelsManagerView: Align Below
        if let aligned = LevelRegistration.alignByStairs(level, to: level)
            ?? LevelRegistration.alignByFootprint(level, to: level) {
            let _: LevelGeometry = aligned.level
            let _: Double = aligned.shift.length
        }

        // PlanEditorScreen: rotate level, wall thickness, door style
        let pivot = level.bounds.isNull ? Vec2.zero : level.bounds.center
        _ = LevelRegistration.rotated(level, by: .pi / 2, about: pivot)
        if let wall = level.walls.first {
            _ = EditorEngine.setWallThickness(in: level, wallID: wall.id, thickness: 0.1524)
            let _: String? = wall.thicknessSource?.displayName
        }
        for style in DoorStyle.allCases { let _: String = style.displayName }
        if let opening = level.walls.first(where: { !$0.openings.isEmpty })?.openings.first {
            let _: DoorStyle = opening.resolvedStyle
        }

        // ManualRoomView: centerlines outside the typed clear size
        _ = GeometryOps.insetPolygon([Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)], by: -0.05715)

        // RoomDetailView / TakeoffScreen: quantities
        let q = ContractorQuantities.compute(room: level.rooms[0], in: level)
        let _: String = formatter.area(q.paintableWallArea)
        let _: String = formatter.area(q.wallTileArea)
        let _: String = formatter.area(q.wainscotArea)
        let _: String = formatter.volume(q.volume)
        let _: Int = q.fixtureTotal
        let _: String = q.fixtureSummary
        let summary = ContractorSummary.compute(levels: levels)
        let _: String = formatter.area(summary.floorArea)
        let _: String = formatter.area(summary.paintableWallArea)
        let _: String = formatter.area(summary.ceilingArea)
        let _: String = formatter.area(summary.wetWallTileArea)
        let _: String = formatter.linearFeet(summary.baseboardLength)
        let _: String = formatter.linearFeet(summary.crownLength)
        let _: String = formatter.volume(summary.volume)
        let _: Int = summary.doorCount
        let _: Int = summary.windowCount
        let _: String = summary.fixtureSummary
        let _: [ContractorQuantities] = summary.rooms

        // ReportBuilder: opening schedule page
        for r in OpeningSchedule.rows(levels: levels) {
            let _: String = r.mark
            let _: String = r.levelName
            let _: [String] = r.rooms
            let _: String = r.kind.displayName
            let _: String? = r.style?.displayName
            let _: String = "\(formatter.length(r.width)) × \(formatter.length(r.height))"
            let _: String = r.kind == .window ? formatter.length(r.sillHeight) : "—"
            let _: String? = r.hand
            let _: String? = r.swingsInto
            let _: String = r.changeStatus == .existing ? "" : r.changeStatus.displayName
            let _: String = r.notes
        }

        // ExportScreen: CSVs and OBJ
        let _: String = CSVExporter.openingSchedule(levels: levels, formatter: formatter)
        let _: String = CSVExporter.contractorQuantities(levels: levels, formatter: formatter)
        var objOptions = OBJExporter.Options()
        objOptions.mode = .existing
        objOptions.includeFixtures = true
        objOptions.includeFurniture = false
        objOptions.materialFileName = "fieldplan.mtl"
        let output = OBJExporter.export(levels: levels, options: objOptions)
        let entries = [
            ZipEntry(path: "Model.obj", data: Data(output.obj.utf8)),
            ZipEntry(path: "fieldplan.mtl", data: Data(output.mtl.utf8)),
        ]
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("m.zip")
        try ZipArchive.write(entries: entries, to: url)
        try? FileManager.default.removeItem(at: url)

        // ThreeDSceneBuilder: measured stacking
        let measured = levels.count > 1 && levels.allSatisfy { $0.elevation != nil }
        let lowest = levels.compactMap(\.elevation).min() ?? 0
        for l in levels.sorted(by: { $0.storyIndex < $1.storyIndex }) {
            let _: Double = measured ? (l.elevation ?? 0) - lowest : Double(l.storyIndex) * 3.4
        }
    }
}
