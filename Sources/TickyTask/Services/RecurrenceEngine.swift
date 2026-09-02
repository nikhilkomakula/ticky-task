import Foundation

/// Pure recurrence date math: expands a `RecurrenceRule` into the ordered list of
/// occurrence day-keys (`"yyyyMMdd"`) that fall within a `[from, through]` window.
///
/// Deliberately dependency-free (no SwiftData, no UI) so every frequency, interval,
/// and end condition is exhaustively unit-testable. `RecurrenceMaterializer` turns
/// these keys into concrete `TaskItem` rows.
///
/// Correctness rules baked in here (each has a test):
/// - `interval` and `.afterCount` are always counted from `rule.startDate`, never
///   from `from` — otherwise the phase drifts and the count is off by the number of
///   pre-window occurrences.
/// - All stepping uses `Calendar` component math on start-of-day dates (never
///   `+86400`), so it is DST- and timezone-safe; occurrences are compared by their
///   day-key string, not by raw `Date`.
/// - Month/leap overflow is *skipped*, not clamped (rrule semantics): a day that
///   doesn't exist in a month (the 31st in February, Feb 29 in a common year) yields
///   no occurrence. Foundation silently rolls an invalid day over (Feb 31 → Mar 3),
///   so we build the day and verify the round-trip before accepting it.
/// - `.until(D)` is inclusive at day granularity; occurrences before `startDate` are
///   never produced.
enum RecurrenceEngine {
    /// Hard cap on period iterations, so a malformed rule can never loop forever.
    private static let iterationCap = 100_000

    /// A single period's occurrences plus a `reference` date used only for the
    /// "have we walked past the window?" stop test. `reference` is <= every date in
    /// `dates`, so once its key passes `through` no later period can qualify — this
    /// lets the loop terminate even across periods that produce no occurrence
    /// (an overflowed month, a weekend for a weekdays rule).
    private struct Period {
        var reference: Date
        var dates: [Date]
    }

    static func occurrenceDayKeys(for rule: RecurrenceRule,
                                  from: Date,
                                  through: Date,
                                  calendar: Calendar = .current) -> [String] {
        let anchor = calendar.startOfDay(for: rule.startDate)
        let startKey = WeekMath.dayKey(for: anchor, calendar: calendar)
        let fromKey = WeekMath.dayKey(for: calendar.startOfDay(for: from), calendar: calendar)
        let throughKey = WeekMath.dayKey(for: calendar.startOfDay(for: through), calendar: calendar)
        // Never emit before the series starts.
        let lowerKey = max(startKey, fromKey)
        guard lowerKey <= throughKey else { return [] }

        let untilKey: String?
        if case .until(let date) = rule.end {
            untilKey = WeekMath.dayKey(for: calendar.startOfDay(for: date), calendar: calendar)
        } else {
            untilKey = nil
        }
        let maxCount: Int
        if case .afterCount(let n) = rule.end { maxCount = max(0, n) } else { maxCount = .max }

        var result: [String] = []
        var emitted = 0   // total occurrences seen from the anchor (drives .afterCount)

        var period = 0
        while period < iterationCap {
            guard let block = expand(rule: rule, anchor: anchor, period: period, calendar: calendar) else { break }
            // Stop once the whole period sits past the window (occurrences are >= reference).
            if WeekMath.dayKey(for: block.reference, calendar: calendar) > throughKey { break }
            for occurrence in block.dates {
                let key = WeekMath.dayKey(for: occurrence, calendar: calendar)
                if let untilKey, key > untilKey { return result }   // .until exhausted
                if emitted >= maxCount { return result }            // .afterCount exhausted
                emitted += 1
                if key >= lowerKey && key <= throughKey {
                    result.append(key)
                } else if key > throughKey {
                    return result                                   // past the window
                }
            }
            period += 1
        }
        return result
    }

    // MARK: - Per-frequency period expansion

    /// The occurrences (and stop-test reference) for `period` (0-based, counted from
    /// the anchor). Returns `nil` only when the underlying date math fails, which
    /// ends enumeration.
    private static func expand(rule: RecurrenceRule, anchor: Date, period: Int, calendar: Calendar) -> Period? {
        let interval = max(1, rule.interval)
        switch rule.frequency {
        case .daily:
            guard let date = calendar.date(byAdding: .day, value: period * interval, to: anchor) else { return nil }
            return Period(reference: date, dates: [date])

        case .weekdays:   // Mon–Fri, every week; interval is not meaningful here.
            guard let date = calendar.date(byAdding: .day, value: period, to: anchor) else { return nil }
            return Period(reference: date, dates: calendar.isDateInWeekend(date) ? [] : [date])

        case .weekly, .customWeekdays:
            // Both walk week-blocks; plain weekly is the single-weekday case.
            let weekdays = rule.weekdays.isEmpty
                ? [calendar.component(.weekday, from: anchor)]
                : Array(rule.weekdays)
            return weeklyBlock(anchor: anchor, period: period, intervalWeeks: interval,
                               weekdays: Set(weekdays), calendar: calendar)

        case .monthly:
            let targetDay = calendar.component(.day, from: anchor)
            return monthlyBlock(anchor: anchor, period: period, intervalMonths: interval,
                                monthDays: [targetDay], calendar: calendar)

        case .daysOfMonth:
            return monthlyBlock(anchor: anchor, period: period, intervalMonths: interval,
                                monthDays: rule.monthDays, calendar: calendar)

        case .yearly:
            return yearlyBlock(anchor: anchor, period: period, intervalYears: interval, calendar: calendar)
        }
    }

    private static func weeklyBlock(anchor: Date, period: Int, intervalWeeks: Int,
                                    weekdays: Set<Int>, calendar: Calendar) -> Period? {
        // Sunday-aligned week blocks so "every N weeks" is deterministic and
        // independent of the user's Monday/Sunday *display* preference.
        let week0 = WeekMath.startOfWeek(containing: anchor, weekStartsMonday: false, calendar: calendar)
        guard let blockStart = calendar.date(byAdding: .weekOfYear, value: period * intervalWeeks, to: week0) else {
            return nil
        }
        var dates: [Date] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: blockStart) else { continue }
            let start = calendar.startOfDay(for: day)
            if weekdays.contains(calendar.component(.weekday, from: start)), start >= anchor {
                dates.append(start)
            }
        }
        return Period(reference: blockStart, dates: dates)
    }

    private static func monthlyBlock(anchor: Date, period: Int, intervalMonths: Int,
                                     monthDays: [Int], calendar: Calendar) -> Period? {
        let month0 = WeekMath.firstOfMonth(containing: anchor, calendar: calendar)
        guard let monthFirst = calendar.date(byAdding: .month, value: period * intervalMonths, to: month0) else {
            return nil
        }
        let dates = monthDays.sorted().compactMap { day -> Date? in
            guard let date = self.day(day, inMonthOf: monthFirst, calendar: calendar), date >= anchor else { return nil }
            return date
        }
        return Period(reference: monthFirst, dates: dates)
    }

    private static func yearlyBlock(anchor: Date, period: Int, intervalYears: Int, calendar: Calendar) -> Period? {
        let components = calendar.dateComponents([.year, .month, .day], from: anchor)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        let targetYear = year + period * intervalYears
        // Reference = the 1st of that month/year, always valid, for the stop test.
        var refComponents = DateComponents()
        refComponents.year = targetYear
        refComponents.month = month
        refComponents.day = 1
        guard let reference = calendar.date(from: refComponents) else { return nil }
        let dates: [Date]
        if let occurrence = date(year: targetYear, month: month, day: day, calendar: calendar), occurrence >= anchor {
            dates = [occurrence]
        } else {
            dates = []   // Feb 29 in a common year → skipped.
        }
        return Period(reference: calendar.startOfDay(for: reference), dates: dates)
    }

    // MARK: - Overflow-safe day construction

    /// Start-of-day for `day` within the month of `monthFirst`, or `nil` if that day
    /// doesn't exist in the month (round-trip guards Foundation's silent roll-over).
    private static func day(_ day: Int, inMonthOf monthFirst: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: monthFirst)
        return date(year: components.year, month: components.month, day: day, calendar: calendar)
    }

    /// Start-of-day for the given components, or `nil` if the day/month rolled over
    /// (e.g. Feb 31, or Feb 29 in a common year).
    private static func date(year: Int?, month: Int?, day: Int, calendar: Calendar) -> Date? {
        guard let year, let month else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let built = calendar.dateComponents([.month, .day], from: date)
        guard built.month == month, built.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }
}
