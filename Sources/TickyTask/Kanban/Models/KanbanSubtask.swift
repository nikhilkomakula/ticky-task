import Foundation
import SwiftData

/// A checklist item on a board card. Done items sink (by `completedAt`, then
/// `sortIndex`); they are never completed automatically.
@Model
final class KanbanSubtask {
    var id: UUID = UUID()
    var title: String = ""
    var isDone: Bool = false
    var sortIndex: Double = 0
    var completedAt: Date?
    /// Owning card; the inverse is declared on `KanbanTask.subtasks`.
    var task: KanbanTask?
    /// The inverse is declared on `KanbanResource.subtaskAssignments`.
    var assignee: KanbanResource?

    init(id: UUID = UUID(), title: String = "", isDone: Bool = false, sortIndex: Double = 0) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.sortIndex = sortIndex
    }
}
