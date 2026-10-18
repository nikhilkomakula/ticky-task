import Foundation

/// The two halves of the main window (design 01 §3).
enum AppModule: String, CaseIterable, Identifiable, Sendable {
    case planner, kanban

    var id: String { rawValue }
    var label: String { self == .planner ? "Planner" : "Kanban" }
    var symbol: String { self == .planner ? "calendar" : "square.grid.3x2" }
}

/// Which modules are visible. At least one always is: hiding both shows the planner.
struct ModulePolicy: Equatable, Sendable {
    /// The keys the settings backup already carries (`AppSettingsDTO`).
    static let showPlannerKey = "showPlannerModule"
    static let showKanbanKey = "showKanbanModule"

    let showPlanner: Bool
    let showKanban: Bool

    init(showPlanner: Bool = true, showKanban: Bool = true) {
        self.showPlanner = showPlanner || !showKanban
        self.showKanban = showKanban
    }

    init(_ defaults: UserDefaults) {
        self.init(showPlanner: defaults.bool(forKey: Self.showPlannerKey, default: true),
                  showKanban: defaults.bool(forKey: Self.showKanbanKey, default: true))
    }

    var visible: [AppModule] { AppModule.allCases.filter(isVisible) }
    var showsSwitcher: Bool { visible.count > 1 }

    func isVisible(_ module: AppModule) -> Bool { module == .planner ? showPlanner : showKanban }

    /// `requested` if it's visible, otherwise the first visible module.
    func resolve(_ requested: AppModule) -> AppModule { isVisible(requested) ? requested : visible[0] }

    /// Whether `module`'s toggle may be turned off: never the last visible one.
    func canHide(_ module: AppModule) -> Bool { isVisible(module) && visible.count > 1 }

    /// Whether `module`'s toggle is locked: only the last visible one is; a hidden one can come back.
    func isLocked(_ module: AppModule) -> Bool { isVisible(module) && !canHide(module) }
}

/// What the Kanban sidebar has selected.
enum KanbanSidebarItem: Hashable, Sendable {
    case attention
    case allProjects
    case project(UUID)
}

/// The Kanban module's navigation state for this session.
struct KanbanNavigation: Equatable, Sendable {
    var selection: KanbanSidebarItem = .allProjects
    var showSidebar = true
    /// Whether the module has opened its default board this session.
    var openedDefault = false
}

/// Settings › Kanban › Default board: where the Kanban module opens each session.
enum KanbanDefaultBoard {
    /// A board's id, `allProjects`, or empty or missing for the last opened board.
    static let key = "kanban.defaultBoard"
    static let allProjects = "allProjects"

    /// The chosen board, or All projects if that's chosen. Otherwise, or when the chosen board
    /// is gone or archived, the last opened board, then the first in the sidebar (pinned
    /// first); with no boards, All projects.
    static func item(_ projects: [KanbanProject], choice: String?, lastOpened: String?) -> KanbanSidebarItem {
        if choice == allProjects { return .allProjects }
        let live = projects.filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
        for id in [choice, lastOpened].compactMap({ $0.flatMap(UUID.init(uuidString:)) }) where live.contains(where: { $0.id == id }) {
            return .project(id)
        }
        let first = live.first(where: \.isPinned) ?? live.first
        return first.map { .project($0.id) } ?? .allProjects
    }
}
