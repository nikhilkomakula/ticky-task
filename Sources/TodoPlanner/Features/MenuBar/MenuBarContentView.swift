import SwiftUI
import AppKit

/// The menu-bar popover: a mini month calendar, the selected day's tasks (with
/// inline quick-add via `DayAgendaView`), and a button to open the main window.
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TodoPlanner")
                .font(.headline)

            MiniMonthCalendar()

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
