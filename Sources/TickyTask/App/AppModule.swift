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
}
