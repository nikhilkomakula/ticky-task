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

    /// The days to render as columns in the week view.
    func weekDays(columns: Int, weekStartsMonday: Bool) -> [Date] {
        let start = WeekMath.startOfWeek(
            containing: weekAnchor, weekStartsMonday: weekStartsMonday, calendar: calendar
        )
        return WeekMath.weekDates(startingFrom: start, count: columns, calendar: calendar)
    }
}
