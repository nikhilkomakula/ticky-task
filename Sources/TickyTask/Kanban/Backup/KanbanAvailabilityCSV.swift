import Foundation

/// Long-form CSV export of a board's resource availability by week.
enum KanbanAvailabilityCSV {
    /// Generate CSV rows for availability data.
    /// - Parameters:
    ///   - project: The board to export.
    ///   - weeks: Array of week-start days (Mondays) to include, in order.
    ///   - calendar: Calendar to use for calculations.
    /// - Returns: RFC 4180 formatted CSV with CRLF line endings.
    @MainActor
    static func csv(_ project: KanbanProject, weeks: [KanbanDay], calendar: Calendar) -> String {
        let header = [
            "Board ID", "Board", "Person ID", "Person", "Membership ID",
            "Week Start", "Week End", "Possible Days", "Computed Days", "Override Days", "Effective Days",
            "Allocation %", "Status"
        ]

        var rows: [[String]] = []
        let board = KanbanAvailability.Board(project)

        for resource in project.resources.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            let person = resource.person
            guard person?.archivedAt == nil else { continue }

            let member = KanbanAvailability.Member(resource, calendar: calendar)

            for week in weeks {
                let weekEnd = week.adding(days: 6)
                let cell = KanbanAvailability.cell(week: week, board: board, member: member)
                let possible = cell.possibleHalfDays
                let computed = cell.computedHalfDays
                let effective = cell.effectiveHalfDays

                let status: String
                if !cell.isActive {
                    status = "no work days"
                } else if cell.overrideNeedsReview {
                    status = "override needs review"
                } else if resource.archivedAt != nil {
                    status = "archived membership"
                } else {
                    status = "active"
                }

                let allocPercent = Double(resource.allocationPercent) * Double(effective) / Double(max(possible, 1)) / 100.0
                let allocationStr = String(format: "%.1f", allocPercent)
                let row = [
                    project.id.uuidString,
                    project.name,
                    person?.id.uuidString ?? "",
                    person?.name ?? "Unknown",
                    resource.id.uuidString,
                    week.key,
                    weekEnd.key,
                    formatDays(possible),
                    formatDays(computed),
                    cell.overrideHalfDays.map { formatDays($0) } ?? "—",
                    formatDays(effective),
                    allocationStr,
                    status
                ]
                rows.append(row)
            }
        }

        return ([header] + rows).map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func formatDays(_ halfDays: Int) -> String {
        halfDays % 2 == 0 ? "\(halfDays / 2)" : "\(halfDays / 2).5"
    }

    static func quote(_ field: String) -> String {
        let start = field.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
        let risky = start.map { "=+-@".unicodeScalars.contains($0) } == true || field.first.map { "\t\r".contains($0) } == true
        let safe = risky ? "'" + field : field
        guard safe.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
