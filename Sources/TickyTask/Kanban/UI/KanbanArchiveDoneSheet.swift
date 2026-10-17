import SwiftUI
import SwiftData

/// Board actions › Archive done cards…: archives a board's finished cards in one Change Log
/// entry, either those finished more than a number of days ago or all of them.
struct KanbanArchiveDoneSheet: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var onlyOlder = true
    @State private var days = 30
    @State private var error: String?

    var body: some View {
        let candidates = self.candidates
        VStack(alignment: .leading, spacing: 12) {
            Text("Archive done cards on \(project.name)").font(.headline)
            Form {
                Picker("Archive", selection: $onlyOlder) {
                    Text("Cards finished more than…").tag(true)
                    Text("All done cards").tag(false)
                }
                .pickerStyle(.radioGroup)
                if onlyOlder {
                    Stepper("\(days) days ago", value: $days, in: 1...365)
                        .accessibilityIdentifier("kanban-archive-done-days")
                }
            }
            Text(summary(candidates))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Archive") { archive() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(candidates.isEmpty)
                    .accessibilityIdentifier("kanban-archive-done-confirm")
            }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityIdentifier("kanban-archive-done-sheet")
    }

    /// Worked out afresh on every change and again on Archive, so it's never a stale list.
    private var candidates: [KanbanTask] {
        KanbanDoneCards.archivable(in: project, finishedMoreThan: onlyOlder ? days : nil)
    }

    private func summary(_ candidates: [KanbanTask]) -> String {
        guard !candidates.isEmpty else { return "No done cards to archive." }
        let ids = Set(candidates.map(\.id))
        let waiting = project.tasks.filter { task in
            task.archivedAt == nil && task.column?.kind != .done && task.dependsOn.contains { ids.contains($0.id) }
        }.count
        var text = "Archives \(candidates.count) \(candidates.count == 1 ? "card" : "cards"), including any hidden by filters. "
            + "Nothing is deleted: Show Archived brings them back into view, and ⌘Z or the Change Log undoes it."
        if waiting > 0 {
            text += " \(waiting) open \(waiting == 1 ? "card depends" : "cards depend") on them and will show as waiting on an archived card."
        }
        return text
    }

    private func archive() {
        let candidates = self.candidates
        guard !candidates.isEmpty else { return }
        do {
            try app.kanbanService(context).setArchived(candidates, true)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
