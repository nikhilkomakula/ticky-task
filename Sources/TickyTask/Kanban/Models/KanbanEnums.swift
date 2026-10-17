import Foundation

/// A board column's role. Dashboards and completion key off `.done`; every project
/// has exactly one `.backlog` and at least one `.done` column.
enum KanbanColumnKind: String, CaseIterable, Codable, Sendable {
    case backlog, active, done
}

enum KanbanEmployment: String, CaseIterable, Codable, Sendable {
    case fte, contractor
}

enum KanbanAssignment: String, CaseIterable, Codable, Sendable {
    case fullTime, partTime
}

/// What capacity views measure: open-task counts (default) or estimated hours.
enum KanbanLoadMeasure: String, CaseIterable, Codable, Sendable {
    case taskCount, hours
}

/// What happens when a drop exceeds a column's WIP limit (limits are unset by default).
enum KanbanWIPPolicy: String, CaseIterable, Codable, Sendable {
    case warn, block
}
