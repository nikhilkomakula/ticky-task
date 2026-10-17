import Foundation
import SwiftUI

/// Which primary view is showing. Week is the app default; Calendar is the
/// month-grid alternative (P2b).
enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case week
    case calendar

    var id: String { rawValue }
    var label: String { self == .week ? "Week" : "Month" }
    var symbol: String { self == .week ? "calendar.day.timeline.left" : "calendar" }
}

/// Transient, non-persisted UI state shared across the app: which week is shown,
/// which day is selected (drives calendar drill-in and the menu-bar panel), and
/// the current view mode. Persisted preferences live in `@AppStorage` instead.
@MainActor
@Observable
final class AppState {
    /// A date within the currently displayed week.
    var weekAnchor: Date
    /// Selected day key (`"yyyyMMdd"`).
    var selectedDayKey: String
    var viewMode: ViewMode = .week

    /// Whether the task-search sheet is showing (toggled by the toolbar button
    /// and the ⌘F "Find Task" command).
    var isSearchPresented = false
    /// Whether the Weekly Summary sheet is showing (toolbar button / ⇧⌘Y).
    var isWeeklySummaryPresented = false
    /// Whether the keyboard shortcuts sheet is showing (Help › Keyboard Shortcuts, ⌘/).
    var isShortcutsPresented = false
    /// A task to briefly highlight after a search jump. Holds the task's stable
    /// `id` — not the model — so it's safe if the task is later deleted; it
    /// auto-clears after the flash.
    var highlightedTaskID: UUID?
    /// Bumped on each reveal so a newer flash isn't cleared by an older timer.
    private var revealGeneration = 0

    /// A newer release found by the update check (manual or automatic), surfaced
    /// in Settings › General.
    var availableUpdate: AppRelease?

    /// The module the main window shows (⌘1 / ⌘2).
    var module: AppModule = .planner
    var kanban = KanbanNavigation()
    /// A board card to briefly highlight after a reveal (Attention, search).
    var highlightedKanbanTaskID: UUID?
    private var kanbanRevealGeneration = 0
    /// Board undo/redo for this session; cleared by a restore.
    let kanbanHistory = KanbanHistory()
    /// Bumped by every Kanban save and by a restore (01 §2.5).
    let kanbanGeneration = KanbanStoreGeneration()
    /// A refused or failed board change, shown as an alert by the Kanban module.
    var kanbanError: String?
    /// Today's day key and the time zone, refreshed by the root's minute timer, on activation
    /// and when the time zone changes, so metrics follow the calendar (01 §2.5).
    var kanbanClock = AppState.currentKanbanClock()
    /// The menu-bar popover's Planner | Kanban choice, kept until relaunch (nil: the Default view).
    var popoverModule: AppModule?

    static func currentKanbanClock() -> String { "\(WeekMath.dayKey(for: Date()))|\(TimeZone.current.identifier)" }

    func refreshKanbanClock() {
        let clock = Self.currentKanbanClock()
        if kanbanClock != clock { kanbanClock = clock }
    }
    /// Bumped by a restore: the Kanban module is rebuilt, dropping sheets that hold replaced rows.
    var kanbanRestoreToken = 0
    @ObservationIgnored let kanbanMetrics = KanbanMetricsCache()
    /// ⌘Z / ⇧⌘Z for the board on screen, if any.
    @ObservationIgnored var kanbanBoardActions: KanbanBoardActions?

    private let calendar: Calendar

    init(calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.weekAnchor = now
        self.selectedDayKey = WeekMath.dayKey(for: now, calendar: calendar)
        // Settings › Kanban › Open at launch, among the visible modules.
        let defaults = UserDefaults.standard
        module = ModulePolicy(defaults).resolve(defaults.string(forKey: "defaultModule").flatMap(AppModule.init(rawValue:)) ?? .planner)
        // Test/screenshot hook (inert in normal use): start in a given view.
        if ProcessInfo.processInfo.environment["WTD_INITIAL_VIEW"] == "calendar" {
            viewMode = .calendar
        }
    }

    func goToToday() {
        let now = Date()
        weekAnchor = now
        selectedDayKey = WeekMath.dayKey(for: now, calendar: calendar)
    }

    func previousWeek() { shiftWeek(by: -1) }
    func nextWeek() { shiftWeek(by: 1) }

    private func shiftWeek(by delta: Int) {
        if let shifted = calendar.date(byAdding: .weekOfYear, value: delta, to: weekAnchor) {
            weekAnchor = shifted
        }
    }

    func previousMonth() { shiftMonth(by: -1) }
    func nextMonth() { shiftMonth(by: 1) }

    private func shiftMonth(by delta: Int) {
        if let shifted = calendar.date(byAdding: .month, value: delta, to: weekAnchor) {
            weekAnchor = shifted
        }
    }

    /// Select a day (from the calendar grid): updates the selection and moves
    /// the week anchor so switching back to the week view shows that week.
    func select(day: Date) {
        weekAnchor = day
        selectedDayKey = WeekMath.dayKey(for: day, calendar: calendar)
    }

    /// Reveal a task (from a search result): move to and select its day, choosing
    /// the view that can actually show it — the week view when the day is among
    /// the visible columns, otherwise the month view, whose day-agenda panel
    /// shows any day. Custom-list tasks use the week view (their lists row).
    /// Stores only the task's `id`, so a later-deleted task simply isn't found.
    func reveal(_ task: TaskItem) {
        module = .planner
        if let key = task.dayKey, let date = WeekMath.date(fromDayKey: key, calendar: calendar) {
            weekAnchor = date
            selectedDayKey = key
            viewMode = isDayVisibleInWeek(date) ? .week : .calendar
        } else if task.customList != nil {
            viewMode = .week
        }
        beginHighlight(task.id)
    }

    /// Whether `date` falls among the week view's actual columns for the current
    /// settings (fewer than 7 when weekends are hidden, so a weekend day is
    /// off-screen). Derived from the same `weekDays` the grid renders, so search
    /// reveal falls back to the month view exactly when the day isn't a column.
    /// Assumes `weekAnchor` is already the week containing `date` (reveal sets it).
    private func isDayVisibleInWeek(_ date: Date) -> Bool {
        let defaults = UserDefaults.standard
        let columns = max(1, min(12, defaults.integer(forKey: "calendarColumns", default: 5)))
        let mondayStart = defaults.bool(forKey: "weekStartsMonday", default: true)
        let showWeekends = defaults.bool(forKey: "showWeekends", default: false)
        let key = WeekMath.dayKey(for: date, calendar: calendar)
        return weekDays(columns: columns, weekStartsMonday: mondayStart, showWeekends: showWeekends)
            .contains { WeekMath.dayKey(for: $0, calendar: calendar) == key }
    }

    /// Opens the Kanban module on `projectID`'s board and highlights the card for ~2s.
    func revealKanban(taskID: UUID, projectID: UUID) {
        module = .kanban
        kanban.selection = .project(projectID)
        highlightedKanbanTaskID = taskID
        kanbanRevealGeneration &+= 1
        let generation = kanbanRevealGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if kanbanRevealGeneration == generation { highlightedKanbanTaskID = nil }
        }
    }

    /// Flash the highlight for ~2s, using a generation token so a newer reveal's
    /// flash isn't cleared early by an older reveal's timer.
    private func beginHighlight(_ id: UUID) {
        highlightedTaskID = id
        revealGeneration &+= 1
        let generation = revealGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if revealGeneration == generation { highlightedTaskID = nil }
        }
    }

    /// The days to render as columns in the week view.
    ///
    /// - `showWeekends == true`: the **full 7-day week** (Sat & Sun included), so
    ///   the toggle visibly reveals the weekend regardless of `columns`.
    /// - `showWeekends == false`: `columns` **weekday** columns only, skipping
    ///   Sat/Sun (spilling into the next week's weekdays for wider counts, so the
    ///   visible count stays stable and is never empty). This keeps the planner
    ///   focused on workdays by default; `columns` sizes how many weekdays show.
    func weekDays(columns: Int, weekStartsMonday: Bool, showWeekends: Bool = true) -> [Date] {
        let start = WeekMath.startOfWeek(
            containing: weekAnchor, weekStartsMonday: weekStartsMonday, calendar: calendar
        )
        if showWeekends {
            return WeekMath.weekDates(startingFrom: start, count: 7, calendar: calendar)
        }
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: start)
        while days.count < columns {
            if !WeekMath.isSaturdayOrSunday(cursor, calendar: calendar) { days.append(cursor) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// How many day columns the week view actually shows for the given settings:
    /// the full week (7) when weekends are shown, otherwise the weekday count. The
    /// custom-lists row uses this to size its cards to line up under the columns.
    static func visibleColumnCount(columns: Int, showWeekends: Bool) -> Int {
        showWeekends ? 7 : max(1, min(12, columns))
    }
}
