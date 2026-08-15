import SwiftUI
import SwiftData

/// One day column: a header (today shown as an accent day-number circle), the
/// day's tasks (live `@Query`), an empty state, and an inline quick-add. Rendered
/// as a material card; selected day gets an accent border.
struct DayColumnView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Environment(DragController.self) private var drag
    @AppStorage("taskSortMode") private var sortModeRaw = TaskSortMode.manual.rawValue
    @AppStorage("moveCompletedToBottom") private var moveCompletedToBottom = true

    let date: Date
    private let dayKey: String
    @Query private var tasks: [TaskItem]
    @State private var newTitle = ""
    var onEditTask: (TaskItem) -> Void

    init(date: Date, onEditTask: @escaping (TaskItem) -> Void = { _ in }) {
        self.date = date
        self.onEditTask = onEditTask
        let key = WeekMath.dayKey(for: date)
        self.dayKey = key
        let target: String? = key
        _tasks = Query(
            filter: #Predicate<TaskItem> { $0.dayKey == target },
            sort: [SortDescriptor(\.sortIndex)]
        )
    }

    private var isToday: Bool { dayKey == WeekMath.dayKey(for: Date()) }
    private var isSelected: Bool { app.selectedDayKey == dayKey }
    private var orderedTasks: [TaskItem] {
        BehaviorService.sorted(tasks,
                               mode: TaskSortMode(rawValue: sortModeRaw) ?? .manual,
                               completedToBottom: moveCompletedToBottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if orderedTasks.isEmpty {
                EmptyTasksView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(orderedTasks) { task in
                                TaskRowView(task: task) { onEditTask(task) }
                                    .id(task.id)
                                    .reorderableRow(id: task.id, kind: .task, container: .weekDay(dayKey), controller: drag, task: task)
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
        .cardSurface(selected: isSelected)
        // Whole-column drop target: catches drops on the empty area / padding below
        // the rows (moving a task into this day). Rows publish their own frames so
        // the engine can position precisely between them.
        .publishContainerFrame(.weekDay(dayKey), accepts: .task, axis: .vertical, isEmpty: orderedTasks.isEmpty)
        .contentShape(Rectangle())
        .onTapGesture { app.selectedDayKey = dayKey }
        .accessibilityIdentifier("dayColumn-\(dayKey)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(date.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if isToday {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor, in: Circle())
            } else {
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 30)
    }

    /// Center + flash a searched-for task if it lives in this day.
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
