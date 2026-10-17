import Foundation

/// A value draft for card creation, holding field values until Done.
struct KanbanCardDraft: Equatable, Sendable {
    // Core fields
    var title: String = ""
    var notes: String = ""
    var notesRich: Data?
    var priority: Int = 0
    var isCritical: Bool = false

    // Placement
    var columnID: UUID?
    var row: KanbanRowKey = .unassigned

    // Dates and estimates
    var dueDate: Date?
    var startDate: Date?
    var estimateHours: Double?

    // Jira and blocking
    var jiraURL: String?
    var isBlocked: Bool = false
    var blockedReason: String?

    // Relationships
    var labelIDs: [UUID] = []
    var dependencyIDs: [UUID] = []

    // Steps (subtasks)
    struct Step: Equatable, Sendable {
        var title: String
        var isDone: Bool = false
        var assigneeID: UUID?
    }
    var steps: [Step] = []

    init() {}
}
