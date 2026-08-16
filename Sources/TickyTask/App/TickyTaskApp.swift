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
    @State private var appState = AppState()
    /// User-chosen menu-bar icon (SF Symbol name); defaults to a calendar+task glyph.
    /// Configurable in Settings › Appearance. SwiftUI re-evaluates the scene when
    /// this changes, so the icon updates live.
    @AppStorage("menuBarIcon") private var menuBarIcon = "calendar.badge.checkmark"
    private let containerResult: Result<ModelContainer, Error>

    init() {
        // UI tests run against an isolated in-memory store so real data is never touched.
        if UITestSupport.isRunning {
            containerResult = .success(ModelContainerProvider.makeInMemoryContainer())
        } else {
            containerResult = Result { try ModelContainerProvider.makeContainer() }
        }
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
