import SwiftUI
import SwiftData

/// Application entry point.
///
/// The persistent store is opened once at launch and shared (via `ContainerGate`)
/// across the main window, the menu-bar popover, and the quick-capture window.
/// `AppState` is likewise shared so selection stays in sync. On store-open
/// failure a recovery UI is shown instead of crashing.
@main
struct TodoPlannerApp: App {
    @State private var appState = AppState()
    private let containerResult: Result<ModelContainer, Error>

    init() {
        containerResult = Result { try ModelContainerProvider.makeContainer() }
    }

    var body: some Scene {
        Window("TodoPlanner", id: "main") {
            ContainerGate(containerResult: containerResult) { ContentView() }
                .environment(appState)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)

        MenuBarExtra("TodoPlanner", systemImage: "checklist") {
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
            SettingsView()
        }
    }
}
