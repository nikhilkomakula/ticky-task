import SwiftUI
import SwiftData

/// The quick-capture window opened by the global "New task for today" shortcut.
/// Shows the full task editor in create mode, initially dated today.
struct QuickCaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        TaskEditorView(newTaskWithDayKey: WeekMath.dayKey(for: Date()))
            .onDisappear {
                dismissWindow(id: "quickCapture")
            }
    }
}
