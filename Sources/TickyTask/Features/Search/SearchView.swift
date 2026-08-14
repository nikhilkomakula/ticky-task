import SwiftUI
import SwiftData

/// A search sheet over every task. Type to filter by title or notes; pick a
/// result to jump to it — the app navigates to the task's day (or list) and
/// briefly flashes its row in place. Reachable from the toolbar button or ⌘F.
struct SearchView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var allTasks: [TaskItem]
    @State private var query = ""
    @FocusState private var focused: Bool

    // Unassigned tasks (no day and no list) aren't shown anywhere in the app, so
    // there's nowhere to navigate to — exclude them from results.
    private var results: [TaskItem] {
        TaskSearch.rank(allTasks.filter { $0.dayKey != nil || $0.customList != nil }, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .frame(width: 540, height: 480)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search all tasks", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit(openFirst)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Button("Done", action: dismiss.callAsFunction)
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
        .onAppear { focused = true }
    }

    @ViewBuilder private var content: some View {
        if TaskSearch.normalize(query).isEmpty {
            hint("Type to search across every task by title or notes.")
        } else if results.isEmpty {
            hint("No tasks match “\(query)”.")
        } else {
            List(results) { task in
                SearchResultRow(task: task, query: query)
                    .contentShape(Rectangle())
                    .onTapGesture { open(task) }
            }
            .listStyle(.inset)
        }
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openFirst() {
        if let first = results.first { open(first) }
    }

    /// Jump to the task in place: reveal it (week view, select + flash its day/
    /// row), then close search. No second sheet, so nothing to race.
    private func open(_ task: TaskItem) {
        app.reveal(task)
        dismiss()
    }
}

/// One search hit: priority glyph, title, and a location line (day or list) with
/// a notes snippet when the match came from the notes.
private struct SearchResultRow: View {
    let task: TaskItem
    let query: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.priorityLevel.symbol)
                .font(.system(size: 12))
                .foregroundStyle(task.priorityLevel.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "Untitled" : task.title)
                    .font(.body)
                    .lineLimit(1)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                HStack(spacing: 6) {
                    Label(locationLabel, systemImage: locationSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !snippet.isEmpty {
                        Text("· \(snippet)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if task.isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var locationLabel: String {
        if let name = task.customList?.name { return name }
        if let key = task.dayKey, let date = WeekMath.date(fromDayKey: key) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return "Unscheduled"
    }

    private var locationSymbol: String {
        if task.customList != nil { return "list.bullet" }
        if task.dayKey != nil { return "calendar" }
        return "tray"
    }

    /// A short notes excerpt, shown only when the title itself didn't match.
    private var snippet: String {
        let q = TaskSearch.normalize(query)
        guard !q.isEmpty, !task.title.localizedCaseInsensitiveContains(q), !task.notes.isEmpty else { return "" }
        return String(task.notes.replacingOccurrences(of: "\n", with: " ").prefix(80))
    }
}
