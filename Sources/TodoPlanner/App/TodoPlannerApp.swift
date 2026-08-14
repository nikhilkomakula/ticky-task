import SwiftUI
import SwiftData

/// Application entry point.
///
/// The persistent store is opened once at launch. On success the container is
/// injected into the scene; on failure a recovery UI is shown instead of
/// crashing (never a silent in-memory fallback, which would mislead the user
/// into thinking their data is being saved).
@main
struct TodoPlannerApp: App {
    private let containerResult: Result<ModelContainer, Error>

    init() {
        containerResult = Result { try ModelContainerProvider.makeContainer() }
    }

    var body: some Scene {
        WindowGroup {
            RootView(containerResult: containerResult)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}
