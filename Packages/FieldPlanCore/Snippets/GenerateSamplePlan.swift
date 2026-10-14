// Emits the SAMPLE one-bedroom apartment's generated artifacts so the plan
// generator and exporters can be inspected without a device:
//
//   swift run GenerateSamplePlan [output-directory]
//
// Writes: sample-existing.svg, sample-demolition.svg, sample-existing.dxf,
// sample-rooms.csv, sample-project.json, sample.fieldplan
import Foundation
import FieldPlanCore

let outputDir = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".",
    isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

var level = SampleFixtures.apartment()

// Give the demolition/proposed views something to show: open the kitchen to
// the living room and mark a closet wall as new construction.
if let partition = level.walls.first(where: { wall in
    wall.openings.contains { $0.kind == .opening }
}) {
    level = EditorEngine.setWallChangeStatus(in: level, wallID: partition.id, status: .demolish)
}
level.northAngle = 0.35

let formatter = UnitFormatter()
var options = PlanGenerator.Options()
options.formatter = formatter
options.showCeilingHeights = true   // exercise the new label line

func write(_ text: String, _ name: String) throws {
    let url = outputDir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url, options: .atomic)
    print("wrote \(url.path)")
}

// SVG — existing conditions and demolition plan.
let stats = ProjectSummaryStats.compute(levels: [level])
let totalArea = formatter.sheetArea(stats.totalFloorArea)
options.titleBlock = PlanTitleBlock(
    style: .centered,
    summaryLines: PlanAreaSummary.lines(levels: [level], formatter: formatter),
    projectName: "SAMPLE Apartment",
    address: "123 Main Street, Apt 4B, Brooklyn NY 11201",
    planTitle: "Existing Conditions — \(level.name)",
    totalArea: totalArea,
    dateText: "August 30, 2026",
    preparedBy: "Jerry's Renovations",
    contact: "(555) 010-0100  ·  Lic. #123456",
    note: "SAMPLE DATA — not a field measurement")

options.mode = .existing
let existingScene = PlanGenerator.scene(for: level, options: options)
try write(SVGExporter.svg(for: existingScene), "sample-existing.svg")

options.mode = .demolition
options.titleBlock?.planTitle = "Demolition Plan — \(level.name)"
let demoScene = PlanGenerator.scene(for: level, options: options)
try write(SVGExporter.svg(for: demoScene), "sample-demolition.svg")

// DXF — existing conditions.
try write(DXFExporter.dxf(for: existingScene), "sample-existing.dxf")

// CSV room schedule.
try write(CSVExporter.roomSchedule(levels: [level], formatter: formatter), "sample-rooms.csv")

// JSON archive + .fieldplan package round-trip.
let archive = SampleFixtures.sampleProject()
let json = try archive.jsonData()
try json.write(to: outputDir.appendingPathComponent("sample-project.json"), options: .atomic)
print("wrote \(outputDir.appendingPathComponent("sample-project.json").path)")

let package = ZipArchive.archiveData(entries: [
    ZipEntry(path: "project.json", data: json)
])
try package.write(to: outputDir.appendingPathComponent("sample.fieldplan"), options: .atomic)
print("wrote \(outputDir.appendingPathComponent("sample.fieldplan").path)")

// Sanity summary.
print(String(format: "rooms: %d  floor: %@  QA findings: %d",
             stats.totalRooms,
             formatter.area(stats.totalFloorArea),
             QAEngine.evaluate(level: level).count))
