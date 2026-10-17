import SwiftUI
import SwiftData

/// The menu-bar popover's Kanban mode (design 01 §7): what's due on a day across the
/// active boards, and a quick add that files a card due that day.
@MainActor
enum KanbanPopover {
    /// Settings › Kanban's quick-add board (an id string; empty or missing: the last opened board).
    static let projectKey = "kanbanPopoverProjectID"
    /// The board the main window last showed. View state, so it isn't backed up.
    static let lastProjectKey = "kanbanLastProjectID"

    struct Agenda {
        var due: [KanbanTask] = []
        /// Open cards due before today; only filled when the day is today.
        var overdue: [KanbanTask] = []
    }

    static func agenda(_ projects: [KanbanProject], dayKey: String, now: Date = Date(), calendar: Calendar = .current) -> Agenda {
        let today = WeekMath.dayKey(for: now, calendar: calendar)
        var agenda = Agenda()
        for project in projects where project.archivedAt == nil {
            for task in project.tasks where task.archivedAt == nil {
                guard let due = task.dueDate else { continue }
                let key = WeekMath.dayKey(for: due, calendar: calendar)
                if key == dayKey {
                    agenda.due.append(task)
                } else if dayKey == today, key < today, task.column?.kind != .done {
                    agenda.overdue.append(task)
                }
            }
        }
        func order(_ a: KanbanTask, _ b: KanbanTask) -> Bool {
            let lhs = (a.column?.kind == .done ? 1 : 0, a.dueDate ?? .distantFuture, a.project?.sortIndex ?? 0, a.title)
            let rhs = (b.column?.kind == .done ? 1 : 0, b.dueDate ?? .distantFuture, b.project?.sortIndex ?? 0, b.title)
            return lhs < rhs
        }
        agenda.due.sort(by: order)
        agenda.overdue.sort(by: order)
        return agenda
    }

    /// Days with a card due, for the calendar's markers.
    static func dueDayKeys(_ tasks: [KanbanTask], calendar: Calendar = .current) -> Set<String> {
        Set(tasks.compactMap { task in
            guard task.archivedAt == nil, task.project?.archivedAt == nil, let due = task.dueDate else { return nil }
            return WeekMath.dayKey(for: due, calendar: calendar)
        })
    }

    /// The board quick add files into: the chosen one, else the last opened, else the first
    /// active board; nil when there's no active board.
    static func quickAddProject(_ projects: [KanbanProject], chosen: String?, lastOpened: String?) -> KanbanProject? {
        let active = projects.filter { $0.archivedAt == nil }
        for id in [chosen, lastOpened].compactMap({ $0.flatMap(UUID.init(uuidString:)) }) {
            if let project = active.first(where: { $0.id == id }) { return project }
        }
        return active.first
    }
}

struct KanbanDayAgendaView: View {
    let dayKey: String
    /// Opens the main window on a card's board, highlighted.
    let open: (KanbanTask) -> Void
    /// Opens the main window's Kanban module (no active board yet).
    let openKanban: () -> Void

    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \KanbanProject.sortIndex) private var projects: [KanbanProject]
    @AppStorage(KanbanPopover.projectKey) private var chosenProjectID = ""
    @AppStorage(KanbanPopover.lastProjectKey) private var lastProjectID = ""
    @State private var newTitle = ""
    @State private var error: String?

    var body: some View {
        let _ = app.kanbanClock   // Overdue follows the day
        let _ = app.kanbanGeneration.value
        let agenda = KanbanPopover.agenda(projects, dayKey: dayKey)
        let target = KanbanPopover.quickAddProject(projects, chosen: chosenProjectID, lastOpened: lastProjectID)
        VStack(alignment: .leading, spacing: 8) {
            if let date = WeekMath.date(fromDayKey: dayKey) {
                Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.headline)
            }
            if !agenda.overdue.isEmpty {
                Text("Overdue").font(.caption.weight(.semibold)).foregroundStyle(.red)
                rows(agenda.overdue)
                if !agenda.due.isEmpty { Text("Due today").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            if agenda.due.isEmpty && agenda.overdue.isEmpty {
                EmptyTasksView(hint: target == nil ? "No boards yet" : "Nothing due")
            } else {
                rows(agenda.due)
            }
            if let target {
                HStack(spacing: 6) {
                    QuickAddField(placeholder: "Add card to \(target.name)", text: $newTitle) { add(to: target) }
                        .accessibilityIdentifier("menubar-kanban-add")
                    Menu {
                        ForEach(projects.filter { $0.archivedAt == nil }) { project in
                            Button(project.name) { chosenProjectID = project.id.uuidString }
                        }
                    } label: {
                        Image(systemName: "square.grid.3x2")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Board for new cards")
                    .accessibilityLabel("Board for new cards")
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } else {
                Button("Create a project…", action: openKanban)
                    .buttonStyle(.link)
                    .accessibilityIdentifier("menubar-kanban-create-project")
            }
        }
        .padding(8)
        .onChange(of: dayKey) { _, _ in error = nil }
    }

    private func rows(_ tasks: [KanbanTask]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tasks) { task in
                Button { open(task) } label: { KanbanPopoverRow(task: task) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("menubar-kanban-\(task.title)")
            }
        }
    }

    /// In the board's backlog column, Unassigned, due on the shown day.
    private func add(to project: KanbanProject) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let day = WeekMath.date(fromDayKey: dayKey) else { return }
        do {
            try app.kanbanService(context).createTask(in: project, title: title, dueDate: Calendar.current.startOfDay(for: day))
            newTitle = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Project dot, title, assignee initials, priority or Critical, and the Jira key.
private struct KanbanPopoverRow: View {
    let task: KanbanTask

    var body: some View {
        let done = task.column?.kind == .done
        HStack(spacing: 6) {
            Circle()
                .fill(KanbanUI.color(task.project?.colorHex) ?? .accentColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(task.title)
                .lineLimit(1)
                .strikethrough(done)
                .foregroundStyle(done ? .secondary : .primary)
            Spacer(minLength: 4)
            if task.isCritical {
                Text("Critical").font(.caption2.weight(.semibold)).foregroundStyle(.red)
            } else if let priority = TaskPriority(rawValue: task.priority), priority != .low {
                Text(priority.label).font(.caption2).foregroundStyle(.secondary)
            }
            if let key = task.jiraKey {
                Text(key).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if let initials = task.resource?.initials, !initials.isEmpty {
                Text(initials).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title)\(task.isCritical ? ", Critical" : "")")
        .accessibilityHint("Opens \(task.project?.name ?? "the board") with the card highlighted")
    }
}
