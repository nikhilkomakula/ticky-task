import Foundation
import SwiftData

/// A single to-do item.
///
/// Named `TaskItem` (not `Task`) to avoid colliding with Swift Concurrency's
/// `Task`. A task lives on **either** a calendar day (`dayKey`, `"yyyyMMdd"`)
/// **or** a `customList` — never both; `listKind` reflects which.
@Model
final class TaskItem {
    var id: UUID = UUID()
    var title: String = ""
    /// Markdown source for the task's notes/description.
    var notes: String = ""
    var isDone: Bool = false

    /// `"yyyyMMdd"` day key for calendar tasks; `nil` for custom-list tasks.
    var dayKey: String?
    /// Owning custom list; `nil` for calendar tasks. The inverse is declared on
    /// `CustomList.tasks`, which owns the cascade-delete rule.
    var customList: CustomList?

    /// Minutes since midnight (0...1439); `nil` = untimed.
    var timeMinutes: Int?
    /// `"#rrggbb"` color; `nil` = "none".
    var colorHex: String?
    var priority: Int = 0
    /// Manual ordering within a day/list (fractional indexing).
    var sortIndex: Double = 0
    var alarmEnabled: Bool = false
    /// Escalation flag: this task needs immediate attention. Replaces the former
    /// `.critical` priority level; surfaced with a red warning mark. Default off.
    var needsImmediateAttention: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Recurrence rule for a repeating template; `nil` = one-off task. Stored as
    /// a single Codable attribute — occurrences are computed by `RecurrenceEngine`.
    var recurrence: RecurrenceRule?

    @Relationship(deleteRule: .cascade, inverse: \Subtask.parent)
    var subtasks: [Subtask] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskOccurrence.template)
    var occurrences: [TaskOccurrence] = []

    @Relationship(inverse: \TaskTag.tasks)
    var tags: [TaskTag] = []

    init(id: UUID = UUID(),
         title: String = "",
         dayKey: String? = nil,
         customList: CustomList? = nil,
         timeMinutes: Int? = nil,
         colorHex: String? = nil,
         priority: Int = 0,
         sortIndex: Double = 0,
         alarmEnabled: Bool = false,
         recurrence: RecurrenceRule? = nil) {
        self.id = id
        self.title = title
        self.dayKey = dayKey
        self.customList = customList
        self.timeMinutes = timeMinutes
        self.colorHex = colorHex
        self.priority = priority
        self.sortIndex = sortIndex
        self.alarmEnabled = alarmEnabled
        self.recurrence = recurrence
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

extension TaskItem {
    enum ListKind: Equatable {
        case day(String)
        case customList
        case unassigned
    }

    var listKind: ListKind {
        if let dayKey { return .day(dayKey) }
        if customList != nil { return .customList }
        return .unassigned
    }

    var isRecurringTemplate: Bool { recurrence != nil }
}
