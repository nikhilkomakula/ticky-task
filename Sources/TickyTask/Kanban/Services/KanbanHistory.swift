import Foundation
import Observation

/// Per-board undo and redo stacks of change-log entry ids for this session (design 01 §2.4).
/// Only user operations go on the undo stack — never the inverses that ⌘Z writes — and a
/// fresh operation clears redo. `KanbanService` updates the stacks only after a save
/// succeeds; a restore or import clears them.
@MainActor @Observable
final class KanbanHistory {
    private var undo: [UUID: [UUID]] = [:]
    private var redo: [UUID: [UUID]] = [:]

    func canUndo(_ project: UUID) -> Bool { !(undo[project] ?? []).isEmpty }
    func canRedo(_ project: UUID) -> Bool { !(redo[project] ?? []).isEmpty }

    func peekUndo(_ project: UUID) -> UUID? { undo[project]?.last }
    func peekRedo(_ project: UUID) -> UUID? { redo[project]?.last }

    func recordUserOperation(_ activity: UUID, project: UUID) {
        undo[project, default: []].append(activity)
        redo[project] = []
    }

    /// ⌘Z succeeded: the original moves to redo; its inverse is not undoable itself.
    func didUndo(original: UUID, inverse: UUID, project: UUID) {
        if undo[project]?.last == original { undo[project]?.removeLast() }
        redo[project, default: []].append(original)
    }

    /// ⇧⌘Z succeeded: the original is back on the undo stack (it now reverts via its re-application).
    func didRedo(original: UUID, reapplied: UUID, project: UUID) {
        if redo[project]?.last == original { redo[project]?.removeLast() }
        undo[project, default: []].append(reapplied)
    }

    func clear() {
        undo = [:]
        redo = [:]
    }
}
