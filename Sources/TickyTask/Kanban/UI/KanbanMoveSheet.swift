import SwiftUI
import SwiftData

/// **M** on a focused card: pick its column and assignee (design 01 §4).
struct KanbanMoveSheet: View {
    let task: KanbanTask
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var columnID: UUID?
    @State private var row = KanbanRowKey.unassigned
    @State private var error: String?

    var body: some View {
        let project = task.project
        VStack(alignment: .leading, spacing: 12) {
            Text("Move “\(task.title)”").font(.headline)
            Form {
                Picker("Column", selection: $columnID) {
                    ForEach(project?.orderedColumns ?? []) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("kanban-move-column")
                Picker("Assignee", selection: $row) {
                    Text("Unassigned").tag(KanbanRowKey.unassigned)
                    ForEach((project?.resources ?? []).filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }) {
                        Text($0.displayName).tag(KanbanRowKey.resource($0.id))
                    }
                }
                .accessibilityIdentifier("kanban-move-assignee")
            }
            .frame(width: 340)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move", action: move)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("kanban-move-confirm")
            }
        }
        .padding(20)
        .onAppear {
            columnID = task.column?.id
            row = task.resource.flatMap { $0.archivedAt == nil ? .resource($0.id) : nil } ?? .unassigned
        }
    }

    private func move() {
        guard let project = task.project, let columnID else { return dismiss() }
        do {
            _ = try app.kanbanService(context).move(.cards([task.id], to: .cell(columnID: columnID, row: row, beforeCardID: nil)), in: project)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// **Space** on a focused card: a read-only look at it.
struct KanbanQuickLook: View {
    let task: KanbanTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title).font(.headline)
            Text([task.column?.name, task.resource?.displayName ?? "Unassigned"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let due = task.dueDate {
                Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar").font(.caption)
            }
            if !task.notes.isEmpty {
                Text(task.notes).font(.callout).lineLimit(8)
            }
            if !task.subtasks.isEmpty {
                Text("\(task.subtasks.filter(\.isDone).count) of \(task.subtasks.count) subtasks done").font(.caption)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .accessibilityIdentifier("kanban-quicklook")
    }
}
