import SwiftUI
import AppKit

/// The menu-bar popover: a compact header, a full-width mini month calendar, and
/// the selected day's agenda (with inline quick-add) — each on a subtle material
/// section.
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TickyTask")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: openMainWindow) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .help("Open TickyTask")
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

    /// Collapse the menu-bar popover, then bring up (or focus) the main window.
    ///
    /// The popover is closed first, while it's still first responder, via the
    /// AppKit responder chain (`performClose:`) — more reliable for
    /// `MenuBarExtra(.window)` than `dismiss()` alone, which stays as a fallback.
    /// Opening + activating the main window is deferred one run-loop turn so the
    /// popover finishes tearing down before a new window becomes key.
    private func openMainWindow() {
        let closed = NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)
        if !closed { dismiss() }
        DispatchQueue.main.async {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
