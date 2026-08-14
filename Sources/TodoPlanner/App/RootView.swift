import SwiftUI
import SwiftData

/// Injects the SwiftData container + shared `AppState` on success, or shows a
/// recoverable error UI if the persistent store failed to open. Never silently
/// falls back to an in-memory store — that would mislead the user into thinking
/// data is saved.
struct RootView: View {
    let containerResult: Result<ModelContainer, Error>
    @State private var appState = AppState()

    var body: some View {
        switch containerResult {
        case .success(let container):
            ContentView()
                .environment(appState)
                .modelContainer(container)
        case .failure(let error):
            StoreErrorView(error: error)
        }
    }
}

/// Shown when the persistent store cannot be opened.
struct StoreErrorView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.red)
            Text("Couldn't open your data store")
                .font(.title2.weight(.semibold))
            Text(error.localizedDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Quit and relaunch. If this keeps happening, restore from a backup.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding(40)
    }
}
