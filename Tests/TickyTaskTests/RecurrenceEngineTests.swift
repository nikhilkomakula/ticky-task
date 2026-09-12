import Testing
import Foundation
@testable import TickyTask

/// Pure date-math tests for `RecurrenceEngine`. A fixed Gregorian calendar pinned
/// to a DST-observing timezone makes every case deterministic.
@Suite("RecurrenceEngine")
struct RecurrenceEngineTests {
    private func calendar(_ tz: String = "America/New_York") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        cal.firstWeekday = 1
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0, minute: Int = 0, cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    private func keys(_ rule: RecurrenceRule, _ from: Date, _ through: Date, _ cal: Calendar) -> [String] {
        RecurrenceEngine.occurrenceDayKeys(for: rule, from: from, through: through, calendar: cal)
    }

    // MARK: - Happy paths

    @Test("Daily yields consecutive days")
    func daily() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let result = keys(rule, start, date(2026, 1, 7, cal: cal), cal)
        #expect(result == ["20260101", "20260102", "20260103", "20260104", "20260105", "20260106", "20260107"])
    }

    @Test("Weekly repeats on the start weekday")
    func weekly() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)   // Thursday
        let rule = RecurrenceRule(frequency: .weekly, startDate: start)
        let result = keys(rule, start, date(2026, 1, 31, cal: cal), cal)
        #expect(result == ["20260101", "20260108", "20260115", "20260122", "20260129"])
    }

    @Test("Weekdays excludes Saturday and Sunday")
    func weekdays() {
        var cal = calendar()
        // India considers only Sunday a localized weekend; the product's
        // "weekdays" recurrence is explicitly Mon–Fri in every locale.
        cal.locale = Locale(identifier: "en_IN")
        let start = date(2026, 1, 5, cal: cal)   // Monday
        let rule = RecurrenceRule(frequency: .weekdays, startDate: start)
        let result = keys(rule, start, date(2026, 1, 11, cal: cal), cal)   // Mon–Sun
        #expect(result == ["20260105", "20260106", "20260107", "20260108", "20260109"])
    }

    @Test("Weekly with a weekday set emits each selected day, ascending")
    func weeklyWithSet() {
        let cal = calendar()
        let start = date(2026, 1, 5, cal: cal)   // Monday
        // Mon(2), Wed(4), Fri(6) in Calendar's 1=Sun convention.
        let rule = RecurrenceRule(frequency: .weekly, weekdays: [2, 4, 6], startDate: start)
        let result = keys(rule, start, date(2026, 1, 11, cal: cal), cal)
        #expect(result == ["20260105", "20260107", "20260109"])
    }

    @Test("Monthly keeps the day-of-month across months")
    func monthly() {
        let cal = calendar()
        let start = date(2026, 1, 15, cal: cal)
        let rule = RecurrenceRule(frequency: .monthly, startDate: start)
        let result = keys(rule, start, date(2026, 4, 30, cal: cal), cal)
        #expect(result == ["20260115", "20260215", "20260315", "20260415"])
    }

    @Test("Yearly keeps month and day")
    func yearly() {
        let cal = calendar()
        let start = date(2026, 3, 10, cal: cal)
        let rule = RecurrenceRule(frequency: .yearly, startDate: start)
        let result = keys(rule, start, date(2028, 12, 31, cal: cal), cal)
        #expect(result == ["20260310", "20270310", "20280310"])
    }

    @Test("Days-of-month emits each named day per month")
    func daysOfMonth() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .daysOfMonth, monthDays: [1, 15], startDate: start)
        let result = keys(rule, start, date(2026, 3, 31, cal: cal), cal)
        #expect(result == ["20260101", "20260115", "20260201", "20260215", "20260301", "20260315"])
    }

    // MARK: - Interval (phase anchored at startDate)

    @Test("Every-3-days is anchored to startDate, not the window start")
    func dailyIntervalPhase() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .daily, interval: 3, startDate: start)
        // Window starts mid-series; the phase must stay on Jan 1 + 3k.
        let result = keys(rule, date(2026, 1, 5, cal: cal), date(2026, 1, 14, cal: cal), cal)
        #expect(result == ["20260107", "20260110", "20260113"])
    }

    @Test("Every other week")
    func weeklyInterval2() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .weekly, interval: 2, startDate: start)
        let result = keys(rule, start, date(2026, 2, 15, cal: cal), cal)
        #expect(result == ["20260101", "20260115", "20260129", "20260212"])
    }

    @Test("Every other month")
    func monthlyInterval2() {
        let cal = calendar()
        let start = date(2026, 1, 10, cal: cal)
        let rule = RecurrenceRule(frequency: .monthly, interval: 2, startDate: start)
        let result = keys(rule, start, date(2026, 7, 31, cal: cal), cal)
        #expect(result == ["20260110", "20260310", "20260510", "20260710"])
    }

    // MARK: - End conditions

    @Test("afterCount stops after N occurrences")
    func afterCountInWindow() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .daily, end: .afterCount(3), startDate: start)
        let result = keys(rule, start, date(2026, 1, 31, cal: cal), cal)
        #expect(result == ["20260101", "20260102", "20260103"])
    }

    @Test("afterCount counts occurrences from startDate, including pre-window ones")
    func afterCountBeforeWindow() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .daily, end: .afterCount(5), startDate: start)
        // Occurrences Jan1–5; the window starts on the 3rd, so only 3,4,5 remain.
        let result = keys(rule, date(2026, 1, 3, cal: cal), date(2026, 1, 31, cal: cal), cal)
        #expect(result == ["20260103", "20260104", "20260105"])
    }

    @Test("until is inclusive at day granularity")
    func untilInclusive() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .daily, end: .until(date(2026, 1, 5, cal: cal)), startDate: start)
        let result = keys(rule, start, date(2026, 1, 31, cal: cal), cal)
        #expect(result == ["20260101", "20260102", "20260103", "20260104", "20260105"])
    }

    // MARK: - Overflow / calendar edges

    @Test("Monthly on the 31st skips short months, never clamps")
    func monthly31Skips() {
        let cal = calendar()
        let start = date(2026, 1, 31, cal: cal)
        let rule = RecurrenceRule(frequency: .monthly, startDate: start)
        let result = keys(rule, start, date(2026, 12, 31, cal: cal), cal)
        // Only 31-day months: Jan, Mar, May, Jul, Aug, Oct, Dec.
        #expect(result == ["20260131", "20260331", "20260531", "20260731", "20260831", "20261031", "20261231"])
    }

    @Test("Yearly Feb 29 fires only in leap years")
    func yearlyLeapDay() {
        let cal = calendar()
        let start = date(2024, 2, 29, cal: cal)   // leap year
        let rule = RecurrenceRule(frequency: .yearly, startDate: start)
        let result = keys(rule, start, date(2032, 12, 31, cal: cal), cal)
        #expect(result == ["20240229", "20280229", "20320229"])
    }

    @Test("Days-of-month with the 31st skips 30-day months and February")
    func daysOfMonth31Skips() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .daysOfMonth, monthDays: [31], startDate: start)
        let result = keys(rule, start, date(2026, 6, 30, cal: cal), cal)
        #expect(result == ["20260131", "20260331", "20260531"])
    }

    // MARK: - DST safety

    @Test("Daily is unbroken across spring-forward")
    func dstSpringForward() {
        let cal = calendar()
        let start = date(2026, 3, 7, cal: cal)   // DST begins Sun Mar 8, 2026
        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let result = keys(rule, start, date(2026, 3, 10, cal: cal), cal)
        #expect(result == ["20260307", "20260308", "20260309", "20260310"])
    }

    @Test("Daily is unbroken across fall-back")
    func dstFallBack() {
        let cal = calendar()
        let start = date(2026, 10, 31, cal: cal)   // DST ends Sun Nov 1, 2026
        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let result = keys(rule, start, date(2026, 11, 2, cal: cal), cal)
        #expect(result == ["20261031", "20261101", "20261102"])
    }

    // MARK: - Boundaries

    @Test("A start time late in the day still yields the correct day key")
    func lateStartTime() {
        let cal = calendar()
        let start = date(2026, 1, 1, hour: 23, minute: 30, cal: cal)
        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let result = keys(rule, date(2026, 1, 1, cal: cal), date(2026, 1, 1, cal: cal), cal)
        #expect(result == ["20260101"])
    }

    @Test("A window entirely before the start is empty")
    func windowBeforeStart() {
        let cal = calendar()
        let start = date(2026, 2, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        #expect(keys(rule, date(2026, 1, 1, cal: cal), date(2026, 1, 15, cal: cal), cal).isEmpty)
    }

    @Test("A single-day window on the start yields exactly one key")
    func singleDayWindow() {
        let cal = calendar()
        let start = date(2026, 1, 1, cal: cal)
        let rule = RecurrenceRule(frequency: .weekly, startDate: start)
        #expect(keys(rule, start, start, cal) == ["20260101"])
    }
}
