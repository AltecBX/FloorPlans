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
