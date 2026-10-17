import SwiftUI
import SwiftData

/// A board's Change Log (design 01 §2.4): every entry, newest first, with Revert where it
/// applies. Revert is conflict-checked and refuses, with the reason, if anything newer
/// changed the same thing.
struct KanbanChangeLogView: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        let entries = project.activities.sorted { $0.seq > $1.seq }
        VStack(spacing: 0) {
            HStack {
                Text("Change Log — \(project.name)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("kanban-changelog-done")
            }
            .padding(12)
            Divider()
            List(entries) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: symbol(entry)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary)
                        Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.revertedByActivityID != nil {
                        Text("Reverted").font(.caption).foregroundStyle(.secondary)
                    } else if KanbanService.offersRevert(entry) {
                        Button("Revert") {
                            do { _ = try app.kanbanService(context).revert(entry) } catch { self.error = error.localizedDescription }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("kanban-changelog-revert-\(entry.summary)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("kanban-changelog-entry-\(entry.summary)")
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 520)
        .alert("Can’t revert that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func symbol(_ entry: KanbanActivity) -> String {
        switch KanbanActivityKind(rawValue: entry.kindRaw) {
        case .created: "plus.circle"
        case .moved: "arrow.right.circle"
        case .edited: "pencil.circle"
        case .archived: "archivebox"
        case .restored, .restoredGraph: "arrow.uturn.backward.circle"
        case .deleted: "trash.circle"
        case .structure: "square.grid.3x2"
        case .memberArchived: "person.crop.circle.badge.minus"
        case .scheduled: "calendar.badge.plus"
        case nil: "circle"
        }
    }
}

/// What ⌘Z / ⇧⌘Z do on the open board; registered by the board while it's on screen.
@MainActor
final class KanbanBoardActions {
    let projectID: UUID
    var undo: () -> Void
    var redo: () -> Void

    init(projectID: UUID, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        self.projectID = projectID
        self.undo = undo
        self.redo = redo
    }
}

/// Edit › Undo / Redo (design 01 §4 shortcut routing): a text field keeps its own undo;
/// otherwise, in Kanban with a board open, they undo and redo board changes.
struct KanbanUndoCommands: View {
    let appState: AppState

    var body: some View {
        Button("Undo") { route(undo: true) }
            .keyboardShortcut("z", modifiers: .command)
        Button("Redo") { route(undo: false) }
            .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    private func route(undo: Bool) {
        // The board's history only when nothing else owns ⌘Z: no text field, no sheet (an
        // editor's draft), Kanban showing (as resolved: a hidden planner means Kanban) and
        // the registered board still the one open.
        let window = NSApp.keyWindow
        let editingText = window?.firstResponder is NSText
        let inSheet = window?.sheetParent != nil || window?.attachedSheet != nil
        let module = ModulePolicy(UserDefaults.standard).resolve(appState.module)
        if !editingText, !inSheet, module == .kanban, let actions = appState.kanbanBoardActions,
           appState.kanban.selection == .project(actions.projectID) {
            undo ? actions.undo() : actions.redo()
        } else {
            NSApp.sendAction(Selector(undo ? "undo:" : "redo:"), to: nil, from: nil)
        }
    }
}
