import SwiftUI
import SwiftData

/// One custom list as a material card matching the day columns: an inline-
/// renamable title, its tasks, an empty state, and an inline quick-add.
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
                .font(.system(size: 13, weight: .semibold))
                .textFieldStyle(.plain)
                .onSubmit { try? context.save() }
                .frame(minHeight: 30)

            if sortedTasks.isEmpty {
                EmptyTasksView(title: "This list is empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedTasks) { task in
                            TaskRowView(task: task) { onEditTask(task) }
                        }
                    }
                }
            }

            QuickAddField(placeholder: "Add task", text: $newTitle, onSubmit: addTask)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cardSurface()
        .contextMenu {
            Button("Delete List", role: .destructive) { deleteList() }
        }
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
