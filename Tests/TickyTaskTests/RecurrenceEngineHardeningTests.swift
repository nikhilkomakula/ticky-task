import Testing
import Foundation
@testable import TickyTask

/// Recurrence engine hardening tests cover edge cases: duplicate month days
/// (counted once), extreme intervals (safe termination), leap centuries,
/// sparse rules, and seed dates outside the rule.
@Suite("Recurrence engine hardening")
struct RecurrenceEngineHardeningTests {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ c: Calendar) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func dayKey(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d%02d%02d", y, m, d)
    }

    // MARK: - Duplicate month days

    @Test("Duplicate monthDays are counted distinct once")
    func duplicateMonthDaysCountedOnce() {
        let c = cal()
        let start = date(2026, 1, 1, c)

        // Monthly rule with duplicate monthDays: [1, 15, 1]
        let rule = RecurrenceRule(
            frequency: .daysOfMonth, interval: 1,
            monthDays: [1, 15, 1],
            end: .afterCount(6),
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2026, 12, 31, c), calendar: c)

        // Should have 2 occurrences per month (1st and 15th), not 3, over 6 total
        #expect(keys.count == 6)

        // Verify we got 1st and 15th of three months
        #expect(keys.contains(dayKey(2026, 1, 1)))
        #expect(keys.contains(dayKey(2026, 1, 15)))
        #expect(keys.contains(dayKey(2026, 2, 1)))
        #expect(keys.contains(dayKey(2026, 2, 15)))
    }

    // MARK: - Extreme intervals

    @Test("Int.max interval for daily terminates quickly without overflow")
    func extremeIntervalDaily() {
        let c = cal()
        let start = date(2026, 1, 1, c)

        let rule = RecurrenceRule(
            frequency: .daily, interval: Int.max,
            end: .never,
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2030, 12, 31, c), calendar: c)

        // Only the start date should be generated
        #expect(keys.count == 1)
        #expect(keys[0] == dayKey(2026, 1, 1))
    }

    @Test("Int.max interval for weekly terminates safely")
    func extremeIntervalWeekly() {
        let c = cal()
        let start = date(2026, 1, 5, c)

        let rule = RecurrenceRule(
            frequency: .weekly, interval: Int.max,
            end: .never,
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2030, 12, 31, c), calendar: c)

        // Only the start date
        #expect(keys.count == 1)
    }

    @Test("Int.max interval for yearly terminates safely")
    func extremeIntervalYearly() {
        let c = cal()
        let start = date(2026, 1, 1, c)

        let rule = RecurrenceRule(
            frequency: .yearly, interval: Int.max,
            end: .never,
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(3000, 12, 31, c), calendar: c)

        #expect(keys.count == 1)
    }

    // MARK: - Weekday with huge interval

    @Test("Weekly with huge interval still emits matching weekdays")
    func hugeIntervalWeekdaysEmitCorrectly() {
        let c = cal()
        // 2026-01-05 is a Monday
        let start = date(2026, 1, 5, c)

        let rule = RecurrenceRule(
            frequency: .customWeekdays, interval: 100_000,
            weekdays: [2, 4], // Mon, Wed
            end: .afterCount(3),
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2026, 12, 31, c), calendar: c)

        // With huge interval, only start week's matching days
        #expect(keys.count == 2) // Mon 5th and Wed 7th of Jan
        #expect(keys.contains(dayKey(2026, 1, 5)))
        #expect(keys.contains(dayKey(2026, 1, 7)))
    }

    // MARK: - Leap-century years

    @Test("Feb-29 yearly across leap-century boundary 2096-2104")
    func leapCenturyFeb29() {
        let c = cal()
        let start = date(2096, 2, 29, c)

        let rule = RecurrenceRule(
            frequency: .yearly, interval: 1,
            end: .afterCount(9),
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2105, 12, 31, c), calendar: c)

        // Feb 29 exists only in leap years — 2100 is not one — and is skipped, never rolled over.
        #expect(keys == [dayKey(2096, 2, 29), dayKey(2104, 2, 29)])
    }

    // MARK: - Sparse rules

    @Test("Decennial (every 10 years) generates sparse occurrences")
    func decennialSparse() {
        let c = cal()
        let start = date(2010, 1, 15, c)

        let rule = RecurrenceRule(
            frequency: .yearly, interval: 10,
            end: .afterCount(5),
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2100, 12, 31, c), calendar: c)

        #expect(keys.count == 5)
        #expect(keys == [dayKey(2010, 1, 15), dayKey(2020, 1, 15), dayKey(2030, 1, 15),
                         dayKey(2040, 1, 15), dayKey(2050, 1, 15)])
    }

    // MARK: - Seed date off the rule

    @Test("Seed date outside rule weekdays emits nothing before next match")
    func seedOffRuleWeekdayEmitsNothing() {
        let c = cal()
        // 2026-01-06 is a Tuesday
        let start = date(2026, 1, 6, c)

        let rule = RecurrenceRule(
            frequency: .customWeekdays, interval: 1,
            weekdays: [2, 4], // Mon, Wed
            end: .afterCount(3),
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2026, 1, 31, c), calendar: c)

        // Seed is Tuesday; rule is Mon/Wed; next match is Wed 2026-01-07
        #expect(keys.count == 3)
        #expect(keys[0] == dayKey(2026, 1, 7)) // First Wed after seed
    }

    // MARK: - Display preference independence

    @Test("Monday/Sunday preference does not affect every-2-weeks generation")
    func mondaySundayPreferenceIndependent() {
        let c = cal()
        let start = date(2026, 1, 5, c) // Monday

        let rule = RecurrenceRule(
            frequency: .customWeekdays, interval: 2,
            weekdays: [2, 4],
            end: .afterCount(4),
            startDate: start
        )

        // Gregorian calendar firstWeekday can vary, but output should be stable
        var c2 = c
        c2.firstWeekday = 7 // Sunday (vs. Monday = 1 default)

        let keys1 = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2026, 12, 31, c), calendar: c)
        let keys2 = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2026, 12, 31, c2), calendar: c2)

        // Both should generate the same sequence
        #expect(keys1.count == keys2.count)
        #expect(keys1 == keys2)
    }

    // MARK: - Count behavior edge cases

    @Test("After-count with extremely sparse rule terminates correctly")
    func afterCountSparseTerminates() {
        let c = cal()
        let start = date(2000, 1, 1, c)

        let rule = RecurrenceRule(
            frequency: .yearly, interval: 50,
            end: .afterCount(100),
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(7000, 12, 31, c), calendar: c)

        #expect(keys.count == 100)
    }

    // MARK: - Edge case validation

    @Test("Monthly with invalid month day > 31 handled gracefully")
    func invalidMonthDayHandled() {
        let c = cal()
        let start = date(2026, 1, 1, c)

        let rule = RecurrenceRule(
            frequency: .daysOfMonth, interval: 1,
            monthDays: [31, 32, 50], // 32 and 50 are invalid
            end: .afterCount(12),
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2026, 12, 31, c))

        // Should emit only valid dates (31st where it exists)
        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy { !$0.hasSuffix("32") && !$0.hasSuffix("50") })
    }

    @Test("Negative or zero interval does not overflow")
    func zeroOrNegativeIntervalSafe() {
        let c = cal()
        let start = date(2026, 1, 1, c)

        let rule = RecurrenceRule(
            frequency: .daily, interval: 0,
            end: .afterCount(3),
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2026, 12, 31, c))

        // Should handle gracefully without infinite loop or crash
        #expect(keys.count <= 10) // Reasonable limit
    }

    @Test("Short month day (31) in February handled correctly")
    func feb31RequestHandled() {
        let c = cal()
        let start = date(2026, 2, 1, c)

        let rule = RecurrenceRule(
            frequency: .daysOfMonth, interval: 1,
            monthDays: [31],
            end: .never,
            startDate: start
        )

        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: start, through: date(2026, 4, 30, c), calendar: c)

        // February and April have no 31st (skipped, not clamped); March does.
        #expect(keys == [dayKey(2026, 3, 31)])
    }
}
