import Foundation
import SwiftData

/// One entry in a board's change log: what changed, in a form that can be replayed
/// (dashboards) and conflict-checked for undo/Revert. Task references are plain ids
/// so an entry outlives a deleted task.
@Model
final class KanbanActivity {
    var id: UUID = UUID()
    /// Per-project order (from `KanbanProject.nextActivitySeq`); `at` is the calendar time.
    var seq: Int = 0
    var at: Date = Date()
    var kindRaw: String = ""
    var taskIDs: [UUID] = []
    /// Human-readable line for the Change Log.
    var summary: String = ""
    /// Encoded, versioned `KanbanActivityPayload`.
    var payload: Data = Data()
    /// Set on an inverse: the entry it reverts.
    var revertsActivityID: UUID?
    /// Set on an original once something reverted it.
    var revertedByActivityID: UUID?
    /// Owning project; the inverse is declared on `KanbanProject.activities`.
    var project: KanbanProject?

    init(id: UUID = UUID(), seq: Int, at: Date = Date(), kind: String, taskIDs: [UUID] = [],
         summary: String = "", payload: Data = Data()) {
        self.id = id
        self.seq = seq
        self.at = at
        self.kindRaw = kind
        self.taskIDs = taskIDs
        self.summary = summary
        self.payload = payload
    }
}
