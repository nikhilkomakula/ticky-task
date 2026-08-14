import SwiftUI
import SwiftData

/// The quick-capture window opened by the global "New task for today" shortcut.
/// Adds a task to today and closes.
struct QuickCaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var title = ""
    @State private var errorText: String?

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New task for today")
                .font(.headline)
            TextField("What needs doing?", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        do {
            let service = DataService(context)
            try service.addTask(title: trimmed, location: .day(WeekMath.dayKey(for: Date())))
            try service.save()
            title = ""
            close()
        } catch {
            errorText = "Couldn't save the task. Please try again."
        }
    }

    private func close() {
        dismissWindow(id: "quickCapture")
    }
}
