import SwiftUI
import SwiftData

/// One custom list as a material card matching the day columns: an inline-
/// renamable title, its tasks, an empty state, and an inline quick-add.
struct CustomListColumn: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Environment(DragController.self) private var drag
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
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .reorderCardHandle(id: list.id, controller: drag, list: list)
                    .help("Drag to reorder lists")
                TextField("List name", text: $list.name)
                    .font(.system(size: 13, weight: .semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { try? context.save() }
            }
            .frame(minHeight: 30)

            if sortedTasks.isEmpty {
                EmptyTasksView(title: "This list is empty")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(sortedTasks) { task in
                                TaskRowView(task: task) { onEditTask(task) }
                                    .id(task.id)
                                    .reorderableRow(id: task.id, kind: .task, container: .list(list.id), controller: drag, task: task)
                            }
                        }
                    }
                    .onChange(of: app.highlightedTaskID) { _, id in scrollToHighlight(id, proxy: proxy) }
                    .onAppear { scrollToHighlight(app.highlightedTaskID, proxy: proxy) }
                }
            }

            QuickAddField(placeholder: "Add task", text: $newTitle, onSubmit: addTask)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cardSurface()
        // Drop target for tasks moved into this list, and (via reorderableListCard)
        // this card's own frame as a row in the horizontal lists row.
        .publishContainerFrame(.list(list.id), accepts: .task, axis: .vertical, isEmpty: sortedTasks.isEmpty)
        .reorderableListCard(id: list.id, controller: drag)
        .contextMenu {
            Button("Delete List", role: .destructive) { deleteList() }
        }
    }

    /// Center + flash a searched-for task if it lives in this list.
    private func scrollToHighlight(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id, sortedTasks.contains(where: { $0.id == id }) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
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
