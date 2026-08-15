import SwiftUI
import KeyboardShortcuts

/// The macOS Settings window (⌘,): Appearance, Behavior, Notifications, Shortcuts.
/// All values are persisted via `@AppStorage` and read by the relevant views.
struct SettingsView: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            BehaviorSettingsView()
                .tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            DataSettingsView(context: context)
                .tabItem { Label("Data", systemImage: "externaldrive") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("calendarColumns") private var calendarColumns = 5
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @AppStorage("compactView") private var compactView = false

    var body: some View {
        Form {
            Picker("Theme", selection: $appTheme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Stepper("Week columns: \(calendarColumns)", value: $calendarColumns, in: 1...12)
            Toggle("Start the week on Monday", isOn: $weekStartsMonday)
            Toggle("Compact rows (hide times)", isOn: $compactView)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct BehaviorSettingsView: View {
    @AppStorage("taskSortMode") private var sortModeRaw = TaskSortMode.manual.rawValue
    @AppStorage("moveCompletedToBottom") private var moveCompletedToBottom = true
    @AppStorage("autoCarryForward") private var autoCarryForward = false
    @AppStorage("autoDeleteCompletedEnabled") private var autoDeleteEnabled = false
    @AppStorage("autoDeleteCompletedDays") private var autoDeleteDays = 7

    var body: some View {
        Form {
            Picker("Sort tasks", selection: $sortModeRaw) {
                ForEach(TaskSortMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Toggle("Move completed tasks to the bottom", isOn: $moveCompletedToBottom)
            Toggle("Automatically move unfinished tasks to today", isOn: $autoCarryForward)
            Text("When the app opens, unfinished tasks from past days are carried forward to today.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("Auto-delete completed tasks") {
                Toggle("Delete old completed tasks", isOn: $autoDeleteEnabled)
                if autoDeleteEnabled {
                    Stepper("Delete after \(autoDeleteDays) day\(autoDeleteDays == 1 ? "" : "s")",
                            value: $autoDeleteDays, in: 1...365)
                }
                Text("Off by default — completed tasks stay until you delete them. When on, tasks completed more than the chosen number of days ago are removed automatically each time TickyTask opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct NotificationSettingsView: View {
    @AppStorage("endOfDayReminderEnabled") private var endOfDayEnabled = false
    @AppStorage("endOfDayReminderMinutes") private var endOfDayMinutes = 18 * 60

    var body: some View {
        Form {
            Toggle("Remind me about unfinished tasks", isOn: $endOfDayEnabled)
            if endOfDayEnabled {
                DatePicker("Remind me at", selection: endOfDayTime, displayedComponents: .hourAndMinute)
            }
            Text("Per-task reminders: open a task and turn on “Remind me at this time.”")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Allow notifications…") {
                Task {
                    if await NotificationService.requestAuthorization() {
                        // Schedule immediately on grant (per-task reminders sync
                        // when the main window re-activates).
                        await NotificationService.scheduleEndOfDayReminder(
                            enabled: endOfDayEnabled, minutes: endOfDayMinutes
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: endOfDayEnabled) { _, _ in reschedule() }
        .onChange(of: endOfDayMinutes) { _, _ in reschedule() }
    }

    private var endOfDayTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: endOfDayMinutes / 60,
                                      minute: endOfDayMinutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                endOfDayMinutes = (comps.hour ?? 18) * 60 + (comps.minute ?? 0)
            }
        )
    }

    private func reschedule() {
        Task { await NotificationService.scheduleEndOfDayReminder(enabled: endOfDayEnabled, minutes: endOfDayMinutes) }
    }
}

private struct ShortcutsSettingsView: View {
    @AppStorage("menuBarOnly") private var menuBarOnly = false

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Open TickyTask:", name: .openApp)
            KeyboardShortcuts.Recorder("New task for today:", name: .newTaskToday)
            Toggle("Show only in the menu bar (hide Dock icon)", isOn: $menuBarOnly)
            Text("Global shortcuts work from any app. The menu-bar icon shows a mini calendar and the selected day’s tasks with quick-add.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
