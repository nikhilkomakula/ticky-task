import SwiftUI
import AppKit
import KeyboardShortcuts

/// Root content: a Week ⇄ Month switcher on top of the selected view. Week is
/// the default; Month is the calendar grid (P2b). Applies the theme preference,
/// runs launch behaviors (sample seed, carry-forward, notification sync),
/// installs global shortcuts, and applies the menu-bar-only activation policy.
struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("autoCarryForward") private var autoCarryForward = false
    @AppStorage("endOfDayReminderEnabled") private var endOfDayEnabled = false
    @AppStorage("endOfDayReminderMinutes") private var endOfDayMinutes = 18 * 60
    @AppStorage("menuBarOnly") private var menuBarOnly = false

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $app.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            switch app.viewMode {
            case .week:
                WeekView()
            case .calendar:
                CalendarMonthView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(preferredColorScheme)
        .task { await runLaunchTasks() }
        .onAppear {
            GlobalShortcutsInstaller.installIfNeeded(openWindow: openWindow)
            applyActivationPolicy()
        }
        .onChange(of: menuBarOnly) { _, _ in applyActivationPolicy() }
        .onChange(of: scenePhase) { _, phase in
            // Re-run on re-activation: catches post-authorization scheduling,
            // midnight rollover carry-forward, and reminder reconciliation.
            if phase == .active {
                Task { await runLaunchTasks() }
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appTheme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    @MainActor
    private func runLaunchTasks() async {
        SampleData.seedIfEmpty(context)
        if autoCarryForward {
            try? BehaviorService.carryForwardIncomplete(context: context)
        }
        await NotificationService.syncTaskReminders(context: context)
        await NotificationService.scheduleEndOfDayReminder(enabled: endOfDayEnabled, minutes: endOfDayMinutes)
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }
}
