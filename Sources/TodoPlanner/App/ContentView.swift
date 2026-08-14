import SwiftUI
import AppKit

/// Root content: a single top toolbar (centered ‹ Today › nav + the current
/// week/month label, with the Week/Month switcher far-right) above the selected
/// view. Opens maximized. Applies the theme and runs launch behaviors.
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
        VStack(spacing: 0) {
            TopToolbar()
            Divider()
            switch app.viewMode {
            case .week:
                WeekView()
            case .calendar:
                CalendarMonthView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowConfigurator(configure: maximize))
        .preferredColorScheme(preferredColorScheme)
        .task { await runLaunchTasks() }
        .onAppear {
            GlobalShortcutsInstaller.installIfNeeded(openWindow: openWindow)
            applyActivationPolicy()
        }
        .onChange(of: menuBarOnly) { _, _ in applyActivationPolicy() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await runLaunchTasks() } }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appTheme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private func maximize(_ window: NSWindow) {
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true)
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

/// The single shared toolbar row: centered navigation (‹ Today ›) with the
/// current week range or month label, and the Week/Month switcher on the right.
/// Navigation and label adapt to the active view mode.
private struct TopToolbar: View {
    @Environment(AppState.self) private var app
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @AppStorage("calendarColumns") private var calendarColumns = 5

    private var columns: Int { max(1, min(12, calendarColumns)) }

    var body: some View {
        @Bindable var app = app
        ZStack {
            // Center: current week range / month label (truly window-centered).
            Text(navLabel)
                .font(.headline.weight(.semibold))

            HStack(spacing: 12) {
                // Left: Week / Month switcher.
                Picker("View", selection: $app.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                // Right: navigation.
                HStack(spacing: 6) {
                    Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .help(app.viewMode == .week ? "Previous week" : "Previous month")
                    Button("Today") { app.goToToday() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .help(app.viewMode == .week ? "Next week" : "Next month")
                }
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
    }

    private func navigate(_ delta: Int) {
        switch app.viewMode {
        case .week:
            if delta < 0 { app.previousWeek() } else { app.nextWeek() }
        case .calendar:
            if delta < 0 { app.previousMonth() } else { app.nextMonth() }
        }
    }

    private var navLabel: String {
        switch app.viewMode {
        case .week:
            let days = app.weekDays(columns: columns, weekStartsMonday: weekStartsMonday)
            guard let first = days.first, let last = days.last else { return "" }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
        case .calendar:
            return app.weekAnchor.formatted(.dateTime.month(.wide).year())
        }
    }
}
