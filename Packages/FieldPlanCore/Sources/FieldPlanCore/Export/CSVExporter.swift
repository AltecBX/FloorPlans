import Foundation

/// CSV schedules for measurements, rooms and takeoff (spec §37).
public enum CSVExporter {

    static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\n"
    }

    // MARK: - Measurement schedule

    public static func measurementSchedule(
        _ measurements: [FieldMeasurementModel],
        roomNames: [UUID: String] = [:],
        formatter: UnitFormatter = UnitFormatter()
    ) -> String {
        var out = row([
            "Name", "Category", "Type", "Value", "Raw Meters", "Source",
            "Verification", "Critical", "Room", "Notes", "Original Value", "Updated",
        ])
        let dateFormatter = ISO8601DateFormatter()
        for m in measurements {
            out += row([
                m.name,
                m.category.displayName,
                m.kind.displayName,
                m.formattedValue(formatter),
                String(format: "%.6f", m.value),
                m.source.displayName,
                m.verification.displayName,
                m.isCritical ? "YES" : "",
                m.roomID.flatMap { roomNames[$0] } ?? "",
                m.notes,
                m.originalValue.map { formatter.length($0) } ?? "",
                dateFormatter.string(from: m.updatedAt),
            ])
        }
        return out
    }

    // MARK: - Room schedule

    public static func roomSchedule(
        levels: [LevelGeometry],
        formatter: UnitFormatter = UnitFormatter()
    ) -> String {
        var out = row([
            "Level", "Room", "Type", "Floor Area", "Ceiling Area", "Perimeter",
            "Ceiling Height", "Gross Wall Area", "Net Wall Area", "Window Area",
            "Door/Opening Area", "Base Molding", "Crown Molding", "Doors", "Windows",
        ])
        for level in levels {
            for room in level.rooms {
                let c = RoomCalculations.compute(room: room, in: level)
                out += row([
                    level.name,
                    room.name,
                    room.type.displayName,
                    formatter.area(c.floorArea),
                    formatter.area(c.ceilingArea),
                    formatter.linearFeet(c.perimeter),
                    c.ceilingHeight.map { formatter.length($0) } ?? "",
                    formatter.area(c.grossWallArea),
                    formatter.area(c.netWallArea),
                    formatter.area(c.windowArea),
                    formatter.area(c.doorAndOpeningArea),
                    formatter.linearFeet(c.baseMoldingLength),
                    formatter.linearFeet(c.crownMoldingLength),
                    String(c.doorCount),
                    String(c.windowCount),
                ])
            }
        }
        return out
    }

    // MARK: - Door and window schedule

    public static func openingSchedule(
        levels: [LevelGeometry],
        formatter: UnitFormatter = UnitFormatter()
    ) -> String {
        var out = row([
            "Mark", "Level", "Kind", "Style", "Width", "Height", "Sill",
            "Rooms", "Hand", "Swings Into", "Wall Thickness", "Status", "Source", "Evidence", "Notes",
        ])
        for r in OpeningSchedule.rows(levels: levels) {
            out += row([
                r.mark,
                r.levelName,
                r.kind.displayName,
                r.style?.displayName ?? "",
                formatter.length(r.width),
                formatter.length(r.height),
                r.kind == .window ? formatter.length(r.sillHeight) : "",
                r.rooms.joined(separator: " / "),
                r.hand ?? "",
                r.swingsInto ?? "",
                formatter.length(r.wallThickness),
                r.changeStatus.displayName,
                r.source.displayName,
                r.evidencePercent.map { "\($0)%" } ?? "",
                r.notes,
            ])
        }
        return out
    }

    // MARK: - Contractor quantities

    public static func contractorQuantities(
        levels: [LevelGeometry],
        formatter: UnitFormatter = UnitFormatter()
    ) -> String {
        var out = row([
            "Level", "Room", "Type", "Floor Area", "Ceiling Area", "Ceiling Height",
            "Paintable Wall Area", "Wall Tile Area (to 7')", "Wainscot Area (to 4')", "Volume",
            "Perimeter", "Baseboard", "Crown", "Doors", "Windows", "Openings",
            "Fixtures", "Fixtures Removed", "Wet Room",
        ])
        let summary = ContractorSummary.compute(levels: levels)
        for q in summary.rooms {
            let removed = FixtureCategory.allCases.compactMap { category -> String? in
                guard let n = q.demolishedFixtureCounts[category.rawValue], n > 0 else { return nil }
                return "\(n) \(category.displayName.lowercased())"
            }.joined(separator: ", ")
            out += row([
                q.levelName,
                q.roomName,
                q.roomType.displayName,
                formatter.area(q.floorArea),
                formatter.area(q.ceilingArea),
                q.ceilingHeight.map { formatter.length($0) } ?? "",
                formatter.area(q.paintableWallArea),
                formatter.area(q.wallTileArea),
                formatter.area(q.wainscotArea),
                formatter.volume(q.volume),
                formatter.linearFeet(q.perimeter),
                formatter.linearFeet(q.baseboardLength),
                formatter.linearFeet(q.crownLength),
                String(q.doorCount),
                String(q.windowCount),
                String(q.openingCount),
                q.fixtureSummary,
                removed,
                q.isWetRoom ? "YES" : "",
            ])
        }
        out += row([
            "TOTAL", "", "",
            formatter.area(summary.floorArea),
            formatter.area(summary.ceilingArea),
            "",
            formatter.area(summary.paintableWallArea),
            formatter.area(summary.wetWallTileArea),
            formatter.area(summary.wainscotArea),
            formatter.volume(summary.volume),
            "",
            formatter.linearFeet(summary.baseboardLength),
            formatter.linearFeet(summary.crownLength),
            String(summary.doorCount),
            String(summary.windowCount),
            "",
            summary.fixtureSummary,
            "",
            "",
        ])
        return out
    }

    // MARK: - Takeoff schedule

    public static func takeoffSchedule(_ lines: [TakeoffLine]) -> String {
        var out = row([
            "Category", "Item", "Rooms", "Base Quantity", "Unit",
            "Waste %", "Total Quantity", "Manual Override", "Notes",
        ])
        for line in lines {
            out += row([
                line.category.displayName,
                line.name,
                line.roomNames.joined(separator: "; "),
                String(format: "%.1f", line.baseQuantity),
                line.unit.displayName,
                String(format: "%.0f%%", line.wastePercent),
                String(format: "%.1f", line.totalQuantity),
                line.isManualOverride ? "YES" : "",
                line.notes,
            ])
        }
        return out
    }
}
