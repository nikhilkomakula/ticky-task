import SwiftUI
import AppKit

/// The menu-bar popover: a compact header, a full-width mini month calendar, and
/// the selected day's agenda (with inline quick-add) — each on a subtle material
/// section.
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TodoPlanner")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .help("Open TodoPlanner")
            }

            MiniMonthCalendar()
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            DayAgendaView(dayKey: app.selectedDayKey, insets: 8)
                .frame(minHeight: 180, maxHeight: 260)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(10)
        .frame(width: 340)
    }
}
