import SwiftUI
import SwiftData

extension AppState {
    /// Changes a board's remembered view state (view, filters, sort, Show Archived).
    func updateBoardState(_ project: KanbanProject, context: ModelContext, _ change: (inout KanbanBoardState) -> Void) {
        var state = KanbanBoardState.decode(project.boardState)
        change(&state)
        runKanban { try kanbanService(context).setBoardState(project, state.encoded()) }
    }
}

/// Board · List, Filter, Sort and Show Archived for the open board (design 01 §5). Filter,
/// Sort and Show Archived are tinted while they change what's shown.
struct KanbanViewControls: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var showFilter = false

    var body: some View {
        let state = KanbanBoardState.decode(project.boardState)
        HStack(spacing: 6) {
            Picker("View", selection: Binding(get: { state.view }, set: { view in app.updateBoardState(project, context: context) { $0.view = view } })) {
                Label("Board", systemImage: "square.grid.3x2").tag(KanbanBoardState.ViewKind.board)
                Label("List", systemImage: "list.bullet").tag(KanbanBoardState.ViewKind.list)
                Label("Timeline", systemImage: "chart.bar.xaxis").tag(KanbanBoardState.ViewKind.timeline)
                Label("Dashboard", systemImage: "chart.pie").tag(KanbanBoardState.ViewKind.dashboard)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("kanban-view-picker")

            Button { showFilter.toggle() } label: {
                Image(systemName: state.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(state.filter.isActive ? Color.accentColor : .primary)
            .frame(width: 28, height: 28)
            .help("Filter cards")
            .accessibilityLabel("Filter cards")
            .accessibilityIdentifier("kanban-filter")
            .popover(isPresented: $showFilter, arrowEdge: .bottom) { KanbanFilterPopover(project: project) }

            Menu {
                Picker("Sort", selection: Binding(get: { state.sort }, set: { sort in
                    app.updateBoardState(project, context: context) { $0.sort = sort; $0.listSortKey = nil }
                })) {
                    ForEach(KanbanBoardState.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .foregroundStyle(state.sort == .manual ? Color.primary : Color.accentColor)
            .fixedSize()
            .help("Sort cards: \(state.sort.label)")
            .accessibilityLabel("Sort cards")
            .accessibilityIdentifier("kanban-sort")

            Button {
                app.updateBoardState(project, context: context) { $0.showArchived.toggle() }
            } label: {
                Image(systemName: state.showArchived ? "archivebox.fill" : "archivebox")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(state.showArchived ? Color.accentColor : .primary)
            .frame(width: 28, height: 28)
            .help(state.showArchived ? "Hide archived cards" : "Show archived cards")
            .accessibilityIdentifier("kanban-show-archived")
        }
    }
}

/// The board's filters. Text applies on Return or when the popover closes; the rest apply at once.
struct KanbanFilterPopover: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @State private var text = ""

    var body: some View {
        let filter = KanbanBoardState.decode(project.boardState).filter
        Form {
            TextField("Title or notes", text: $text)
                .onSubmit(applyText)
                .accessibilityIdentifier("kanban-filter-text")
            Picker("Due", selection: binding(\.due, filter)) {
                Text("Any").tag(KanbanCardFilter.Due?.none)
                ForEach(KanbanCardFilter.Due.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            LabeledContent("Priority") {
                HStack {
                    ForEach(TaskPriority.allCases) { priority in
                        Toggle(priority.label, isOn: setBinding(\.priorities, priority.rawValue, filter))
                    }
                }
            }
            Toggle("Critical only", isOn: binding(\.criticalOnly, filter))
            Toggle("Open cards only", isOn: binding(\.openOnly, filter))
            Toggle("Blocked only", isOn: binding(\.blockedOnly, filter))
            LabeledContent("People") {
                VStack(alignment: .leading) {
                    Toggle("Unassigned", isOn: binding(\.unassigned, filter))
                    ForEach(project.resources.filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }) { resource in
                        Toggle(resource.displayName, isOn: setBinding(\.resourceIDs, resource.id, filter))
                    }
                }
            }
            LabeledContent("Labels") {
                VStack(alignment: .leading) {
                    ForEach(project.labels.sorted { $0.sortIndex < $1.sortIndex }) { label in
                        Toggle(label.name, isOn: setBinding(\.labelIDs, label.id, filter))
                    }
                    Button(action: { /* P4: open label manager */ }) {
                        Label("Edit labels…", systemImage: "tag")
                    }
                    .accessibilityIdentifier("kanban-filter-edit-labels")
                }
            }
            Picker("Jira link", selection: binding(\.hasJira, filter)) {
                Text("Either").tag(Bool?.none)
                Text("Has one").tag(Bool?.some(true))
                Text("Missing").tag(Bool?.some(false))
            }
            Picker("Estimate", selection: binding(\.hasEstimate, filter)) {
                Text("Either").tag(Bool?.none)
                Text("Has one").tag(Bool?.some(true))
                Text("Missing").tag(Bool?.some(false))
            }
            Button("Clear filters") {
                text = ""
                app.updateBoardState(project, context: context) { $0.filter = KanbanCardFilter() }
            }
            .disabled(!filter.isActive)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .frame(maxHeight: 560)
        .onAppear { text = filter.text }
        .onDisappear(perform: applyText)
    }

    private func applyText() {
        guard KanbanBoardState.decode(project.boardState).filter.text != text else { return }
        app.updateBoardState(project, context: context) { $0.filter.text = text }
    }

    private func binding<V>(_ path: WritableKeyPath<KanbanCardFilter, V>, _ filter: KanbanCardFilter) -> Binding<V> {
        Binding(get: { filter[keyPath: path] }, set: { value in app.updateBoardState(project, context: context) { $0.filter[keyPath: path] = value } })
    }

    private func setBinding<E: Hashable>(_ path: WritableKeyPath<KanbanCardFilter, Set<E>>, _ element: E, _ filter: KanbanCardFilter) -> Binding<Bool> {
        Binding(get: { filter[keyPath: path].contains(element) }, set: { on in
            app.updateBoardState(project, context: context) { state in
                if on { state.filter[keyPath: path].insert(element) } else { state.filter[keyPath: path].remove(element) }
            }
        })
    }
}

/// The second tier: one chip per active filter, each removable, and Clear.
struct KanbanFilterChips: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        let filter = KanbanBoardState.decode(project.boardState).filter
        if filter.isActive {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips(filter), id: \.label) { chip in
                        Button { app.updateBoardState(project, context: context) { chip.remove(&$0.filter) } } label: {
                            HStack(spacing: 4) {
                                Text(chip.label)
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove filter \(chip.label)")
                        .accessibilityIdentifier("kanban-chip-\(chip.label)")
                    }
                    Button("Clear") { app.updateBoardState(project, context: context) { $0.filter = KanbanCardFilter() } }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("kanban-clear-filters")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private struct Chip {
        var label: String
        var remove: (inout KanbanCardFilter) -> Void
    }

    private func chips(_ f: KanbanCardFilter) -> [Chip] {
        var chips: [Chip] = []
        if !f.text.isEmpty { chips.append(Chip(label: "“\(f.text)”") { $0.text = "" }) }
        if let due = f.due { chips.append(Chip(label: due.label) { $0.due = nil }) }
        for p in f.priorities.sorted() {
            chips.append(Chip(label: TaskPriority(rawValue: p)?.label ?? "\(p)") { $0.priorities.remove(p) })
        }
        if f.criticalOnly { chips.append(Chip(label: "Critical") { $0.criticalOnly = false }) }
        if f.blockedOnly { chips.append(Chip(label: "Blocked") { $0.blockedOnly = false }) }
        if f.unassigned { chips.append(Chip(label: "Unassigned") { $0.unassigned = false }) }
        for resource in project.resources where f.resourceIDs.contains(resource.id) {
            chips.append(Chip(label: resource.displayName) { $0.resourceIDs.remove(resource.id) })
        }
        for label in project.labels where f.labelIDs.contains(label.id) {
            chips.append(Chip(label: label.name) { $0.labelIDs.remove(label.id) })
        }
        if let jira = f.hasJira { chips.append(Chip(label: jira ? "Has Jira" : "No Jira") { $0.hasJira = nil }) }
        if let estimate = f.hasEstimate { chips.append(Chip(label: estimate ? "Has estimate" : "No estimate") { $0.hasEstimate = nil }) }
        if f.openOnly { chips.append(Chip(label: "Open only") { $0.openOnly = false }) }
        if f.excludeCritical { chips.append(Chip(label: "Not Critical") { $0.excludeCritical = false }) }
        for column in project.orderedColumns where f.columnIDs.contains(column.id) {
            chips.append(Chip(label: column.name) { $0.columnIDs.remove(column.id) })
        }
        return chips
    }
}
