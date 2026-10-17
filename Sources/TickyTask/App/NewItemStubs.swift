import SwiftUI
import SwiftData

// MARK: - P2 Stubs: Task and Card Create Modes

/// P2 will implement create-mode initialization for TaskEditorView.
/// This stub allows P3 to compile while P2 adds the actual implementation.
extension TaskEditorView {
    /// Create mode: presents an empty form for a new task on the given day.
    /// - Parameter dayKey: The day to create the task on ("yyyyMMdd" format).
    init(createOn dayKey: String) {
        fatalError("P2: TaskEditorView create mode init")
    }
}

/// P2 will implement create-mode initialization for KanbanTaskEditor.
/// This stub allows P3 to compile while P2 adds the actual implementation.
extension KanbanTaskEditor {
    /// Create mode: presents an empty form for a new card in the given project.
    /// - Parameters:
    ///   - project: The project to create the card in.
    ///   - column: The column to place the card in (nil: backlog).
    ///   - row: The row to place the card in (nil: unassigned).
    init(newCardIn project: KanbanProject, column: UUID?, row: KanbanRowKey?) {
        fatalError("P2: KanbanTaskEditor create mode init")
    }
}

// MARK: - P4 Stubs: Label Manager Sheet

/// P4 will implement the label management sheet for editing board labels.
/// This stub allows P3 to compile while P4 adds the actual implementation.
struct KanbanLabelManagerSheet: View {
    let project: KanbanProject

    var body: some View {
        fatalError("P4: KanbanLabelManagerSheet implementation")
    }
}
