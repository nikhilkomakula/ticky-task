import SwiftUI
import SwiftData

/// The Kanban module: the board sidebar beside the selected board, the All projects
/// overview or the Attention list (design 01 §5).
struct KanbanModuleView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \KanbanProject.sortIndex) private var projects: [KanbanProject]

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            if app.kanban.showSidebar {
                KanbanSidebar(projects: projects)
                    .frame(width: 230)
                Divider()
            }
            Group {
                switch app.kanban.selection {
                case .attention:
                    KanbanAttentionView(projects: projects.filter { $0.archivedAt == nil })
                case .allProjects:
                    KanbanAllProjectsView(projects: projects)
                case let .project(id):
                    if let project = projects.first(where: { $0.id == id }) {
                        KanbanBoardView(project: project, allProjects: projects)
                    } else {
                        ContentUnavailableView("Board not found", systemImage: "square.grid.3x2",
                                               description: Text("It may have been deleted."))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Can’t make that change", isPresented: Binding(get: { app.kanbanError != nil }, set: { if !$0 { app.kanbanError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.kanbanError ?? "")
        }
    }
}

extension AppState {
    func kanbanService(_ context: ModelContext) -> KanbanService {
        KanbanService(context, history: kanbanHistory, generation: kanbanGeneration)
    }

    /// Runs a board change, showing why it was refused or failed.
    func runKanban(_ change: () throws -> Void) {
        do { try change() } catch { kanbanError = error.localizedDescription }
    }
}

enum KanbanUI {
    static let rowHeaderWidth: CGFloat = 230
    static let columnWidth: CGFloat = 250

    /// The user's calendar with their week start, for the metrics.
    static func calendar(weekStartsMonday: Bool) -> Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsMonday ? 2 : 1
        return calendar
    }

    static func color(_ hex: String?) -> Color? { hex.flatMap { Color(hex: $0) } }

    static func bandColor(_ band: KanbanMetrics.Band?) -> Color {
        switch band {
        case .green: .green
        case .amber: .orange
        case .red: .red
        case nil: .secondary
        }
    }

    /// The band's colour; no capacity is red when there's work, neutral when there isn't.
    static func utilisationColor(_ utilisation: KanbanMetrics.Utilisation?) -> Color {
        switch utilisation {
        case let .ratio(_, band)?: bandColor(band)
        case let .noCapacity(load)?: load > 0 ? .red : .secondary
        case nil: .secondary
        }
    }

    /// "3 of 5 open tasks (60%)", or hours in hours mode.
    static func loadText(load: Double, target: Double?, utilisation: KanbanMetrics.Utilisation?, hours: Bool) -> String {
        let unit = hours ? "h this week" : "open tasks"
        let amount = load.formatted(.number.precision(.fractionLength(0...1)))
        guard let target else { return "\(amount) \(unit)" }
        let of = target.formatted(.number.precision(.fractionLength(0...1)))
        switch utilisation {
        case let .ratio(u, _)?: return "\(amount) of \(of) \(unit) (\(Int((u * 100).rounded()))%)"
        default: return "\(amount) \(unit), no capacity set"
        }
    }
}

/// Toolbar, leading: sidebar toggle and the breadcrumb.
struct KanbanToolbarLeading: View {
    @Environment(AppState.self) private var app
    @Query(sort: \KanbanProject.sortIndex) private var projects: [KanbanProject]

    var body: some View {
        HStack(spacing: 8) {
            Button { app.kanban.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help(app.kanban.showSidebar ? "Hide sidebar" : "Show sidebar")
                .accessibilityIdentifier("kanban-toggle-sidebar")
            Text(breadcrumb)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("kanban-breadcrumb")
        }
    }

    private var breadcrumb: String {
        switch app.kanban.selection {
        case .attention: "Attention"
        case .allProjects: "All projects"
        case let .project(id): "All projects › " + (projects.first { $0.id == id }?.name ?? "")
        }
    }
}

/// Toolbar, trailing (before the global buttons): row expand/collapse for the open board.
struct KanbanToolbarTrailing: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \KanbanProject.sortIndex) private var projects: [KanbanProject]

    var body: some View {
        if case let .project(id) = app.kanban.selection, let project = projects.first(where: { $0.id == id }) {
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
            .help("Expand or collapse rows (⌃⌘↓ / ⌃⌘↑)")
            .accessibilityIdentifier("kanban-expand-collapse")
        }
    }

    private func setAll(_ project: KanbanProject, collapsed: Bool) {
        app.runKanban { try app.kanbanService(context).setAllRowsCollapsed(project, collapsed) }
    }
}
