import Testing
import Foundation
@testable import TodoPlanner

@Suite("WeekMath")
struct WeekMathTests {
    /// Gregorian calendar in UTC for deterministic, timezone-independent assertions.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test("dayKey formats zero-padded yyyyMMdd")
    func dayKeyFormat() {
        #expect(WeekMath.dayKey(for: date(2026, 8, 14), calendar: cal) == "20260814")
        #expect(WeekMath.dayKey(for: date(2026, 1, 5), calendar: cal) == "20260105")
    }

    @Test("dayKey round-trips through date(fromDayKey:)")
    func dayKeyRoundTrip() {
        let d = date(2026, 12, 31)
        let key = WeekMath.dayKey(for: d, calendar: cal)
        #expect(WeekMath.date(fromDayKey: key, calendar: cal) == d)
        #expect(WeekMath.date(fromDayKey: "not-a-key", calendar: cal) == nil)
    }

    @Test("startOfWeek honors Monday vs Sunday")
    func startOfWeek() {
        // 2026-08-14 is a Friday.
        let friday = date(2026, 8, 14)
        let monday = WeekMath.startOfWeek(containing: friday, weekStartsMonday: true, calendar: cal)
        let sunday = WeekMath.startOfWeek(containing: friday, weekStartsMonday: false, calendar: cal)
        #expect(WeekMath.dayKey(for: monday, calendar: cal) == "20260810") // Mon 10th
        #expect(WeekMath.dayKey(for: sunday, calendar: cal) == "20260809") // Sun 9th
    }

    @Test("weekDates returns N consecutive days")
    func weekDates() {
        let start = date(2026, 8, 10)
        let days = WeekMath.weekDates(startingFrom: start, count: 5, calendar: cal)
        #expect(days.count == 5)
        #expect(WeekMath.dayKey(for: days[0], calendar: cal) == "20260810")
        #expect(WeekMath.dayKey(for: days[4], calendar: cal) == "20260814")
    }

    @Test("monthGridDays covers 6 weeks starting on the chosen weekday and includes the 1st")
    func monthGrid() {
        // August 2026: the 1st is a Saturday.
        let anchor = date(2026, 8, 14)
        let grid = WeekMath.monthGridDays(containing: anchor, weekStartsMonday: true, calendar: cal)
        #expect(grid.count == 42)
        // Monday-start grid for August 2026 begins Monday 2026-07-27.
        #expect(WeekMath.dayKey(for: grid[0], calendar: cal) == "20260727")
        #expect(grid.contains { WeekMath.dayKey(for: $0, calendar: cal) == "20260801" })
        #expect(WeekMath.isSameMonth(date(2026, 8, 1), as: anchor, calendar: cal))
        #expect(!WeekMath.isSameMonth(date(2026, 7, 31), as: anchor, calendar: cal))
    }
}
