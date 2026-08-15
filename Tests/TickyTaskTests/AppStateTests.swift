import Testing
import Foundation
@testable import TickyTask

@MainActor
@Suite("AppState navigation")
struct AppStateTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test("nextWeek / previousWeek shift the anchor by whole weeks")
    func weekShift() {
        let app = AppState(calendar: utc, now: date(2026, 8, 14)) // Friday
        app.nextWeek()
        #expect(WeekMath.dayKey(for: app.weekAnchor, calendar: utc) == "20260821")
        app.previousWeek()
        app.previousWeek()
        #expect(WeekMath.dayKey(for: app.weekAnchor, calendar: utc) == "20260807")
    }

    @Test("weekDays returns N consecutive days from the Monday start")
    func weekDays() {
        let app = AppState(calendar: utc, now: date(2026, 8, 14)) // Friday
        let days = app.weekDays(columns: 5, weekStartsMonday: true)
        #expect(days.count == 5)
        #expect(WeekMath.dayKey(for: days[0], calendar: utc) == "20260810") // Mon
        #expect(WeekMath.dayKey(for: days[4], calendar: utc) == "20260814") // Fri
    }

    @Test("weekDays hides weekends when showWeekends is false")
    func weekDaysHidesWeekends() {
        let app = AppState(calendar: utc, now: date(2026, 8, 14)) // Fri; week of Mon Aug 10
        // A 7-column window includes Sat/Sun when weekends are shown.
        let shown = app.weekDays(columns: 7, weekStartsMonday: true, showWeekends: true)
        #expect(shown.contains { utc.isDateInWeekend($0) })
        // Hidden: a normal 5-column work week, Mon–Fri, none on a weekend.
        let hidden = app.weekDays(columns: 5, weekStartsMonday: true, showWeekends: false)
        #expect(hidden.count == 5)
        #expect(hidden.allSatisfy { !utc.isDateInWeekend($0) })
        #expect(WeekMath.dayKey(for: hidden[0], calendar: utc) == "20260810") // Mon
        #expect(WeekMath.dayKey(for: hidden[4], calendar: utc) == "20260814") // Fri
        // More columns than a work week keeps the requested count by spilling into
        // the next week's weekdays — never empty, never a weekend.
        let wide = app.weekDays(columns: 7, weekStartsMonday: true, showWeekends: false)
        #expect(wide.count == 7)
        #expect(wide.allSatisfy { !utc.isDateInWeekend($0) })
    }

    @Test("goToToday resets the selected day to today")
    func goToToday() {
        let app = AppState(calendar: utc, now: date(2020, 1, 1))
        app.goToToday()
        #expect(app.selectedDayKey == WeekMath.dayKey(for: Date(), calendar: utc))
    }
}
