import Foundation
import SwiftData

/// One person's membership of one board: a board row. Name, initials, colour and
/// employment come from `person`. At most one non-archived membership per
/// (person, project), enforced by `KanbanService` and the backup validator.
@Model
final class KanbanResource {
    var id: UUID = UUID()
    /// Owning project; the inverse is declared on `KanbanProject.resources`.
    var project: KanbanProject?
    /// Required (enforced by the service); optional only so SwiftData can nullify.
    var person: KanbanPerson?
    var role: String?
    var assignmentRaw: String = KanbanAssignment.fullTime.rawValue
    /// 1–100; full-time = 100.
    var allocationPercent: Int = 100
    var capacityHoursPerWeekOverride: Double?
    var openTaskTargetOverride: Double?
    var startDate: Date?
    /// Rolls off this project.
    var endDate: Date?
    var sortIndex: Double = 0
    var archivedAt: Date?
    /// Assigned tasks. Nullify, so removing a membership leaves its tasks Unassigned.
    @Relationship(deleteRule: .nullify, inverse: \KanbanTask.resource) var tasks: [KanbanTask] = []
    @Relationship(deleteRule: .nullify, inverse: \KanbanSubtask.assignee) var subtaskAssignments: [KanbanSubtask] = []
    /// Weekly availability overrides on this board. Deleted with the membership.
    @Relationship(deleteRule: .cascade, inverse: \KanbanAvailabilityOverride.resource) var availabilityOverrides: [KanbanAvailabilityOverride] = []

    init(id: UUID = UUID(), person: KanbanPerson? = nil, assignment: KanbanAssignment = .fullTime,
         allocationPercent: Int = 100, sortIndex: Double = 0) {
        self.id = id
        self.person = person
        self.assignmentRaw = assignment.rawValue
        self.allocationPercent = allocationPercent
        self.sortIndex = sortIndex
    }

    var assignment: KanbanAssignment {
        get { KanbanAssignment(rawValue: assignmentRaw) ?? .fullTime }
        set { assignmentRaw = newValue.rawValue }
    }

    var displayName: String { person?.name ?? "" }
    var initials: String { person?.initials ?? "" }
    /// The board's collapse key for this row.
    var rowKey: String { id.uuidString }

    /// Derived allocation classification: exactly 100% → fullTime, otherwise partTime.
    /// Stored `assignmentRaw` is never modified; this computes based on `allocationPercent`.
    var effectiveAssignment: KanbanAssignment {
        allocationPercent == 100 ? .fullTime : .partTime
    }
}
