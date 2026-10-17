import Foundation
import SwiftData

/// A board status column (per project, ordered).
@Model
final class KanbanColumn {
    var id: UUID = UUID()
    var name: String = ""
    var sortIndex: Double = 0
    var colorHex: String?
    /// Unset by default; when set, the project's `wipPolicy` applies.
    var wipLimit: Int?
    var kindRaw: String = KanbanColumnKind.active.rawValue
    /// Owning project; the inverse is declared on `KanbanProject.columns`.
    var project: KanbanProject?
    /// Tasks in this column. Nullify, so a deletion never takes tasks with it;
    /// `KanbanService` moves a column's tasks out before deleting it.
    @Relationship(deleteRule: .nullify, inverse: \KanbanTask.column) var tasks: [KanbanTask] = []

    init(id: UUID = UUID(), name: String = "", kind: KanbanColumnKind = .active, sortIndex: Double = 0) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.sortIndex = sortIndex
    }

    var kind: KanbanColumnKind {
        get { KanbanColumnKind(rawValue: kindRaw) ?? .active }
        set { kindRaw = newValue.rawValue }
    }
}
