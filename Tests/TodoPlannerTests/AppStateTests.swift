import Testing
import Foundation
@testable import TodoPlanner

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

    @Test("goToToday resets the selected day to today")
    func goToToday() {
        let app = AppState(calendar: utc, now: date(2020, 1, 1))
        app.goToToday()
        #expect(app.selectedDayKey == WeekMath.dayKey(for: Date(), calendar: utc))
    }
}
