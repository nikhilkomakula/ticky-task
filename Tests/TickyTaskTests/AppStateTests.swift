import Testing
import Foundation
@testable import TickyTask

@MainActor
@Suite("AppState navigation")
struct AppStateTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        // India considers only Sunday a localized weekend. Product semantics are
        // deliberately fixed to Saturday/Sunday regardless of locale.
        c.locale = Locale(identifier: "en_IN")
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

    @Test("weekDays returns N weekday columns from the Monday start")
    func weekDays() {
        let app = AppState(calendar: utc, now: date(2026, 8, 14)) // Friday
        let days = app.weekDays(columns: 5, weekStartsMonday: true, showWeekends: false)
        #expect(days.count == 5)
        #expect(WeekMath.dayKey(for: days[0], calendar: utc) == "20260810") // Mon
        #expect(WeekMath.dayKey(for: days[4], calendar: utc) == "20260814") // Fri
    }

    @Test("weekDays hides weekends when showWeekends is false")
    func weekDaysHidesWeekends() {
        let app = AppState(calendar: utc, now: date(2026, 8, 14)) // Fri; week of Mon Aug 10
        // A 7-column window includes Sat/Sun when weekends are shown.
        let shown = app.weekDays(columns: 7, weekStartsMonday: true, showWeekends: true)
        #expect(shown.contains { WeekMath.isSaturdayOrSunday($0, calendar: utc) })
        // Hidden: a normal 5-column work week, Mon–Fri, none on a weekend.
        let hidden = app.weekDays(columns: 5, weekStartsMonday: true, showWeekends: false)
        #expect(hidden.count == 5)
        #expect(hidden.allSatisfy { !WeekMath.isSaturdayOrSunday($0, calendar: utc) })
        #expect(WeekMath.dayKey(for: hidden[0], calendar: utc) == "20260810") // Mon
        #expect(WeekMath.dayKey(for: hidden[4], calendar: utc) == "20260814") // Fri
        // More columns than a work week keeps the requested count by spilling into
        // the next week's weekdays — never empty, never a weekend.
        let wide = app.weekDays(columns: 7, weekStartsMonday: true, showWeekends: false)
        #expect(wide.count == 7)
        #expect(wide.allSatisfy { !WeekMath.isSaturdayOrSunday($0, calendar: utc) })
    }

    @Test("Show weekends reveals the full 7-day week even at the default 5 columns")
    func weekDaysShowWeekendsIsFullWeek() {
        let app = AppState(calendar: utc, now: date(2026, 8, 14)) // Fri; week of Mon Aug 10
        // The bug fix: with 5 columns, ON must still show Saturday & Sunday (before,
        // it returned 5 consecutive days = Mon–Fri, so the toggle looked dead).
        let days = app.weekDays(columns: 5, weekStartsMonday: true, showWeekends: true)
        #expect(days.count == 7)
        #expect(days.contains { WeekMath.isSaturdayOrSunday($0, calendar: utc) })
        #expect(WeekMath.dayKey(for: days[0], calendar: utc) == "20260810") // Mon
        #expect(WeekMath.dayKey(for: days[6], calendar: utc) == "20260816") // Sun
    }

    @Test("visibleColumnCount is 7 with weekends shown, else the clamped weekday count")
    func visibleColumnCount() {
        #expect(AppState.visibleColumnCount(columns: 5, showWeekends: true) == 7)
        #expect(AppState.visibleColumnCount(columns: 5, showWeekends: false) == 5)
        #expect(AppState.visibleColumnCount(columns: 3, showWeekends: false) == 3)
        #expect(AppState.visibleColumnCount(columns: 99, showWeekends: false) == 12) // clamped
    }

    @Test("Sunday-start weeks obey the same full-week and weekday-only semantics")
    func weekDaysSundayStart() {
        let app = AppState(calendar: utc, now: date(2026, 8, 14)) // Friday
        let shown = app.weekDays(columns: 1, weekStartsMonday: false, showWeekends: true)
        #expect(shown.map { WeekMath.dayKey(for: $0, calendar: utc) }
            == ["20260809", "20260810", "20260811", "20260812", "20260813", "20260814", "20260815"])

        let hidden = app.weekDays(columns: 7, weekStartsMonday: false, showWeekends: false)
        #expect(hidden.count == 7)
        #expect(hidden.allSatisfy { !WeekMath.isSaturdayOrSunday($0, calendar: utc) })
        #expect(WeekMath.dayKey(for: hidden[0], calendar: utc) == "20260810") // Mon
        #expect(WeekMath.dayKey(for: hidden[6], calendar: utc) == "20260818") // Tue
    }

    @Test("Rendered and alignment column counts agree for every supported setting")
    func visibleColumnCountMatchesWeekDays() {
        let app = AppState(calendar: utc, now: date(2026, 8, 14))
        for columns in 1...12 {
            for showWeekends in [false, true] {
                let days = app.weekDays(
                    columns: columns,
                    weekStartsMonday: true,
                    showWeekends: showWeekends
                )
                #expect(days.count == AppState.visibleColumnCount(
                    columns: columns,
                    showWeekends: showWeekends
                ))
            }
        }
    }

    @Test("goToToday resets the selected day to today")
    func goToToday() {
        let app = AppState(calendar: utc, now: date(2020, 1, 1))
        app.goToToday()
        #expect(app.selectedDayKey == WeekMath.dayKey(for: Date(), calendar: utc))
    }
}
