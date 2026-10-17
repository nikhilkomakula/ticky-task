import SwiftUI
import SwiftData
import AppKit

/// Application entry point.
///
/// The persistent store is opened once at launch and shared (via `ContainerGate`)
/// across the main window, the menu-bar popover, and the quick-capture window.
/// `AppState` is likewise shared so selection stays in sync. On store-open
/// failure a recovery UI is shown instead of crashing.
@main
struct TickyTaskApp: App {
    @State private var appState: AppState
    /// User-chosen menu-bar icon (SF Symbol name); defaults to a calendar+task glyph.
    /// Configurable in Settings › Appearance. SwiftUI re-evaluates the scene when
    /// this changes, so the icon updates live.
    @AppStorage("menuBarIcon") private var menuBarIcon = "calendar.badge.checkmark"
    private let containerResult: Result<ModelContainer, Error>

    init() {
        // Tests run against an isolated store so real data is never touched.
        if let url = UITestSupport.diskStoreURL {
            containerResult = Result { try ModelContainerProvider.makeContainer(at: url) }
        } else if UITestSupport.isRunning || UITestSupport.isHostingUnitTests {
            containerResult = .success(ModelContainerProvider.makeInMemoryContainer())
            // Hosting unit tests: stay out of the Dock and never take focus from the user.
            if UITestSupport.isHostingUnitTests { NSApplication.shared.setActivationPolicy(.prohibited) }
        } else {
            containerResult = Result { try ModelContainerProvider.makeContainer() }
        }
        let state = AppState()
        // Due-date reminders follow every board change, even with the main window closed.
        if case let .success(container) = containerResult {
            state.kanbanGeneration.onBump = {
                Task { @MainActor in await NotificationService.syncKanbanReminders(context: container.mainContext) }
            }
        }
        _appState = State(initialValue: state)
    }

    var body: some Scene {
        Window("TickyTask", id: "main") {
            ContainerGate(containerResult: containerResult) { ContentView() }
                .environment(appState)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .textEditing) {
                FindTaskCommand(appState: appState)
                WeeklySummaryCommand(appState: appState)
                NewItemCommand(appState: appState)
            }
            CommandGroup(after: .help) {
                ShortcutsCommand(appState: appState)
            }
            CommandGroup(replacing: .undoRedo) {
                KanbanUndoCommands(appState: appState)
            }
            CommandGroup(before: .toolbar) {
                ModuleCommand(appState: appState, module: .planner, key: "1")
                ModuleCommand(appState: appState, module: .kanban, key: "2")
                Divider()
            }
        }

        MenuBarExtra("TickyTask", systemImage: menuBarIcon) {
            ContainerGate(containerResult: containerResult) { MenuBarContentView() }
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Window("New Task", id: "quickCapture") {
            ContainerGate(containerResult: containerResult) { QuickCaptureView() }
                .environment(appState)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)   // opened on demand via the global shortcut

        Settings {
            ContainerGate(containerResult: containerResult) { SettingsView() }
                .environment(appState)
        }
    }
}

/// The ⌘F "Find Task" menu command. Opens/activates the main window before
/// presenting search, so it works even if that window is closed or another
/// window (e.g. quick-capture) is key.
private struct FindTaskCommand: View {
    @Environment(\.openWindow) private var openWindow
    let appState: AppState

    var body: some View {
        Button("Find Task…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            appState.isSearchPresented = true
        }
        .keyboardShortcut("f", modifiers: .command)
    }
}

/// Help › Keyboard Shortcuts (⌘/): the sheet lives on the main window, so open it first.
private struct ShortcutsCommand: View {
    @Environment(\.openWindow) private var openWindow
    let appState: AppState

    var body: some View {
        Button("Keyboard Shortcuts") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            appState.isShortcutsPresented = true
        }
        .keyboardShortcut("/", modifiers: .command)
    }
}

/// View › Planner (⌘1) / Kanban (⌘2); disabled while the module is hidden.
private struct ModuleCommand: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ModulePolicy.showPlannerKey) private var showPlanner = true
    @AppStorage(ModulePolicy.showKanbanKey) private var showKanban = true
    let appState: AppState
    let module: AppModule
    let key: KeyEquivalent

    var body: some View {
        Button(module.label) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            appState.module = module
        }
        .keyboardShortcut(key, modifiers: .command)
        .disabled(!ModulePolicy(showPlanner: showPlanner, showKanban: showKanban).isVisible(module))
    }
}

/// The ⇧⌘Y "Weekly Summary…" menu command; like Find, it brings the main window
/// forward first so the sheet has somewhere to appear.
private struct WeeklySummaryCommand: View {
    @Environment(\.openWindow) private var openWindow
    let appState: AppState

    var body: some View {
        Button("Weekly Summary…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            appState.isWeeklySummaryPresented = true
        }
        .keyboardShortcut("y", modifiers: [.command, .shift])
    }
}

/// The ⌘N "New item" command: creates a new task in Planner or a new card in Kanban,
/// based on the visible module. In Kanban, disabled when no board is active.
private struct NewItemCommand: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ModulePolicy.showPlannerKey) private var showPlanner = true
    @AppStorage(ModulePolicy.showKanbanKey) private var showKanban = true
    let appState: AppState

    var body: some View {
        let policy = ModulePolicy(showPlanner: showPlanner, showKanban: showKanban)
        let module = policy.resolve(appState.module)
        let isKanbanWithActiveBoard = module == .kanban && isActiveBoard()

        Button(module == .planner ? "New Task" : "New Card") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            if module == .planner {
                appState.presentPlannerNewTask()
            } else {
                appState.presentKanbanNewCard()
            }
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(module == .kanban && !isKanbanWithActiveBoard)
    }

    /// Commands get no model context, so the Kanban module publishes the board it shows.
    private func isActiveBoard() -> Bool {
        if case let .project(projectID) = appState.kanban.selection { return appState.kanbanActiveBoardID == projectID }
        return false
    }
}
