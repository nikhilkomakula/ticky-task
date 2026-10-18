import SwiftUI
import SwiftData

/// Two-row window header replacing the original single TopToolbar.
struct MainWindowHeader: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings
    @AppStorage(ModulePolicy.showPlannerKey) private var showPlanner = true
    @AppStorage(ModulePolicy.showKanbanKey) private var showKanban = true

    var onSearch: () -> Void = {}
    var onWeeklySummary: () -> Void = {}
    var onNewTask: () -> Void = {}
    var onNewCard: () -> Void = {}

    var body: some View {
        @Bindable var app = app
        let policy = ModulePolicy(showPlanner: showPlanner, showKanban: showKanban)
        let module = policy.resolve(app.module)

        VStack(spacing: 0) {
            // Row 1: Centered module switcher + Settings
            ZStack(alignment: .center) {
                // Center the module switcher or module name
                if policy.showsSwitcher {
                    Picker("Modules", selection: $app.module) {
                        ForEach(policy.visible) { m in
                            Label(m.label, systemImage: m.symbol).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Planner / Kanban per segment; Modules on picker")
                    .accessibilityIdentifier("module-switcher")
                } else {
                    Text(module.label)
                        .font(.headline.weight(.semibold))
                }
                // Overlay Settings on the trailing edge
                HStack {
                    Spacer()
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .help("Settings")
                    .accessibilityIdentifier("toolbar-settings")
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 44)

            Divider()

            // Row 2: Module-specific
            HStack(spacing: 12) {
                switch module {
                case .planner:
                    PlannerRow2View(onSearch: onSearch, onWeeklySummary: onWeeklySummary, onNewTask: onNewTask)
                case .kanban:
                    KanbanRow2View(onSearch: onSearch, onNewCard: onNewCard)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 12)

            Divider()
        }
    }
}

/// Planner row 2 as a separate view for cleaner separation.
private struct PlannerRow2View: View {
    @Environment(AppState.self) private var app
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @AppStorage("calendarColumns") private var calendarColumns = 5
    @AppStorage("showWeekends") private var showWeekends = false

    let onSearch: () -> Void
    let onWeeklySummary: () -> Void
    let onNewTask: () -> Void

    private var columns: Int { max(1, min(12, calendarColumns)) }

    var body: some View {
        // Week | Month picker
        Picker("View", selection: Binding(get: { app.viewMode }, set: { app.viewMode = $0 })) {
            ForEach(ViewMode.allCases) { mode in
                Label(mode.label, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Week / Month per segment; Planner view on picker")
        .accessibilityIdentifier("planner-view-picker")

        Divider()
            .frame(height: 24)

        // Previous
        Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help(app.viewMode == .week ? "Previous week" : "Previous month")
            .accessibilityIdentifier("toolbar-previous")

        // Today
        Button("Today") { app.goToToday() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Today")
            .accessibilityIdentifier("toolbar-today")

        // Next
        Button { navigate(1) } label: { Image(systemName: "chevron.right") }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help(app.viewMode == .week ? "Next week" : "Next month")
            .accessibilityIdentifier("toolbar-next")

        // Period text
        Text(navLabel)
            .font(.headline.weight(.semibold))
            .lineLimit(1)

        Spacer()

        // Search
        Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .help("Search tasks")
        .accessibilityIdentifier("toolbar-search")

        // Weekly Summary
        Button(action: onWeeklySummary) {
            Image(systemName: "text.badge.star")
        }
        .buttonStyle(.borderless)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .help("Weekly Summary")
        .accessibilityLabel("Weekly Summary")
        .accessibilityIdentifier("toolbar-weekly-summary")

        // + New task
        Button(action: onNewTask) {
            Label("Task", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .frame(height: 28)
        .help("New task")
        .accessibilityIdentifier("toolbar-new-task")
    }

    private func navigate(_ delta: Int) {
        switch app.viewMode {
        case .week:
            if delta < 0 { app.previousWeek() } else { app.nextWeek() }
        case .calendar:
            if delta < 0 { app.previousMonth() } else { app.nextMonth() }
        }
    }

    private var navLabel: String {
        switch app.viewMode {
        case .week:
            let days = app.weekDays(columns: columns, weekStartsMonday: weekStartsMonday, showWeekends: showWeekends)
            guard let first = days.first, let last = days.last else { return "" }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) - \(last.formatted(.dateTime.month(.abbreviated).day()))"
        case .calendar:
            return app.weekAnchor.formatted(.dateTime.month(.wide).year())
        }
    }
}

/// Kanban row 2 as a separate view, so @Query sits at struct level.
private struct KanbanRow2View: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \KanbanProject.sortIndex) private var projects: [KanbanProject]

    let onSearch: () -> Void
    let onNewCard: () -> Void

    var body: some View {
        let isActiveBoard = kanbanHasActiveBoard()

        // Sidebar toggle
        Button { app.kanban.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help(app.kanban.showSidebar ? "Hide sidebar" : "Show sidebar")
            .accessibilityIdentifier("kanban-toggle-sidebar")

        // Breadcrumb
        Text(kanbanBreadcrumb())
            .font(.headline.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: 120)
            .accessibilityIdentifier("kanban-breadcrumb")

        if isActiveBoard {
            Divider()
                .frame(height: 24)

            if let project = projects.first(where: { projectMatches($0) }) {
                KanbanViewControls(project: project)
                let onAvailability = KanbanBoardState.decode(project.boardState).view == .availability

                // Expand rows menu
                if !onAvailability {
                Menu {
                    Button("Expand all rows") { setAll(project, collapsed: false) }
                        .keyboardShortcut(.downArrow, modifiers: [.control, .command])
                    Button("Collapse all rows") { setAll(project, collapsed: true) }
                        .keyboardShortcut(.upArrow, modifiers: [.control, .command])
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Expand or collapse rows")
                .accessibilityIdentifier("kanban-expand-collapse")
                }

                Spacer()

                // Search
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help("Search tasks")
                .accessibilityIdentifier("toolbar-search")

                // Board actions menu
                Menu {
                    Button(action: { app.kanbanBoardSettingsProjectID = project.id }) {
                        Label("Board settings…", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("kanban-board-settings")
                    Button(action: { app.kanbanLabelManagerProjectID = project.id }) {
                        Label("Edit labels", systemImage: "tag")
                    }
                    .accessibilityIdentifier("kanban-edit-labels")
                    Button(action: { app.kanbanArchiveDoneProjectID = project.id }) {
                        Label("Archive done cards…", systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("kanban-archive-done")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help("Board actions")
                .accessibilityIdentifier("kanban-board-actions")

                // Change Log
                Button { app.kanbanChangeLogProjectID = project.id } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .help("Change Log")
                    .accessibilityIdentifier("kanban-change-log")

                // Kanban Summary
                Button { app.kanbanSummaryProjectID = project.id } label: { Image(systemName: "text.badge.star") }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .help("Kanban Summary")
                    .accessibilityLabel("Kanban Summary")
                    .accessibilityIdentifier("kanban-summary")

                // + Card
                if !onAvailability {
                Button(action: onNewCard) {
                    Label("Card", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .frame(height: 28)
                .help("New card")
                .accessibilityIdentifier("kanban-new-card")
                }
            }
        } else {
            Spacer()
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help("Search tasks")
            .accessibilityIdentifier("toolbar-search")
        }
    }

    private func kanbanBreadcrumb() -> String {
        switch app.kanban.selection {
        case .attention: "Attention"
        case .allProjects: "All projects"
        case let .project(id): "All projects > " + (projects.first { $0.id == id }?.name ?? "")
        }
    }

    private func kanbanHasActiveBoard() -> Bool {
        if case .project = app.kanban.selection { true } else { false }
    }

    private func projectMatches(_ project: KanbanProject) -> Bool {
        if case let .project(id) = app.kanban.selection { project.id == id } else { false }
    }

    private func setAll(_ project: KanbanProject, collapsed: Bool) {
        app.runKanban { try app.kanbanService(context).setAllRowsCollapsed(project, collapsed) }
    }
}
