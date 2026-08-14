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
    /// A task to briefly highlight after a search jump. Holds the task's stable
    /// `id` — not the model — so it's safe if the task is later deleted; it
    /// auto-clears after the flash.
    var highlightedTaskID: UUID?
    /// Bumped on each reveal so a newer flash isn't cleared by an older timer.
    private var revealGeneration = 0

    /// A newer release found by the update check (manual or automatic), surfaced
    /// in Settings › General.
    var availableUpdate: AppRelease?

    private let calendar: Calendar

    init(calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.weekAnchor = now
        self.selectedDayKey = WeekMath.dayKey(for: now, calendar: calendar)
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
        if let key = task.dayKey, let date = WeekMath.date(fromDayKey: key, calendar: calendar) {
            weekAnchor = date
            selectedDayKey = key
            viewMode = isDayVisibleInWeek(date) ? .week : .calendar
        } else if task.customList != nil {
            viewMode = .week
        }
        beginHighlight(task.id)
    }

    /// Whether `date` falls within the week view's configured columns (which may
    /// be fewer than 7, so weekend days can be off-screen at narrower widths).
    private func isDayVisibleInWeek(_ date: Date) -> Bool {
        let defaults = UserDefaults.standard
        let columns = max(1, min(12, defaults.object(forKey: "calendarColumns") as? Int ?? 5))
        let mondayStart = defaults.object(forKey: "weekStartsMonday") as? Bool ?? true
        let start = WeekMath.startOfWeek(containing: date, weekStartsMonday: mondayStart, calendar: calendar)
        let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
        return (0..<columns).contains(offset)
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
    func weekDays(columns: Int, weekStartsMonday: Bool) -> [Date] {
        let start = WeekMath.startOfWeek(
            containing: weekAnchor, weekStartsMonday: weekStartsMonday, calendar: calendar
        )
        return WeekMath.weekDates(startingFrom: start, count: columns, calendar: calendar)
    }
}
