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
    @State private var movingTask: KanbanTask?
    @State private var quickLook: UUID?
    @State private var drag = BoardDragController()
    @State private var position = ScrollPosition()
    @FocusState private var focus: KanbanBoardFocus?

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
        let _ = configureDrag(metrics: metrics, rowOrder: snapshot.rows.compactMap(\.resourceID))

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
            // A two-axis scroll view centres a board smaller than the window, leaving a band
            // above the headers and accessibility frames that don't match what's drawn.
            .defaultScrollAnchor(.topLeading)
            .accessibilityIdentifier("kanban-board")
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                scroll.x = max(0, geometry.contentOffset.x + geometry.contentInsets.leading)
                scroll.geometry = geometry
            }
            .publishBoardFrame { BoardFrames(viewport: $0) }
            .onPreferenceChange(BoardFramesKey.self) { frames in
                drag.frames = frames
                drag.framesChanged()
            }
            .overlay { BoardDragOverlay(controller: drag, project: project) }
            .onKeyPress(phases: .down) { press in handleKey(press, snapshot: snapshot, columns: columns, tasks: tasks) }
            // Runs on appear too: Attention sets the card before this board exists.
            .task(id: app.highlightedKanbanTaskID) { await reveal(app.highlightedKanbanTaskID, proxy: proxy) }
        }
        .sheet(item: $prompt) { KanbanTextPromptSheet(prompt: $0) }
        .sheet(item: $columnToDelete) { KanbanDeleteColumnSheet(column: $0) }
        .sheet(isPresented: $isAddingPerson) { KanbanAddPersonSheet(project: project) }
        .sheet(item: $editingMembership) { KanbanMembershipSheet(resource: $0) }
        .sheet(item: $editingTask) { KanbanTaskEditor(task: $0) }
        .sheet(item: $movingTask) { KanbanMoveSheet(task: $0) }
        .onAppear {
            app.kanbanBoardActions = KanbanBoardActions(projectID: project.id,
                undo: { [app, context, project] in app.runKanban { try app.kanbanService(context).undo(in: project) } },
                redo: { [app, context, project] in app.runKanban { try app.kanbanService(context).redo(in: project) } })
        }
        .onDisappear {
            drag.cancel()
            if app.kanbanBoardActions?.projectID == project.id { app.kanbanBoardActions = nil }
        }
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
            KanbanRowHeader(project: project, row: row, resource: resource, load: load, person: person, collapsed: collapsed, drag: drag,
                            onToggle: { toggle(row.key, collapsed: collapsed) },
                            onEdit: { editingMembership = resource },
                            onRemove: { archivingMembership = resource })
                // The full row height, so cards scrolling under it stay covered.
                .frame(width: KanbanUI.rowHeaderWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .opacity(resource.map { drag.isDragging(row: $0.id) } == true ? 0.4 : 1)
                .publishBoardFrame { BoardFrames(rowHeaders: [.init(row: row.key, frame: $0)]) }
                .modifier(RowHeaderDrag(resource: resource, row: row, drag: drag))
                .focusable(resource != nil)
                .focused($focus, equals: .row(resource?.id ?? KanbanBoardFocus.unfocusable))
                .stickyX(scroll)
                .zIndex(1)
            if collapsed {
                Text(columns.map { "\($0.name) \(snapshot.cards(in: $0.id, row: row.key).count)" }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(width: KanbanUI.columnWidth * CGFloat(columns.count), height: 44, alignment: .leading)
                    // Still a drop target: it reassigns the card and keeps its column.
                    .publishBoardFrame { BoardFrames(rowHeaders: [.init(row: row.key, frame: $0, isSummary: true)]) }
                    .accessibilityIdentifier("kanban-collapsed-\(row.name)")
            } else {
                ForEach(columns) { column in
                    KanbanCell(project: project, column: column, row: row,
                               tasks: snapshot.cards(in: column.id, row: row.key).compactMap { tasks[$0.id] },
                               drag: drag, focus: $focus, quickLook: $quickLook,
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

    /// Points the drag controller at this board (not observed state, so this redraws nothing).
    private func configureDrag(metrics: MetricsSnapshot, rowOrder: [UUID]) {
        drag.project = project
        drag.metrics = metrics
        if drag.rowOrder != rowOrder { drag.rowOrder = rowOrder }
        drag.commit = { [app, context, project] op in
            app.runKanban { _ = try app.kanbanService(context).move(op, in: project) }
        }
        drag.scrollBy = { [scroll, position = $position] delta in
            guard let geometry = scroll.geometry else { return }
            let maxX = max(0, geometry.contentSize.width - geometry.containerSize.width)
            let maxY = max(0, geometry.contentSize.height - geometry.containerSize.height)
            let x = min(max(geometry.contentOffset.x + delta.dx, 0), maxX)
            let y = min(max(geometry.contentOffset.y + delta.dy, 0), maxY)
            position.wrappedValue.scrollTo(point: CGPoint(x: x, y: y))
        }
    }

    // MARK: - Keyboard (design 01 §4): only while a card or header on the board has focus

    private func handleKey(_ press: KeyPress, snapshot: BoardSnapshot, columns: [KanbanColumn], tasks: [UUID: KanbanTask]) -> KeyPress.Result {
        let command = press.modifiers.contains(.command), option = press.modifiers.contains(.option)
        let service = app.kanbanService(context)
        func run(_ op: MoveOp) -> KeyPress.Result {
            app.runKanban { _ = try service.move(op, in: project) }
            return .handled
        }
        switch focus {
        case let .column(id)? where command && option:
            guard let index = columns.firstIndex(where: { $0.id == id }) else { return .ignored }
            if press.key == .leftArrow { return index > 0 ? run(.reorderColumn(id, toIndex: index - 1)) : .handled }
            if press.key == .rightArrow { return index < columns.count - 1 ? run(.reorderColumn(id, toIndex: index + 1)) : .handled }
            return .ignored
        case let .row(id)? where command && option:
            let order = snapshot.rows.compactMap(\.resourceID)
            guard let index = order.firstIndex(of: id) else { return .ignored }
            if press.key == .upArrow { return index > 0 ? run(.reorderRow(id, toIndex: index - 1)) : .handled }
            if press.key == .downArrow { return index < order.count - 1 ? run(.reorderRow(id, toIndex: index + 1)) : .handled }
            return .ignored
        case let .card(id)?:
            guard let task = tasks[id], let card = snapshot.cards.first(where: { $0.id == id }),
                  let columnIndex = columns.firstIndex(where: { $0.id == card.columnID }),
                  let rowIndex = snapshot.rows.firstIndex(where: { $0.key == card.row }) else { return .ignored }
            let siblings = snapshot.cards(in: card.columnID, row: card.row).map(\.id)
            let position = siblings.firstIndex(of: id) ?? 0
            switch (press.key, command, option) {
            case (.upArrow, true, true), (.leftArrow, true, true):
                return position > 0 ? run(.cards([id], to: .cell(columnID: card.columnID, row: card.row, beforeCardID: siblings[position - 1]))) : .handled
            case (.downArrow, true, true), (.rightArrow, true, true):
                guard position < siblings.count - 1 else { return .handled }
                let before = position + 2 < siblings.count ? siblings[position + 2] : nil
                return run(.cards([id], to: .cell(columnID: card.columnID, row: card.row, beforeCardID: before)))
            case (.leftArrow, true, false), (.rightArrow, true, false):
                let next = columnIndex + (press.key == .leftArrow ? -1 : 1)
                guard columns.indices.contains(next) else { return .handled }
                return run(.cards([id], to: .cell(columnID: columns[next].id, row: card.row, beforeCardID: nil)))
            case (.upArrow, true, false), (.downArrow, true, false):
                let next = rowIndex + (press.key == .upArrow ? -1 : 1)
                guard snapshot.rows.indices.contains(next) else { return .handled }
                return run(.cards([id], to: .rowHeader(snapshot.rows[next].key)))
            case (.upArrow, false, false), (.downArrow, false, false):
                let next = position + (press.key == .upArrow ? -1 : 1)
                if siblings.indices.contains(next) { focus = .card(siblings[next]) }
                return .handled
            case (.leftArrow, false, false), (.rightArrow, false, false):
                var index = columnIndex
                while true {
                    index += press.key == .leftArrow ? -1 : 1
                    guard columns.indices.contains(index) else { return .handled }
                    let cards = snapshot.cards(in: columns[index].id, row: card.row)
                    if !cards.isEmpty {
                        focus = .card(cards[min(position, cards.count - 1)].id)
                        return .handled
                    }
                }
            case (.return, false, false):
                editingTask = task
                return .handled
            case (.space, false, false):
                quickLook = quickLook == id ? nil : id
                return .handled
            default:
                if press.characters.lowercased() == "m", !command, !option {
                    movingTask = task
                    return .handled
                }
                return .ignored
            }
        default:
            return .ignored
        }
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
                .publishBoardFrame { BoardFrames(corner: $0) }   // inside the shift, so it reports where it's drawn
                .stickyX(scroll)
                .zIndex(1)
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                let cards = snapshot.cards.filter { $0.columnID == column.id }
                let hours = metrics.cards.filter { $0.column == column.id && !$0.archived }.reduce(0) { $0 + KanbanMetrics.measure(metrics, $1) }
                KanbanColumnHeader(column: column, count: cards.count, hours: project.loadMeasure == .hours ? hours : nil, drag: drag)
                    .frame(width: KanbanUI.columnWidth, height: 40)
                    .opacity(drag.isDragging(column: column.id) ? 0.4 : 1)
                    .publishBoardFrame { BoardFrames(columnHeaders: [.init(id: column.id, frame: $0)]) }
                    .boardDraggable(.column(column.id), controller: drag,
                                    frame: { drag.frames.columnHeaders.first { $0.id == column.id }?.frame }, title: column.name)
                    .focusable()
                    .focused($focus, equals: .column(column.id))
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
    var drag: BoardDragController
    var focus: FocusState<KanbanBoardFocus?>.Binding
    @Binding var quickLook: UUID?
    var onOpen: (KanbanTask) -> Void
    var onAdd: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            ForEach(tasks) { task in
                KanbanCardView(task: task, project: project, onOpen: { onOpen(task) })
                    .id(task.id)
                    .opacity(drag.isDragging(card: task.id) ? 0.001 : 1)
                    .publishBoardFrame { BoardFrames(cards: [.init(id: task.id, columnID: column.id, row: row.key, frame: $0)]) }
                    .boardDraggable(.cards([task.id]), controller: drag,
                                    frame: { drag.frames.cards.first { $0.id == task.id }?.frame }, task: task)
                    .focusable()
                    .focused(focus, equals: .card(task.id))
                    .popover(isPresented: Binding(get: { quickLook == task.id }, set: { if !$0 { quickLook = nil } })) {
                        KanbanQuickLook(task: task)
                    }
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
        // The full row height, so the blank space under short cells is a drop target too.
        .frame(minHeight: 72, maxHeight: .infinity, alignment: .top)
        .background((KanbanUI.color(column.colorHex) ?? .clear).opacity(0.06))
        .publishBoardFrame { BoardFrames(cells: [.init(columnID: column.id, row: row.key, frame: $0)]) }
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
    /// For auto-scroll; not observed.
    @ObservationIgnored var geometry: ScrollGeometry?
}

/// What has keyboard focus on a board.
enum KanbanBoardFocus: Hashable {
    case card(UUID)
    case column(UUID)
    case row(UUID)

    /// For the Unassigned header, which can't take focus.
    static let unfocusable = UUID()
}

/// Makes a membership's row header draggable to reorder rows (Unassigned stays put).
private struct RowHeaderDrag: ViewModifier {
    let resource: KanbanResource?
    let row: KanbanRowSnapshot
    let drag: BoardDragController

    func body(content: Content) -> some View {
        if let resource {
            content.boardDraggable(.row(resource.id), controller: drag,
                                   frame: { drag.frames.rowHeaders.first { $0.row == row.key && !$0.isSummary }?.frame }, title: row.name)
        } else {
            content
        }
    }
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
    var drag: BoardDragController?

    var body: some View {
        // Red while over its limit, or while a drag would put it over.
        let over = (column.wipLimit.map { count > $0 } ?? false) || drag?.wipNote?.columnID == column.id
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
