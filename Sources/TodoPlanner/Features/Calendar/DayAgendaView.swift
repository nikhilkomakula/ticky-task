import SwiftUI
import SwiftData

/// A reusable single-day agenda: the day's tasks (live `@Query` on the day key),
/// an inline quick-add, and tap-to-edit. Used by the calendar detail panel and
/// the menu-bar panel (P9).
struct DayAgendaView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("taskSortMode") private var sortModeRaw = TaskSortMode.manual.rawValue
    @AppStorage("moveCompletedToBottom") private var moveCompletedToBottom = true
    let dayKey: String
    var showsHeader: Bool = true

    @Query private var tasks: [TaskItem]
    @State private var newTitle = ""
    @State private var editingTask: TaskItem?

    init(dayKey: String, showsHeader: Bool = true) {
        self.dayKey = dayKey
        self.showsHeader = showsHeader
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

            if tasks.isEmpty {
                Text("No tasks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(orderedTasks) { task in
                            TaskRowView(task: task) { editingTask = task }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            quickAddField
        }
        .padding(8)
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task)
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
