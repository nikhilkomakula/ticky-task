import Foundation
import SwiftData

/// A card on a board. Notes use the planner's storage (`NotesCodec` JSON plus a
/// plain-text projection); priority and Critical match the planner's.
@Model
final class KanbanTask {
    var id: UUID = UUID()
    var title: String = ""
    /// Plain-text projection of `notesRich` (search, summaries).
    var notes: String = ""
    var notesRich: Data?
    /// `TaskPriority` raw value (0 low … 2 high).
    var priority: Int = 0
    var isCritical: Bool = false
    /// Order within its cell (column × resource).
    var sortIndex: Double = 0
    var dueDate: Date?
    var startDate: Date?
    var estimateHours: Double?
    var jiraURL: String?
    var isBlocked: Bool = false
    var blockedReason: String?
    /// The planner `TaskItem` created by "Schedule to day…". A scalar id, so the
    /// planner schema stays untouched; a missing target reads as "no link".
    var linkedPlannerTaskID: UUID?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Set on entering a `.done` column (kept on Done → Done), cleared on leaving.
    var completedAt: Date?
    var archivedAt: Date?

    /// Owning project; the inverse is declared on `KanbanProject.tasks`.
    var project: KanbanProject?
    /// Required (enforced by the service); optional so a column delete can nullify.
    var column: KanbanColumn?
    /// `nil` = the Unassigned row.
    var resource: KanbanResource?
    @Relationship(deleteRule: .cascade, inverse: \KanbanSubtask.task) var subtasks: [KanbanSubtask] = []
    @Relationship(deleteRule: .nullify, inverse: \KanbanLabel.tasks) var labels: [KanbanLabel] = []
    /// Prerequisites. Edges never cascade; self edges and cycles are refused.
    @Relationship(deleteRule: .nullify, inverse: \KanbanTask.dependents) var dependsOn: [KanbanTask] = []
    var dependents: [KanbanTask] = []

    init(id: UUID = UUID(), title: String = "", priority: Int = 0, sortIndex: Double = 0) {
        self.id = id
        self.title = title
        self.priority = priority
        self.sortIndex = sortIndex
    }

    /// The Jira key in `jiraURL`, e.g. "PLAT-142".
    var jiraKey: String? {
        guard let jiraURL, let range = jiraURL.range(of: #"[A-Z][A-Z0-9]+-\d+"#, options: .regularExpression)
        else { return nil }
        return String(jiraURL[range])
    }

    /// Whether the card has content in its notes. Rich notes are decoded and checked
    /// for non-whitespace plaintext; otherwise plain notes are checked. A valid empty
    /// rich document wins over stale plain-text projection.
    var hasNotes: Bool {
        if let notesRich, !notesRich.isEmpty, let document = try? NotesCodec.decode(notesRich) {
            return !document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
