import SwiftUI

/// The default view: `calendarColumns` day columns for the anchored week, with
/// a navigation toolbar. Week start (Mon/Sun) and column count come from
/// persisted settings.
struct WeekView: View {
    @Environment(AppState.self) private var app
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @AppStorage("calendarColumns") private var calendarColumns = 5
    @State private var editingTask: TaskItem?

    private var columns: Int { max(1, min(12, calendarColumns)) }

    var body: some View {
        let days = app.weekDays(columns: columns, weekStartsMonday: weekStartsMonday)
        VStack(spacing: 0) {
            WeekToolbar(days: days)
            Divider()
            VSplitView {
                HStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        DayColumnView(date: day) { editingTask = $0 }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if index < days.count - 1 { Divider() }
                    }
                }
                .frame(minHeight: 220, idealHeight: 440)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Lists")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                    CustomListsRow { editingTask = $0 }
                }
                .frame(minHeight: 140, idealHeight: 200)
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task)
        }
    }
}

/// Week navigation: previous/today/next plus the visible date range.
private struct WeekToolbar: View {
    @Environment(AppState.self) private var app
    let days: [Date]

    var body: some View {
        HStack(spacing: 12) {
            Button { app.previousWeek() } label: { Image(systemName: "chevron.left") }
                .help("Previous week")
            Button("Today") { app.goToToday() }
            Button { app.nextWeek() } label: { Image(systemName: "chevron.right") }
                .help("Next week")
            Spacer()
            if let first = days.first, let last = days.last {
                Text("\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.headline)
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .padding(8)
    }
}
