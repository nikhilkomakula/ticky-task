import SwiftUI
import SwiftData

/// The board as a sortable table with multi-select and bulk actions (design 01 §5).
struct KanbanListView: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\Row.column)]
    @State private var editingTask: KanbanTask?

    struct Row: Identifiable {
        let id: UUID
        let task: KanbanTask
        let title: String
        let column: String
        let columnIndex: Int
        let assignee: String
        let priority: Int
        let priorityLabel: String
        let due: Date
        let hasDue: Bool
        let labels: String
        let estimate: Double
        let archived: Bool
    }

    var body: some View {
        let state = KanbanBoardState.decode(project.boardState)
        let columns = project.orderedColumns
        let rows = project.tasks
            .filter { (state.showArchived || $0.archivedAt == nil) && state.filter.matches($0) }
            .map { task in
                let priority = TaskPriority(rawValue: min(max(task.priority, 0), 2)) ?? .low
                return Row(id: task.id, task: task, title: task.title, column: task.column?.name ?? "",
                           columnIndex: columns.firstIndex { $0.id == task.column?.id } ?? 0,
                           assignee: task.resource.flatMap { $0.archivedAt == nil ? $0.displayName : nil } ?? "Unassigned",
                           priority: task.isCritical ? 3 : task.priority, priorityLabel: task.isCritical ? "Critical" : priority.label,
                           due: task.dueDate ?? .distantFuture, hasDue: task.dueDate != nil,
                           labels: task.labels.sorted { $0.sortIndex < $1.sortIndex }.map(\.name).joined(separator: ", "),
                           estimate: task.estimateHours ?? -1, archived: task.archivedAt != nil)
            }
            .sorted(using: sortOrder)
        let byID = Dictionary(rows.map { ($0.id, $0.task) }, uniquingKeysWith: { a, _ in a })
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                Text(row.title).foregroundStyle(row.archived ? .secondary : .primary)
                    .accessibilityIdentifier("kanban-list-row-\(row.title)")
            }
            TableColumn("Column", value: \.columnIndex) { Text($0.column) }
            TableColumn("Assignee", value: \.assignee) { Text($0.assignee) }
            TableColumn("Priority", value: \.priority) { Text($0.priorityLabel) }
            TableColumn("Due", value: \.due) { row in
                Text(row.hasDue ? row.due.formatted(date: .abbreviated, time: .omitted) : "—")
            }
            TableColumn("Labels", value: \.labels) { Text($0.labels) }
            if project.loadMeasure == .hours {
                TableColumn("Estimate", value: \.estimate) { row in
                    Text(row.estimate < 0 ? "—" : "\(row.estimate.formatted(.number.precision(.fractionLength(0...1))))h")
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            KanbanBulkMenu(project: project, tasks: KanbanBulkMenu.ordered(ids.compactMap { byID[$0] }, in: project),
                           onOpen: { editingTask = $0 })
        } primaryAction: { ids in
            if ids.count == 1, let task = ids.first.flatMap({ byID[$0] }) { editingTask = task }
        }
        .accessibilityIdentifier("kanban-list")
        .sheet(item: $editingTask) { KanbanTaskEditor(task: $0) }
    }
}

/// Actions on one or more cards: open, move, assign, label, priority, archive or restore,
/// delete. Each bulk action is one Change Log entry.
struct KanbanBulkMenu: View {
    let project: KanbanProject
    let tasks: [KanbanTask]
    var onOpen: (KanbanTask) -> Void = { _ in }
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context

    /// Cards in board order: column, then row, then position (design 01 §4, multi-selection).
    static func ordered(_ tasks: [KanbanTask], in project: KanbanProject) -> [KanbanTask] {
        let columns = Dictionary(project.orderedColumns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = Dictionary(project.resources.map { ($0.id, $0.sortIndex) }, uniquingKeysWith: { a, _ in a })
        return tasks.sorted {
            (columns[$0.column?.id ?? UUID()] ?? .max, $0.resource.flatMap { rows[$0.id] } ?? -1, $0.sortIndex)
                < (columns[$1.column?.id ?? UUID()] ?? .max, $1.resource.flatMap { rows[$0.id] } ?? -1, $1.sortIndex)
        }
    }

    var body: some View {
        let service = app.kanbanService(context)
        let ids = tasks.map(\.id)
        let live = tasks.filter { $0.archivedAt == nil }
        if tasks.count == 1, let task = tasks.first {
            Button("Open") { onOpen(task) }
            Divider()
        }
        if !live.isEmpty {
            Menu("Move to") {
                ForEach(project.orderedColumns) { column in
                    Button(column.name) { app.runKanban { _ = try service.move(.cards(live.map(\.id), to: .columnHeader(column.id)), in: project) } }
                }
            }
            Menu("Assign to") {
                Button("Unassigned") { app.runKanban { _ = try service.move(.cards(live.map(\.id), to: .rowHeader(.unassigned)), in: project) } }
                ForEach(project.resources.filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }) { resource in
                    Button(resource.displayName) {
                        app.runKanban { _ = try service.move(.cards(live.map(\.id), to: .rowHeader(.resource(resource.id))), in: project) }
                    }
                }
            }
            Menu("Label") {
                ForEach(project.labels.sorted { $0.sortIndex < $1.sortIndex }) { label in
                    let all = live.allSatisfy { $0.labels.contains { $0.id == label.id } }
                    Button(all ? "Remove \(label.name)" : "Add \(label.name)") {
                        app.runKanban { try service.setLabel(label, on: live, !all) }
                    }
                }
            }
            Menu("Priority") {
                ForEach(TaskPriority.allCases) { priority in
                    Button(priority.label) { app.runKanban { try service.editMany(live, [.priority: .int(priority.rawValue)]) } }
                }
                Divider()
                let critical = live.allSatisfy(\.isCritical)
                Button(critical ? "Clear Critical" : "Mark Critical") { app.runKanban { try service.editMany(live, [.isCritical: .bool(!critical)]) } }
            }
            Divider()
            Button(live.count == 1 ? "Archive" : "Archive \(live.count) cards") { app.runKanban { try service.setArchived(live, true) } }
        }
        let archived = tasks.filter { $0.archivedAt != nil }
        if !archived.isEmpty {
            Button(archived.count == 1 ? "Restore" : "Restore \(archived.count) cards") { app.runKanban { try service.setArchived(archived, false) } }
        }
        if ids.isEmpty { Text("No cards") }
    }
}
