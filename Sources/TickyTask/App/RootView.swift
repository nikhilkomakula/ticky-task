import SwiftUI
import SwiftData

/// Attaches the SwiftData container to its content on success, or shows a
/// recoverable error UI if the persistent store failed to open. Shared by every
/// scene that needs data (main window, menu bar, quick capture). Never silently
/// falls back to an in-memory store.
struct ContainerGate<Content: View>: View {
    let containerResult: Result<ModelContainer, Error>
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch containerResult {
        case .success(let container):
            content().modelContainer(container)
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
        .frame(minWidth: 420, minHeight: 280)
        .padding(40)
    }
}
