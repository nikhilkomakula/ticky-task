import SwiftUI
import SwiftData

/// One day column in the week view: a header, the day's tasks (live `@Query`
/// scoped to the day key), and an inline quick-add field.
struct DayColumnView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(orderedTasks) { task in
                        TaskRowView(task: task) { onEditTask(task) }
                    }
                }
            }
            quickAddField
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { app.selectedDayKey = dayKey }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.wide)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isToday ? Color.accentColor : .primary)
            Text(date.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption)
                .foregroundStyle(.secondary)
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
            try service.addTask(title: title, location: .day(dayKey))
            try service.save()
            newTitle = ""
        } catch {
            // Surfacing save errors in the UI is tracked as a P13 hardening item.
        }
    }
}
