import SwiftUI
import SwiftData

/// The board as a sortable table with multi-select and bulk actions (design 01 §5).
struct KanbanListView: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @State private var selection: Set<UUID> = []
    @State private var editingTask: KanbanTask?

    /// The header sort lives in the board state, so it's remembered and follows the toolbar's Sort.
    private static let keys: [(String, PartialKeyPath<Row>)] = [
        ("title", \Row.title), ("column", \Row.columnIndex), ("assignee", \Row.assignee), ("priority", \Row.priority),
        ("due", \Row.due), ("labels", \Row.labels), ("estimate", \Row.estimate),
    ]

    private static func comparator(_ key: String, ascending: Bool) -> KeyPathComparator<Row> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case "title": return KeyPathComparator(\Row.title, order: order)
        case "assignee": return KeyPathComparator(\Row.assignee, order: order)
        case "priority": return KeyPathComparator(\Row.priority, order: order)
        case "due": return KeyPathComparator(\Row.due, order: order)
        case "labels": return KeyPathComparator(\Row.labels, order: order)
        case "estimate": return KeyPathComparator(\Row.estimate, order: order)
        default: return KeyPathComparator(\Row.columnIndex, order: order)
        }
    }

    private func sortOrder(_ state: KanbanBoardState) -> Binding<[KeyPathComparator<Row>]> {
        Binding(get: {
            let (key, ascending) = state.effectiveListSort
            return [Self.comparator(key, ascending: ascending)]
        }, set: { comparators in
            guard let first = comparators.first, let key = Self.keys.first(where: { $0.1 == first.keyPath })?.0 else { return }
            app.updateBoardState(project, context: context) {
                $0.listSortKey = key
                $0.listSortAscending = first.order == .forward
            }
        })
    }

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
        var dueText: String { hasDue ? due.formatted(date: .abbreviated, time: .omitted) : "—" }
        var estimateText: String { estimate < 0 ? "—" : "\(estimate.formatted(.number.precision(.fractionLength(0...1))))h" }

        init(_ task: KanbanTask, columns: [KanbanColumn]) {
            let level = TaskPriority(rawValue: min(max(task.priority, 0), 2)) ?? .low
            id = task.id
            self.task = task
            title = task.title
            column = task.column?.name ?? ""
            columnIndex = columns.firstIndex { $0.id == task.column?.id } ?? 0
            assignee = task.resource.flatMap { $0.archivedAt == nil ? $0.displayName : nil } ?? "Unassigned"
            priority = task.isCritical ? 3 : task.priority
            priorityLabel = task.isCritical ? "Critical" : level.label
            due = task.dueDate ?? .distantFuture
            hasDue = task.dueDate != nil
            labels = task.labels.sorted { $0.sortIndex < $1.sortIndex }.map(\.name).joined(separator: ", ")
            estimate = task.estimateHours ?? -1
            archived = task.archivedAt != nil
        }
    }

    var body: some View {
        let _ = app.kanbanClock   // due filters roll over at midnight
        let state = KanbanBoardState.decode(project.boardState)
        let columns = project.orderedColumns
        let calendar = KanbanUI.calendar(weekStartsMonday: weekStartsMonday)
        let order = sortOrder(state)
        let rows: [Row] = project.tasks
            .filter { (state.showArchived || $0.archivedAt == nil) && state.filter.matches($0, calendar: calendar) }
            .map { Row($0, columns: columns) }
            .sorted(using: order.wrappedValue)
        let byID = Dictionary(rows.map { ($0.id, $0.task) }, uniquingKeysWith: { a, _ in a })
        table(rows, order: order, hours: project.loadMeasure == .hours)
        .contextMenu(forSelectionType: UUID.self) { ids in
            KanbanBulkMenu(project: project, tasks: KanbanBulkMenu.ordered(ids.compactMap { byID[$0] }, in: project),
                           onOpen: { editingTask = $0 })
        } primaryAction: { ids in
            if ids.count == 1, let task = ids.first.flatMap({ byID[$0] }) { editingTask = task }
        }
        .accessibilityIdentifier("kanban-list")
        .sheet(item: $editingTask) { KanbanTaskEditor(task: $0) }
    }

    // Split out, with explicit key paths and plain text cells, so it type-checks quickly.
    private func table(_ rows: [Row], order: Binding<[KeyPathComparator<Row>]>, hours: Bool) -> some View {
        Table(rows, selection: $selection, sortOrder: order) {
            TableColumn("Title", value: \Row.title) { (row: Row) in
                Text(row.title)
                    .foregroundStyle(row.archived ? Color.secondary : Color.primary)
                    .accessibilityIdentifier("kanban-list-row-\(row.title)")
            }
            TableColumn("Column", value: \Row.columnIndex) { (row: Row) in Text(row.column) }
            TableColumn("Assignee", value: \Row.assignee) { (row: Row) in Text(row.assignee) }
            TableColumn("Priority", value: \Row.priority) { (row: Row) in Text(row.priorityLabel) }
            TableColumn("Due", value: \Row.due) { (row: Row) in Text(row.dueText) }
            TableColumn("Labels", value: \Row.labels) { (row: Row) in Text(row.labels) }
            TableColumn("Estimate", value: \Row.estimate) { (row: Row) in Text(hours ? row.estimateText : "—") }
        }
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
        let columns: [UUID: Int] = Dictionary(project.orderedColumns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows: [UUID: Double] = Dictionary(project.resources.map { ($0.id, $0.sortIndex) }, uniquingKeysWith: { a, _ in a })
        func key(_ task: KanbanTask) -> (Int, Double, Double) {
            let column = task.column.flatMap { columns[$0.id] } ?? .max
            let row = task.resource.flatMap { rows[$0.id] } ?? -1
            return (column, row, task.sortIndex)
        }
        return tasks.sorted { key($0) < key($1) }
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
