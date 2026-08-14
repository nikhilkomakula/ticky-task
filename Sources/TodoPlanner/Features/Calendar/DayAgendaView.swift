import SwiftUI
import SwiftData

/// A reusable single-day agenda: the day's tasks (live `@Query`), an empty
/// state, and an inline quick-add. Used by the calendar detail panel and the
/// menu-bar popover. `insets` lets hosts control the edge padding.
struct DayAgendaView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @AppStorage("taskSortMode") private var sortModeRaw = TaskSortMode.manual.rawValue
    @AppStorage("moveCompletedToBottom") private var moveCompletedToBottom = true
    let dayKey: String
    var showsHeader: Bool
    var insets: CGFloat

    @Query private var tasks: [TaskItem]
    @State private var newTitle = ""
    @State private var editingTask: TaskItem?

    init(dayKey: String, showsHeader: Bool = true, insets: CGFloat = 8) {
        self.dayKey = dayKey
        self.showsHeader = showsHeader
        self.insets = insets
        let target: String? = dayKey
        _tasks = Query(
            filter: #Predicate<TaskItem> { $0.dayKey == target },
            sort: [SortDescriptor(\.sortIndex)]
        )
    }

    private var orderedTasks: [TaskItem] {
        BehaviorService.sorted(tasks,
                               mode: TaskSortMode(rawValue: sortModeRaw) ?? .manual,
                               completedToBottom: moveCompletedToBottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader, let date = WeekMath.date(fromDayKey: dayKey) {
                Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.headline)
            }

            if orderedTasks.isEmpty {
                EmptyTasksView(hint: "Add one below")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(orderedTasks) { task in
                                TaskRowView(task: task) { editingTask = task }
                                    .id(task.id)
                            }
                        }
                    }
                    .onChange(of: app.highlightedTaskID) { _, id in scrollToHighlight(id, proxy: proxy) }
                    .onAppear { scrollToHighlight(app.highlightedTaskID, proxy: proxy) }
                }
            }

            QuickAddField(placeholder: "Add task", text: $newTitle, onSubmit: addTask)
        }
        .padding(insets)
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task)
        }
    }

    /// Center + flash a searched-for task if it's in this day's agenda (used when
    /// a search jump lands in the month view for an off-column/weekend day).
    private func scrollToHighlight(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id, orderedTasks.contains(where: { $0.id == id }) else { return }
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
            try service.addTask(title: title, location: .day(dayKey))
            try service.save()
            newTitle = ""
        } catch {
            // Surfacing save errors in the UI is tracked as a P13 hardening item.
        }
    }
}
