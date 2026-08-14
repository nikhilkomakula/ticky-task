import SwiftUI
import AppKit

/// The menu-bar popover: a mini month calendar, the selected day's tasks (with
/// inline quick-add via `DayAgendaView`), and a button to open the main window.
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var app

    /// Bind the mini calendar to the shared selection so the menu bar and the
    /// main window stay in sync.
    private var selectedDate: Binding<Date> {
        Binding(
            get: { WeekMath.date(fromDayKey: app.selectedDayKey) ?? Date() },
            set: { app.select(day: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TodoPlanner")
                .font(.headline)

            DatePicker("", selection: selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(maxWidth: .infinity)

            Divider()

            DayAgendaView(dayKey: app.selectedDayKey)
                .frame(maxWidth: .infinity, minHeight: 240)

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Label("Open TodoPlanner", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(width: 320)
    }
}
