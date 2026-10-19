import Foundation
import SwiftData

/// The Availability tab as a long-form CSV (design 04): one row per member and week, with the
/// numbers `KanbanAvailability` works out. RFC 4180 quoting, formulas neutralised, CRLF ends.
enum KanbanAvailabilityCSV {
    @MainActor
    static func csv(_ project: KanbanProject, weeks: [KanbanDay], calendar: Calendar) -> String {
        let header = ["Board ID", "Board", "Person ID", "Person", "Membership ID", "Week start", "Week end", "Possible days",
                      "Computed days", "Override days", "Effective days", "Allocation percent", "Status", "Holiday days"]
        let board = KanbanAvailability.Board(project)
        let iso = { (day: KanbanDay) in String(format: "%04d-%02d-%02d", day.year, day.month, day.day) }
        var rows: [[String]] = []
        // Fetch all holidays for the cell computation
        let modelContext = project.modelContext
        let holidays = (try? modelContext?.fetch(FetchDescriptor<KanbanHoliday>())) ?? []
        let holidayModel = KanbanAvailability.Holidays(holidays)
        // The tab's rows: memberships on the board now.
        for resource in project.resources.filter({ $0.archivedAt == nil }).sorted(by: { $0.sortIndex < $1.sortIndex }) {
            let member = KanbanAvailability.Member(resource, calendar: calendar)
            for week in weeks {
                let cell = KanbanAvailability.cell(week: week, board: board, member: member, holidays: holidayModel)
                let status = cell.isAllHoliday ? "public holidays" : !cell.isActive ? "outside range" : cell.overrideNeedsReview ? "override needs review"
                    : cell.isOverridden ? "overridden" : "active"
                rows.append([project.id.uuidString, project.name, resource.person?.id.uuidString ?? "", resource.displayName,
                             resource.id.uuidString, iso(week), iso(week.adding(days: 6)),
                             cell.isActive ? KanbanAvailability.days(cell.possibleHalfDays) : "0",
                             cell.isActive ? KanbanAvailability.days(cell.computedHalfDays) : "",
                             cell.overrideHalfDays.map(KanbanAvailability.days) ?? "",
                             cell.isActive ? KanbanAvailability.days(cell.effectiveHalfDays) : "",
                             "\(resource.allocationPercent)", status,
                             cell.holidayHalfDays > 0 ? KanbanAvailability.days(cell.holidayHalfDays) : ""])
            }
        }
        return ([header] + rows).map { $0.map(KanbanBoardTransfer.quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
