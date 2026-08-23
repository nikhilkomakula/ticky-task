import SwiftUI
import SwiftData
import AppKit
import Combine

/// Root content: a single top toolbar (centered ‹ Today › nav + the current
/// week/month label, with the Week/Month switcher far-right) above the selected
/// view. Opens maximized. Applies the theme and runs launch behaviors.
struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("autoCarryForward") private var autoCarryForward = true
    @AppStorage("endOfDayReminderEnabled") private var endOfDayEnabled = false
    @AppStorage("endOfDayReminderMinutes") private var endOfDayMinutes = 18 * 60
    @AppStorage("menuBarOnly") private var menuBarOnly = false
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("autoDeleteCompletedEnabled") private var autoDeleteEnabled = false
    @AppStorage("autoDeleteCompletedDays") private var autoDeleteDays = 7
    @AppStorage("taskSortMode") private var sortModeRaw = TaskSortMode.manual.rawValue
    @AppStorage("moveCompletedToBottom") private var moveCompletedToBottom = true

    /// The main window's drag-to-reorder controller. Rows/containers publish their
    /// frames into it; the overlay draws the lifted preview + insertion line.
    @State private var dragController = DragController()

    /// The day key carry-forward last ran for. Lets a day rolling over while the
    /// app stays open (past midnight, without a relaunch or refocus) still trigger
    /// carry-forward via the minute timer below.
    @State private var lastCarryDayKey = WeekMath.dayKey(for: Date())

    var body: some View {
        @Bindable var app = app
        ZStack {
            VStack(spacing: 0) {
                TopToolbar(onSearch: { app.isSearchPresented = true })
                Divider()
                switch app.viewMode {
                case .week:
                    WeekView()
                case .calendar:
                    CalendarMonthView()
                }
            }
            DragOverlayView(controller: dragController)
        }
        .environment(dragController)
        .onPreferenceChange(RowFramesKey.self) { dragController.rowFrames = $0 }
        .onPreferenceChange(ContainerFramesKey.self) { dragController.containerFrames = $0 }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowConfigurator(configure: maximize))
        .preferredColorScheme(preferredColorScheme)
        .task { await runLaunchTasks() }
        .onAppear {
            GlobalShortcutsInstaller.installIfNeeded(openWindow: openWindow)
            applyActivationPolicy()
            syncDragConfig()
        }
        .onChange(of: menuBarOnly) { _, _ in applyActivationPolicy() }
        .onChange(of: sortModeRaw) { _, _ in syncDragConfig() }
        .onChange(of: moveCompletedToBottom) { _, _ in syncDragConfig() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await runLaunchTasks() } }
        }
        // Enabling the setting mid-session should catch up the current day at once.
        .onChange(of: autoCarryForward) { _, isOn in
            if isOn { runCarryForward() }
        }
        // Catch the date rolling over while the app is left open, so unfinished
        // tasks still carry forward at midnight without a relaunch or refocus.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            carryForwardIfDayChanged()
        }
        .sheet(isPresented: $app.isSearchPresented) { SearchView() }
    }

    /// Keep the drag controller's persistence context + sort config current.
    private func syncDragConfig() {
        dragController.context = context
        dragController.sortMode = TaskSortMode(rawValue: sortModeRaw) ?? .manual
        dragController.completedToBottom = moveCompletedToBottom
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
        if UITestSupport.isRunning {
            UITestSupport.seed(context)
        } else {
            SampleData.seedIfEmpty(context)
        }
        runCarryForward()
        AutoDeleteService.purgeCompleted(context: context, enabled: autoDeleteEnabled, olderThanDays: autoDeleteDays)
        LoginItemService.applyFirstRunDefaultIfNeeded()
        await NotificationService.syncTaskReminders(context: context)
        await NotificationService.scheduleEndOfDayReminder(enabled: endOfDayEnabled, minutes: endOfDayMinutes)
        await maybeCheckForUpdates()
    }

    /// Carry unfinished past-day tasks onto today when enabled, recording the day
    /// it ran for. Errors are logged rather than silently discarded.
    @MainActor
    private func runCarryForward() {
        guard autoCarryForward else { return }
        let todayKey = WeekMath.dayKey(for: Date())
        do {
            try BehaviorService.carryForwardIncomplete(context: context, todayKey: todayKey)
            // Advance only after a successful run, so a transient fetch/save error
            // is retried on the next timer tick or launch rather than skipped.
            lastCarryDayKey = todayKey
        } catch {
            NSLog("TickyTask: carry-forward failed: \(error.localizedDescription)")
        }
    }

    /// Timer-driven: when the calendar day advances while the app stays open,
    /// run carry-forward for the new day (idempotent; a no-op when disabled).
    @MainActor
    private func carryForwardIfDayChanged() {
        guard autoCarryForward, WeekMath.dayKey(for: Date()) != lastCarryDayKey else { return }
        runCarryForward()
    }

    /// Automatic update check, at most once per day, feeding Settings › General.
    @MainActor
    private func maybeCheckForUpdates() async {
        guard autoCheckUpdates else { return }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        guard now - defaults.double(forKey: "lastUpdateCheck") > 86_400 else { return }
        defaults.set(now, forKey: "lastUpdateCheck")
        if case .updateAvailable(let release)? = try? await UpdateService.check(currentVersion: Bundle.main.appVersion) {
            app.availableUpdate = release
        }
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
    @Environment(\.openSettings) private var openSettings
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @AppStorage("calendarColumns") private var calendarColumns = 5
    @AppStorage("showWeekends") private var showWeekends = false
    var onSearch: () -> Void = {}

    private var columns: Int { max(1, min(12, calendarColumns)) }

    var body: some View {
        @Bindable var app = app
        ZStack {
            // Center: current week range / month label (truly window-centered).
            Text(navLabel)
                .font(.headline.weight(.semibold))

            HStack(spacing: 12) {
                // Left: search + Week / Month switcher.
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help("Search tasks (⌘F)")

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

                    // Always-available Settings entry — the only way to reach
                    // Settings when the Dock icon is hidden (accessory mode).
                    // Activate explicitly so it comes frontmost in accessory mode.
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .help("Settings")
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
            let days = app.weekDays(columns: columns, weekStartsMonday: weekStartsMonday, showWeekends: showWeekends)
            guard let first = days.first, let last = days.last else { return "" }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
        case .calendar:
            return app.weekAnchor.formatted(.dateTime.month(.wide).year())
        }
    }
}
