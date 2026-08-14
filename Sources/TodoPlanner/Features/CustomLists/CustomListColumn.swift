import SwiftUI
import SwiftData

/// One custom list rendered as a column: an inline-renamable title, its tasks,
/// and a quick-add field. Used in the week view's bottom custom-lists row.
struct CustomListColumn: View {
    @Environment(\.modelContext) private var context
    @Bindable var list: CustomList
    var onEditTask: (TaskItem) -> Void

    @State private var newTitle = ""
    @AppStorage("taskSortMode") private var sortModeRaw = TaskSortMode.manual.rawValue
    @AppStorage("moveCompletedToBottom") private var moveCompletedToBottom = true

    private var sortedTasks: [TaskItem] {
        BehaviorService.sorted(list.tasks,
                               mode: TaskSortMode(rawValue: sortModeRaw) ?? .manual,
                               completedToBottom: moveCompletedToBottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("List name", text: $list.name)
                .font(.subheadline.weight(.semibold))
                .textFieldStyle(.plain)
                .onSubmit { try? context.save() }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedTasks) { task in
                        TaskRowView(task: task) { onEditTask(task) }
                    }
                }
            }

            quickAddField
        }
        .padding(8)
        .contextMenu {
            Button("Delete List", role: .destructive) { deleteList() }
        }
    }

    private var quickAddField: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus.circle").foregroundStyle(.secondary)
            TextField("Add task", text: $newTitle)
                .textFieldStyle(.plain)
                .onSubmit(addTask)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func addTask() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let service = DataService(context)
            try service.addTask(title: title, location: .customList(list))
            try service.save()
            newTitle = ""
        } catch {
            // Surfacing save errors in the UI is tracked as a P13 hardening item.
        }
    }

    private func deleteList() {
        context.delete(list)
        try? context.save()
    }
}
