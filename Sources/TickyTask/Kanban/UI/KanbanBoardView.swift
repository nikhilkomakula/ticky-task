import SwiftUI
import SwiftData

/// One board: people down the side, columns across the top, cards in the cells. Both
/// header sets stay in view while scrolling (D6): column headers are pinned section
/// headers, and row headers are shifted by the horizontal scroll offset.
struct KanbanBoardView: View {
    let project: KanbanProject
    let allProjects: [KanbanProject]
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    /// Only the sticky views read this, so scrolling doesn't redraw the board.
    @State private var scroll = KanbanScrollOffset()
    @State private var prompt: KanbanTextPrompt?
    @State private var columnToDelete: KanbanColumn?
    @State private var isAddingPerson = false
    @State private var editingMembership: KanbanResource?
    @State private var archivingMembership: KanbanResource?
    @State private var editingTask: KanbanTask?

    var body: some View {
        let snapshot = BoardSnapshot.make(project: project)
        let columns = project.orderedColumns
        let calendar = KanbanUI.calendar(weekStartsMonday: weekStartsMonday)
        let key = app.kanbanMetricsKey(weekStartsMonday: weekStartsMonday)
        let metrics = app.kanbanMetrics.snapshot(of: project, key: key, calendar: calendar)
        let loads = Dictionary(KanbanMetrics.loadVsCapacity(metrics).map { ($0.memberID, $0) }, uniquingKeysWith: { a, _ in a })
        let people = app.kanbanMetrics.people(allProjects, key: key, calendar: calendar)
        let tasks = Dictionary(project.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let collapsed = Set(project.collapsedRowKeys)

        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(snapshot.rows, id: \.key) { row in
                            let resource = row.resourceID.flatMap { id in project.resources.first { $0.id == id } }
                            boardRow(row, resource: resource, columns: columns, snapshot: snapshot, tasks: tasks,
                                     load: loads[row.resourceID], person: row.personID.flatMap { people[$0] },
                                     collapsed: collapsed.contains(row.key.storageKey))
                            Divider()
                        }
                        addPersonButton
                    } header: {
                        columnHeaders(columns, snapshot: snapshot, metrics: metrics)
                    }
                }
            }
            .accessibilityIdentifier("kanban-board")
            .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.x + $0.contentInsets.leading) } action: { _, x in
                scroll.x = x
            }
            // Runs on appear too: Attention sets the card before this board exists.
            .task(id: app.highlightedKanbanTaskID) { await reveal(app.highlightedKanbanTaskID, proxy: proxy) }
        }
        .sheet(item: $prompt) { KanbanTextPromptSheet(prompt: $0) }
        .sheet(item: $columnToDelete) { KanbanDeleteColumnSheet(column: $0) }
        .sheet(isPresented: $isAddingPerson) { KanbanAddPersonSheet(project: project) }
        .sheet(item: $editingMembership) { KanbanMembershipSheet(resource: $0) }
        .sheet(item: $editingTask) { KanbanTaskEditor(task: $0) }
        .confirmationDialog("Remove \(archivingMembership?.displayName ?? "") from this board?",
                            isPresented: Binding(get: { archivingMembership != nil }, set: { if !$0 { archivingMembership = nil } })) {
            Button("Remove", role: .destructive) {
                guard let resource = archivingMembership else { return }
                app.runKanban { try app.kanbanService(context).archiveMembership(resource) }
            }
        } message: {
            Text("Their cards on this board move to Unassigned. You can undo this from the Change Log.")
        }
    }

    // MARK: - Rows

    private func boardRow(_ row: KanbanRowSnapshot, resource: KanbanResource?, columns: [KanbanColumn], snapshot: BoardSnapshot,
                          tasks: [UUID: KanbanTask], load: KanbanMetrics.LoadRow?, person: KanbanMetrics.PersonRow?,
                          collapsed: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            KanbanRowHeader(project: project, row: row, resource: resource, load: load, person: person, collapsed: collapsed,
                            onToggle: { toggle(row.key, collapsed: collapsed) },
                            onEdit: { editingMembership = resource },
                            onRemove: { archivingMembership = resource })
                // The full row height, so cards scrolling under it stay covered.
                .frame(width: KanbanUI.rowHeaderWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .stickyX(scroll)
                .zIndex(1)
            if collapsed {
                Text(columns.map { "\($0.name) \(snapshot.cards(in: $0.id, row: row.key).count)" }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(width: KanbanUI.columnWidth * CGFloat(columns.count), height: 44, alignment: .leading)
                    .accessibilityIdentifier("kanban-collapsed-\(row.name)")
            } else {
                ForEach(columns) { column in
                    KanbanCell(project: project, column: column, row: row,
                               tasks: snapshot.cards(in: column.id, row: row.key).compactMap { tasks[$0.id] },
                               onOpen: { editingTask = $0 },
                               onAdd: { addCard(in: column, row: row.key) })
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Scrolls to a revealed card, expanding its row first if it's collapsed.
    private func reveal(_ id: UUID?, proxy: ScrollViewProxy) async {
        guard let id, let task = project.tasks.first(where: { $0.id == id }) else { return }
        let row: KanbanRowKey = task.resource.flatMap { $0.archivedAt == nil ? .resource($0.id) : nil } ?? .unassigned
        if project.collapsedRowKeys.contains(row.storageKey) {
            app.runKanban { try app.kanbanService(context).setRowCollapsed(project, row, false) }
        }
        try? await Task.sleep(for: .milliseconds(150))   // let the card render first
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }

    private var addPersonButton: some View {
        Button { isAddingPerson = true } label: {
            Label("Add person", systemImage: "person.badge.plus")
        }
        .buttonStyle(.borderless)
        .padding(10)
        .stickyX(scroll)
        .accessibilityIdentifier("kanban-add-person")
    }

    private func addCard(in column: KanbanColumn, row: KanbanRowKey) {
        prompt = .init(title: "New card in \(column.name)", placeholder: "Title") { title in
            _ = try app.kanbanService(context).createTask(in: project, title: title, column: column, row: row)
        }
    }

    private func toggle(_ key: KanbanRowKey, collapsed: Bool) {
        let service = app.kanbanService(context)
        if NSEvent.modifierFlags.contains(.option) {
            app.runKanban { try service.setAllRowsCollapsed(project, !collapsed) }
        } else {
            app.runKanban { try service.setRowCollapsed(project, key, !collapsed) }
        }
    }

    // MARK: - Column headers

    private func columnHeaders(_ columns: [KanbanColumn], snapshot: BoardSnapshot, metrics: MetricsSnapshot) -> some View {
        HStack(spacing: 0) {
            Text(project.loadMeasure == .hours ? "People · hours this week" : "People · open tasks")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(width: KanbanUI.rowHeaderWidth, height: 40, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
                .stickyX(scroll)
                .zIndex(1)
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                let cards = snapshot.cards.filter { $0.columnID == column.id }
                let hours = metrics.cards.filter { $0.column == column.id && !$0.archived }.reduce(0) { $0 + KanbanMetrics.measure(metrics, $1) }
                KanbanColumnHeader(column: column, count: cards.count, hours: project.loadMeasure == .hours ? hours : nil)
                    .frame(width: KanbanUI.columnWidth, height: 40)
                    .contextMenu { columnMenu(column, index: index, count: columns.count) }
            }
            Button {
                prompt = .init(title: "New column", placeholder: "Name") { name in
                    _ = try app.kanbanService(context).addColumn(to: project, name: name, at: max(columns.count - 1, 0))
                }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .help("Add column")
            .accessibilityIdentifier("kanban-add-column")
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func columnMenu(_ column: KanbanColumn, index: Int, count: Int) -> some View {
        let service = app.kanbanService(context)
        Button("Rename…") {
            prompt = .init(title: "Rename column", initial: column.name) { try service.editColumn(column, name: $0) }
        }
        Menu("Colour") {
            Button("None") { app.runKanban { try service.editColumn(column, colorHex: .some(nil)) } }
            ForEach(TaskColor.allCases) { color in
                Button(String(describing: color).capitalized) { app.runKanban { try service.editColumn(column, colorHex: .some(color.hex)) } }
            }
        }
        Button("WIP limit…") {
            prompt = .init(title: "WIP limit for \(column.name)", initial: column.wipLimit.map(String.init) ?? "",
                           placeholder: "No limit", allowsEmpty: true) { text in
                guard !text.isEmpty else { return try service.editColumn(column, wipLimit: .some(nil)) }
                guard let limit = Int(text), limit > 0 else { throw KanbanServiceError.invariant("A WIP limit is a whole number above 0.") }
                try service.editColumn(column, wipLimit: .some(limit))
            }
        }
        Menu("Kind") {
            Button("Active") { app.runKanban { try service.editColumn(column, kind: .active) } }
                .disabled(column.kind == .active)
            Button("Done") { app.runKanban { try service.editColumn(column, kind: .done) } }
                .disabled(column.kind == .done)
            Button("Make this the backlog") { app.runKanban { try service.makeBacklog(column) } }
                .disabled(column.kind == .backlog)
        }
        Divider()
        Button("Move left") { app.runKanban { try service.reorderColumn(column, to: index - 1) } }
            .disabled(index == 0)
        Button("Move right") { app.runKanban { try service.reorderColumn(column, to: index + 1) } }
            .disabled(index == count - 1)
        Divider()
        Button("Delete…", role: .destructive) { columnToDelete = column }
    }
}

/// One cell: its cards in order, and a "+" on hover that adds a card here.
private struct KanbanCell: View {
    let project: KanbanProject
    let column: KanbanColumn
    let row: KanbanRowSnapshot
    let tasks: [KanbanTask]
    var onOpen: (KanbanTask) -> Void
    var onAdd: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            ForEach(tasks) { task in
                KanbanCardView(task: task, project: project, onOpen: { onOpen(task) }).id(task.id)
            }
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .help("Add a card here")
            .accessibilityLabel("Add a card to \(column.name), \(row.name)")
            .accessibilityIdentifier("kanban-add-card-\(column.name)-\(row.name)")
        }
        .padding(6)
        .frame(width: KanbanUI.columnWidth, alignment: .top)
        .frame(minHeight: 72, alignment: .top)
        .background((KanbanUI.color(column.colorHex) ?? .clear).opacity(0.06))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban-cell-\(column.name)-\(row.name)")
    }
}

/// The board's horizontal scroll offset, observed only by the views that stay put.
@MainActor @Observable
final class KanbanScrollOffset {
    var x: CGFloat = 0
}

private struct StickyX: ViewModifier {
    let scroll: KanbanScrollOffset
    func body(content: Content) -> some View { content.offset(x: scroll.x) }
}

private extension View {
    func stickyX(_ scroll: KanbanScrollOffset) -> some View { modifier(StickyX(scroll: scroll)) }
}

/// Name, count, `n/limit` (red when over) and, in hours mode, the column's hours.
struct KanbanColumnHeader: View {
    let column: KanbanColumn
    let count: Int
    let hours: Double?

    var body: some View {
        let over = column.wipLimit.map { count > $0 } ?? false
        HStack(spacing: 6) {
            Circle()
                .fill(KanbanUI.color(column.colorHex) ?? (column.kind == .done ? .green : .secondary))
                .frame(width: 8, height: 8)
            Text(column.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let limit = column.wipLimit {
                Text("\(count)/\(limit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(over ? .red : .secondary)
            } else {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let hours {
                Text("\(hours.formatted(.number.precision(.fractionLength(0...1))))h")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(column.name), \(count) cards\(column.wipLimit.map { ", limit \($0)" } ?? "")\(over ? ", over the limit" : "")")
        .accessibilityIdentifier("kanban-colhdr-\(column.name)")
    }
}

/// Moves a populated column's cards to another column, then deletes it.
struct KanbanDeleteColumnSheet: View {
    let column: KanbanColumn
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var targetID: UUID?
    @State private var error: String?

    var body: some View {
        let others = (column.project?.orderedColumns ?? []).filter { $0.id != column.id }
        let populated = column.project?.tasks.contains { $0.column?.id == column.id } ?? false
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(column.name)”?").font(.headline)
            if populated {
                Picker("Move its cards to", selection: $targetID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(others) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(width: 320)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    do {
                        try app.kanbanService(context).deleteColumn(column, movingTasksTo: others.first { $0.id == targetID })
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(populated && targetID == nil)
                .accessibilityIdentifier("kanban-delete-column")
            }
        }
        .padding(20)
    }
}
