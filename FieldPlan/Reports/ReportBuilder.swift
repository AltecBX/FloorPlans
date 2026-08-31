import UIKit
import SwiftData
import FieldPlanCore

/// Client-ready PDF sections (spec §35). Every section can be toggled.
struct ReportOptions {
    var includeCover = true
    var includeProjectInfo = true
    var includeExistingPlan = true
    var includeProposedPlan = true
    var includeDemolitionPlan = false
    var includeRoomSchedule = true
    var includeMeasurements = true
    var includeTakeoff = true
    var includePhotos = true
    var includeNotes = true
    var includeVerification = true
    var includeDisclaimer = true
    var planDimensions = false
    var planFurniture = false
    /// 3D dollhouse view on the same page as each 2D plan.
    var include3D = true
}

/// Generates the professional PDF with UIGraphicsPDFRenderer. Layout is
/// US Letter; all tables paginate. Branding comes from SettingsStore —
/// nothing is hardcoded to a specific company (spec §35).
@MainActor
enum ReportBuilder {

    // US Letter, 0.66" margins.
    //
    // `nonisolated` because these are read by `Composer`, which is a nested
    // type and so does not inherit this enum's main-actor isolation. They are
    // immutable values of Sendable types, so reading them from any context is
    // safe — and saying so here is what keeps the page geometry as plain
    // constants instead of forcing Composer onto the main actor.
    nonisolated static let pageSize = CGSize(width: 612, height: 792)
    nonisolated static let margin: CGFloat = 48

    struct Fonts {
        static let title = UIFont.systemFont(ofSize: 30, weight: .bold)
        static let heading = UIFont.systemFont(ofSize: 17, weight: .semibold)
        static let body = UIFont.systemFont(ofSize: 10.5)
        static let small = UIFont.systemFont(ofSize: 8.5)
        static let tableHeader = UIFont.systemFont(ofSize: 9, weight: .semibold)
        static let table = UIFont.systemFont(ofSize: 9)
    }

    /// Page composition helper: cursor management + primitives.
    final class Composer {
        let context: UIGraphicsPDFRendererContext
        var cursor: CGFloat = ReportBuilder.margin
        var pageNumber = 0
        let footerText: String

        init(context: UIGraphicsPDFRendererContext, footerText: String) {
            self.context = context
            self.footerText = footerText
        }

        var contentWidth: CGFloat { ReportBuilder.pageSize.width - 2 * ReportBuilder.margin }
        var bottomLimit: CGFloat { ReportBuilder.pageSize.height - ReportBuilder.margin - 20 }

        func newPage() {
            context.beginPage()
            pageNumber += 1
            cursor = ReportBuilder.margin
            drawFooter()
        }

        func ensureSpace(_ height: CGFloat) {
            if cursor + height > bottomLimit {
                newPage()
            }
        }

        private func drawFooter() {
            let text = "\(footerText)  ·  Page \(pageNumber)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Fonts.small,
                .foregroundColor: UIColor.gray,
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let size = attributed.size()
            attributed.draw(at: CGPoint(
                x: (ReportBuilder.pageSize.width - size.width) / 2,
                y: ReportBuilder.pageSize.height - 30))
        }

        @discardableResult
        func text(
            _ string: String,
            font: UIFont = Fonts.body,
            color: UIColor = .black,
            x: CGFloat = ReportBuilder.margin,
            width: CGFloat? = nil,
            spacing: CGFloat = 4
        ) -> CGFloat {
            guard !string.isEmpty else { return 0 }
            let w = width ?? contentWidth
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let attributed = NSAttributedString(string: string, attributes: attributes)
            let bounds = attributed.boundingRect(
                with: CGSize(width: w, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil)
            ensureSpace(bounds.height + spacing)
            attributed.draw(in: CGRect(x: x, y: cursor, width: w, height: ceil(bounds.height)))
            cursor += ceil(bounds.height) + spacing
            return bounds.height
        }

        func heading(_ string: String) {
            ensureSpace(34)
            cursor += 6
            text(string, font: Fonts.heading, spacing: 3)
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(0.8)
            cg.move(to: CGPoint(x: ReportBuilder.margin, y: cursor))
            cg.addLine(to: CGPoint(x: ReportBuilder.pageSize.width - ReportBuilder.margin, y: cursor))
            cg.strokePath()
            cursor += 8
        }

        /// Simple column table with header repetition across pages.
        func table(headers: [String], widths: [CGFloat], rows: [[String]]) {
            let rowHeight: CGFloat = 15
            func drawRow(_ cells: [String], font: UIFont, y: CGFloat) {
                var x = ReportBuilder.margin
                for (i, cell) in cells.enumerated() {
                    let width = i < widths.count ? widths[i] : 60
                    let attributed = NSAttributedString(
                        string: cell,
                        attributes: [.font: font, .foregroundColor: UIColor.black])
                    attributed.draw(in: CGRect(x: x + 2, y: y + 2, width: width - 4, height: rowHeight - 2))
                    x += width
                }
            }
            func drawHeader() {
                ensureSpace(rowHeight * 2)
                let cg = context.cgContext
                cg.setFillColor(UIColor(white: 0.93, alpha: 1).cgColor)
                cg.fill(CGRect(x: ReportBuilder.margin, y: cursor,
                               width: widths.reduce(0, +), height: rowHeight))
                drawRow(headers, font: Fonts.tableHeader, y: cursor)
                cursor += rowHeight
            }

            drawHeader()
            for row in rows {
                if cursor + rowHeight > bottomLimit {
                    newPage()
                    drawHeader()
                }
                drawRow(row, font: Fonts.table, y: cursor)
                let cg = context.cgContext
                cg.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
                cg.setLineWidth(0.4)
                cg.move(to: CGPoint(x: ReportBuilder.margin, y: cursor + rowHeight))
                cg.addLine(to: CGPoint(x: ReportBuilder.margin + widths.reduce(0, +), y: cursor + rowHeight))
                cg.strokePath()
                cursor += rowHeight
            }
            cursor += 8
        }
    }

    // MARK: - Generation

    static func generate(
        project: ProjectRecord,
        snapshot: PlanSnapshot,
        options: ReportOptions,
        outputURL: URL
    ) throws -> URL {
        let settings = SettingsStore.shared
        let formatter = settings.formatter
        let store = ProjectStore.shared

        let pdfMeta = [
            kCGPDFContextTitle as String: "\(project.name) — Field Measurement Report",
            kCGPDFContextCreator as String: AppInfo.appName,
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMeta
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize), format: format)

        let footer = settings.reportFooter.isEmpty
            ? [settings.companyName, settings.companyPhone].filter { !$0.isEmpty }.joined(separator: "  ·  ")
            : settings.reportFooter

        // Which plan sheets this report contains, decided before drawing so the
        // 3D views can be rendered up front.
        let hasChanges = snapshot.levels.contains { level in
            level.walls.contains { $0.changeStatus != .existing }
                || level.fixtures.contains { $0.changeStatus != .existing }
        }
        var planSheets: [(mode: PlanRenderMode, title: String)] = []
        if options.includeExistingPlan { planSheets.append((.existing, "Existing Conditions")) }
        if options.includeProposedPlan && hasChanges { planSheets.append((.proposed, "Proposed Plan")) }
        if options.includeDemolitionPlan && hasChanges { planSheets.append((.demolition, "Demolition Plan")) }

        // Dollhouse snapshots are rendered here rather than inside the drawing
        // callback: Metal work does not belong in a PDF context, and the
        // renderer is main-actor isolated while the callback's local functions
        // are not. The demolition sheet is 2D only.
        var dollhouses: [PlanRenderMode: [UUID: UIImage]] = [:]
        if options.include3D {
            for sheet in planSheets where sheet.mode != .demolition {
                var byLevel: [UUID: UIImage] = [:]
                for level in snapshot.levels where !(level.walls.isEmpty && level.rooms.isEmpty) {
                    if let image = ThreeDSnapshot.render(
                        levels: [level], mode: sheet.mode, showFurniture: true) {
                        byLevel[level.id] = image
                    }
                }
                dollhouses[sheet.mode] = byLevel
            }
        }

        try renderer.writePDF(to: outputURL) { context in
            let composer = Composer(context: context, footerText: footer)

            // ---- Cover ----
            if options.includeCover {
                composer.newPage()
                composer.cursor = 120
                if let logo = settings.companyLogo {
                    let maxLogo = CGSize(width: 180, height: 90)
                    let scale = min(maxLogo.width / logo.size.width, maxLogo.height / logo.size.height, 1)
                    let logoSize = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
                    logo.draw(in: CGRect(
                        x: (pageSize.width - logoSize.width) / 2, y: composer.cursor,
                        width: logoSize.width, height: logoSize.height))
                    composer.cursor += logoSize.height + 24
                }
                if !settings.companyName.isEmpty {
                    centered(settings.companyName, font: Fonts.heading, composer: composer)
                }
                composer.cursor += 40
                centered("Field Measurement Report", font: Fonts.title, composer: composer)
                composer.cursor += 10
                centered(project.name, font: UIFont.systemFont(ofSize: 18, weight: .medium), composer: composer)
                let addressLine = [project.address, project.unit].filter { !$0.isEmpty }.joined(separator: ", ")
                if !addressLine.isEmpty {
                    centered(addressLine, font: Fonts.body, composer: composer)
                }
                if let date = project.inspectionDate {
                    centered("Inspected \(date.formatted(date: .long, time: .omitted))",
                             font: Fonts.body, composer: composer)
                }

                if let coverID = project.coverPhotoID,
                   let record = project.photos.first(where: { $0.id == coverID }),
                   let image = store.loadImage(record, projectID: project.id) {
                    composer.cursor += 24
                    let maxSize = CGSize(width: composer.contentWidth, height: 280)
                    let scale = min(maxSize.width / image.size.width, maxSize.height / image.size.height, 1)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(
                        x: (pageSize.width - size.width) / 2, y: composer.cursor,
                        width: size.width, height: size.height))
                }
            }

            // ---- Project info ----
            if options.includeProjectInfo {
                composer.newPage()
                composer.heading("Project Information")
                var pairs: [(String, String)] = [
                    ("Project", project.name),
                    ("Job Type", project.jobType.displayName),
                    ("Status", project.status.displayName),
                ]
                if !project.clientName.isEmpty { pairs.append(("Client", project.clientName)) }
                if !project.address.isEmpty {
                    pairs.append(("Address", [project.address, project.unit].filter { !$0.isEmpty }.joined(separator: ", ")))
                }
                if !project.clientPhone.isEmpty { pairs.append(("Phone", project.clientPhone)) }
                if !project.clientEmail.isEmpty { pairs.append(("Email", project.clientEmail)) }
                if let date = project.inspectionDate {
                    pairs.append(("Inspection Date", date.formatted(date: .long, time: .omitted)))
                }
                for (label, value) in pairs {
                    composer.text("\(label):  \(value)")
                }
                if !project.notes.isEmpty {
                    composer.cursor += 6
                    composer.text("Notes: \(project.notes)")
                }

                composer.heading("Property Summary")
                let stats = ProjectSummaryStats.compute(levels: snapshot.levels)
                composer.table(
                    headers: ["Metric", "Value"],
                    widths: [220, 200],
                    rows: [
                        ["Levels", "\(stats.totalLevels)"],
                        ["Rooms", "\(stats.totalRooms)"],
                        ["Total Floor Area", formatter.area(stats.totalFloorArea)],
                        ["Total Ceiling Area", formatter.area(stats.totalCeilingArea)],
                        ["Gross Wall Area", formatter.area(stats.totalWallArea)],
                        ["Net Wall Area", formatter.area(stats.totalNetWallArea)],
                        ["Baseboard", formatter.linearFeet(stats.totalBaseboardLength)],
                        ["Crown Molding", formatter.linearFeet(stats.totalCrownLength)],
                        ["Doors", "\(stats.totalDoors)"],
                        ["Windows", "\(stats.totalWindows)"],
                    ])
            }

            // ---- Plans (2D + 3D dollhouse on one page per level) ----
            func planPages(mode: PlanRenderMode, title: String) {
                var generatorOptions = PlanGenerator.Options()
                generatorOptions.mode = mode
                generatorOptions.showDimensions = options.planDimensions
                generatorOptions.showFurniture = options.planFurniture
                generatorOptions.formatter = formatter
                for level in snapshot.levels.sorted(by: { $0.storyIndex < $1.storyIndex }) {
                    guard !(level.walls.isEmpty && level.rooms.isEmpty) else { continue }
                    composer.newPage()
                    composer.heading("\(title) — \(level.name)")

                    let totalArea = level.rooms.reduce(0.0) { $0 + $1.floorArea }
                    if totalArea > 0 {
                        composer.text("Total: \(formatter.area(totalArea))",
                                      font: UIFont.systemFont(ofSize: 11, weight: .semibold))
                    }

                    let threeD = dollhouses[mode]?[level.id]

                    let available = composer.bottomLimit - composer.cursor - 16
                    let planHeight = threeD != nil ? available * 0.55 : available
                    let planRect = CGRect(
                        x: margin, y: composer.cursor,
                        width: composer.contentWidth,
                        height: planHeight)
                    let scene = PlanGenerator.scene(for: level, options: generatorOptions)
                    PlanImageRenderer.draw(scene, in: context.cgContext, rect: planRect)
                    composer.cursor = planRect.maxY + 4

                    if let threeD {
                        let maxHeight = composer.bottomLimit - composer.cursor - 14
                        let scale = min(composer.contentWidth / threeD.size.width,
                                        maxHeight / threeD.size.height)
                        if scale > 0 {
                            let size = CGSize(width: threeD.size.width * scale,
                                              height: threeD.size.height * scale)
                            threeD.draw(in: CGRect(
                                x: margin + (composer.contentWidth - size.width) / 2,
                                y: composer.cursor,
                                width: size.width, height: size.height))
                            composer.cursor += size.height + 4
                        }
                    }
                    composer.text(
                        "Fit-to-page plan — printed dimensions govern over graphic scale.",
                        font: Fonts.small, color: .gray)
                }
            }
            for sheet in planSheets {
                planPages(mode: sheet.mode, title: sheet.title)
            }

            // ---- Room schedule ----
            if options.includeRoomSchedule {
                composer.newPage()
                composer.heading("Room Schedule")
                var rows: [[String]] = []
                for level in snapshot.levels {
                    for room in level.rooms {
                        let calc = RoomCalculations.compute(room: room, in: level)
                        rows.append([
                            level.name,
                            room.name,
                            formatter.area(calc.floorArea),
                            formatter.linearFeet(calc.perimeter),
                            calc.ceilingHeight.map { formatter.length($0) } ?? "—",
                            formatter.area(calc.netWallArea),
                            "\(calc.doorCount)/\(calc.windowCount)",
                        ])
                    }
                }
                composer.table(
                    headers: ["Level", "Room", "Floor", "Perimeter", "CLG HT", "Net Wall", "Dr/Wn"],
                    widths: [70, 110, 70, 78, 62, 78, 48],
                    rows: rows)
            }

            // ---- Measurement schedule ----
            if options.includeMeasurements && !project.measurements.isEmpty {
                composer.newPage()
                composer.heading("Measurement Schedule")
                let rows = project.measurements
                    .sorted { $0.createdAt < $1.createdAt }
                    .map { record -> [String] in
                        let model = record.model
                        return [
                            model.name,
                            model.category.displayName,
                            model.formattedValue(formatter),
                            model.source.displayName,
                            model.verification.displayName,
                            model.isCritical ? "CRITICAL" : "",
                        ]
                    }
                composer.table(
                    headers: ["Measurement", "Category", "Value", "Source", "Verification", "Flag"],
                    widths: [120, 90, 78, 82, 86, 60],
                    rows: rows)
            }

            // ---- Takeoff ----
            if options.includeTakeoff && !project.takeoffItems.isEmpty {
                composer.newPage()
                composer.heading("Quantity Takeoff")
                let items = project.takeoffItems.compactMap(\.item)
                let lines = TakeoffCalculator.lines(for: items, levels: snapshot.levels)
                let rows = lines.map { line -> [String] in
                    [
                        line.category.displayName,
                        line.name,
                        String(format: "%.1f", line.baseQuantity),
                        String(format: "%.0f%%", line.wastePercent),
                        String(format: "%.1f", line.totalQuantity),
                        line.unit.displayName,
                        line.isManualOverride ? "manual" : "",
                    ]
                }
                composer.table(
                    headers: ["Category", "Item", "Base", "Waste", "Total", "Unit", ""],
                    widths: [95, 120, 55, 48, 55, 45, 50],
                    rows: rows)
                composer.text(
                    "Quantities computed from captured geometry with the waste factors shown. Not a price quote.",
                    font: Fonts.small, color: .gray)
            }

            // ---- Photos ----
            if options.includePhotos && !project.photos.isEmpty {
                composer.newPage()
                composer.heading("Photos")
                let photos = project.photos.sorted { $0.createdAt < $1.createdAt }
                let cellWidth = (composer.contentWidth - 12) / 2
                let cellHeight: CGFloat = 220
                var column = 0
                for record in photos {
                    guard let base = store.loadImage(record, projectID: project.id) else { continue }
                    let image = AnnotationDrawing.flatten(
                        image: base,
                        document: PhotoAnnotationDocument.decode(record.annotationData))
                    if composer.cursor + cellHeight > composer.bottomLimit {
                        composer.newPage()
                        composer.heading("Photos (continued)")
                        column = 0
                    }
                    let x = margin + CGFloat(column) * (cellWidth + 12)
                    let scale = min(cellWidth / image.size.width, (cellHeight - 26) / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: x, y: composer.cursor, width: size.width, height: size.height))
                    let caption = NSAttributedString(
                        string: record.caption.isEmpty
                            ? record.createdAt.formatted(date: .abbreviated, time: .shortened)
                            : record.caption,
                        attributes: [.font: Fonts.small, .foregroundColor: UIColor.darkGray])
                    caption.draw(in: CGRect(
                        x: x, y: composer.cursor + size.height + 3,
                        width: cellWidth, height: 20))
                    if column == 1 {
                        composer.cursor += cellHeight
                        column = 0
                    } else {
                        column = 1
                    }
                }
                if column == 1 { composer.cursor += cellHeight }
            }

            // ---- Notes ----
            if options.includeNotes && !project.noteRecords.isEmpty {
                composer.newPage()
                composer.heading("Field Notes")
                for note in project.noteRecords.sorted(by: { $0.createdAt < $1.createdAt }) {
                    composer.text("•  \(note.text)")
                }
            }

            // ---- Verification summary (spec §31: no accuracy claims) ----
            if options.includeVerification {
                composer.ensureSpace(160)
                composer.heading("Measurement Sources & Verification")
                let measurements = project.measurements.map(\.model)
                let critical = measurements.filter(\.isCritical)
                let unverifiedCritical = critical.filter { $0.verification == .unverified }
                var sourceCounts: [String: Int] = [:]
                for level in snapshot.levels {
                    for wall in level.walls {
                        sourceCounts[wall.source.displayName, default: 0] += 1
                    }
                }
                for m in measurements {
                    sourceCounts[m.source.displayName, default: 0] += 1
                }
                composer.table(
                    headers: ["Source", "Elements"],
                    widths: [220, 120],
                    rows: sourceCounts.sorted { $0.value > $1.value }.map { [$0.key, "\($0.value)"] })
                composer.text("Field measurements recorded: \(measurements.count)")
                composer.text("Critical dimensions: \(critical.count) — verified: \(critical.count - unverifiedCritical.count), unverified: \(unverifiedCritical.count)")
                if !unverifiedCritical.isEmpty {
                    composer.text(
                        "Unverified critical dimensions: \(unverifiedCritical.map(\.name).joined(separator: ", ")). Verify before fabrication or ordering.",
                        color: .systemRed)
                }
            }

            // ---- Disclaimer ----
            if options.includeDisclaimer && !settings.reportDisclaimer.isEmpty {
                composer.ensureSpace(80)
                composer.heading("Disclaimer")
                composer.text(settings.reportDisclaimer, font: Fonts.small, color: .darkGray)
            }

            if !settings.companyLicense.isEmpty {
                composer.text("License: \(settings.companyLicense)", font: Fonts.small, color: .darkGray)
            }
        }

        AppLog.export.info("Report generated at \(outputURL.lastPathComponent, privacy: .public)")
        return outputURL
    }

    private static func centered(_ string: String, font: UIFont, composer: Composer) {
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: UIColor.black])
        let size = attributed.size()
        composer.ensureSpace(size.height + 6)
        attributed.draw(at: CGPoint(x: (pageSize.width - size.width) / 2, y: composer.cursor))
        composer.cursor += size.height + 6
    }
}
