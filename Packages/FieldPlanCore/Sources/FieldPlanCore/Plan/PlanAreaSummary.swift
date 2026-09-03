import Foundation

/// The area block printed under a floor plan sheet: the measured total, then
/// each floor that contributed to it.
///
/// It reports the floor area FieldPlan measured and nothing more. A listing
/// sheet often carries an "excluded areas" line under the total — garage,
/// utility, below-grade — but deciding what counts is what ANSI Z765 is for,
/// and FieldPlan implements none of it. Printing an exclusion it did not
/// compute would be the same unfounded claim as calling this figure GLA.
public enum PlanAreaSummary {

    /// One line per floor, plus the total when there is more than one.
    public static func lines(
        levels: [LevelGeometry],
        formatter: UnitFormatter = UnitFormatter()
    ) -> [String] {
        let ordered = levels.sorted { $0.storyIndex < $1.storyIndex }
        let areas = ordered.map { level in
            (name: level.name, area: level.rooms.reduce(0.0) { $0 + $1.floorArea })
        }
        let total = areas.reduce(0.0) { $0 + $1.area }
        guard total > 0 else { return [] }

        var lines = ["Measured Floor Area: \(formatter.sheetArea(total))"]
        if areas.count > 1 {
            lines.append(areas
                .map { "\($0.name): \(formatter.sheetArea($0.area))" }
                .joined(separator: "  ·  "))
        }
        return lines
    }
}
