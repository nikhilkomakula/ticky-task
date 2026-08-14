import SwiftUI

/// The default view: `calendarColumns` day-column cards for the anchored week
/// over a resizable split with the custom-lists row. Navigation lives in the
/// shared top toolbar (`ContentView`).
struct WeekView: View {
    @Environment(AppState.self) private var app
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @AppStorage("calendarColumns") private var calendarColumns = 5
    @State private var editingTask: TaskItem?

    private var columns: Int { max(1, min(12, calendarColumns)) }

    var body: some View {
        let days = app.weekDays(columns: columns, weekStartsMonday: weekStartsMonday)
        VSplitView {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    DayColumnView(date: day) { editingTask = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(8)
            .frame(minHeight: 220, idealHeight: 460)

            VStack(alignment: .leading, spacing: 6) {
                Text("Lists")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                CustomListsRow { editingTask = $0 }
            }
            .frame(minHeight: 150, idealHeight: 210)
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task)
        }
    }
}
