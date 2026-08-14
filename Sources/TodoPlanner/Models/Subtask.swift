import Foundation
import SwiftData

/// A checklist item nested under a `TaskItem`.
@Model
final class Subtask {
    var id: UUID = UUID()
    var title: String = ""
    var isDone: Bool = false
    var sortIndex: Double = 0
    /// Owning task. The inverse is declared on `TaskItem.subtasks`.
    var parent: TaskItem?

    init(id: UUID = UUID(), title: String = "", isDone: Bool = false, sortIndex: Double = 0) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.sortIndex = sortIndex
    }
}
