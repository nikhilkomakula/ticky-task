import SwiftUI
import SwiftData

/// One custom list as a material card matching the day columns: an inline-
/// renamable title, its tasks, an empty state, and an inline quick-add.
struct CustomListColumn: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Bindable var list: CustomList
    var onEditTask: (TaskItem) -> Void
    var onReorderList: (_ draggedID: UUID, _ beforeID: UUID?) -> Void

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
                    .draggable(DraggedItem(id: list.id, kind: .list))
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
                                    .draggable(DraggedItem(id: task.id, kind: .task))
                                    .dropDestination(for: DraggedItem.self) { items, _ in dropTask(items, before: task.id) }
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
        .dropDestination(for: DraggedItem.self) { items, _ in handleCardDrop(items) }
        .contextMenu {
            Button("Delete List", role: .destructive) { deleteList() }
        }
    }

    /// Move/reorder a dropped task into this list, before `beforeID` (append if nil).
    @discardableResult
    private func dropTask(_ items: [DraggedItem], before beforeID: UUID?) -> Bool {
        guard let item = items.first, item.kind == .task else { return false }
        try? DataService(context).dropTask(item.id, into: .customList(list), before: beforeID, siblings: sortedTasks)
        return true
    }

    /// Whole-card drop: a dropped task appends to this list; a dropped list card
    /// reorders the lists (via the parent's `onReorderList`).
    private func handleCardDrop(_ items: [DraggedItem]) -> Bool {
        guard let item = items.first else { return false }
        switch item.kind {
        case .task: return dropTask(items, before: nil)
        case .list:
            guard item.id != list.id else { return false }  // dropping a list on itself is a no-op
            onReorderList(item.id, list.id)
            return true
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
