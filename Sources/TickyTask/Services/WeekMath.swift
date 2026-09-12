import Foundation

/// Pure date helpers for the weekly calendar: day-key formatting and week-window
/// computation. Kept dependency-free and deterministic so it is fully unit-testable.
enum WeekMath {
    /// The `"yyyyMMdd"` key used to bucket tasks by calendar day (matches the
    /// legacy WeekToDo `listId` format). Built from components to avoid
    /// `DateFormatter` locale pitfalls.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Parse a `"yyyyMMdd"` key back into the start-of-day `Date`, or `nil` if malformed.
    static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        guard key.count == 8,
              let year = Int(key.prefix(4)),
              let month = Int(key.dropFirst(4).prefix(2)),
              let day = Int(key.suffix(2)) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return calendar.date(from: comps)
    }

    /// Whether `date` is Saturday or Sunday in `calendar`'s time zone. This is
    /// intentionally independent of the calendar locale: TickyTask's weekend
    /// setting always means the two named weekend columns, even in regions where
    /// Foundation's localized weekend is Friday/Saturday or Sunday-only.
    static func isSaturdayOrSunday(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    /// Start-of-week (at start of day) containing `date`, honoring the user's
    /// week-start preference (Monday vs Sunday).
    static func startOfWeek(containing date: Date,
                            weekStartsMonday: Bool,
                            calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = weekStartsMonday ? 2 : 1  // 1 = Sunday, 2 = Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    /// `count` consecutive day-start dates beginning at `start`.
    static func weekDates(startingFrom start: Date,
                          count: Int,
                          calendar: Calendar = .current) -> [Date] {
        let day0 = calendar.startOfDay(for: start)
        return (0..<max(0, count)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: day0)
        }
    }

    /// First day (start of day) of the month containing `date`.
    static func firstOfMonth(containing date: Date, calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    }

    /// The 42 days (6 weeks × 7) of a stable month grid containing `date`,
    /// starting on the user's preferred weekday. Leading/trailing days spill
    /// into the adjacent months.
    static func monthGridDays(containing date: Date,
                              weekStartsMonday: Bool,
                              calendar: Calendar = .current) -> [Date] {
        let first = firstOfMonth(containing: date, calendar: calendar)
        let gridStart = startOfWeek(containing: first, weekStartsMonday: weekStartsMonday, calendar: calendar)
        return weekDates(startingFrom: gridStart, count: 42, calendar: calendar)
    }

    /// Whether two dates fall in the same calendar month (and year).
    static func isSameMonth(_ lhs: Date, as rhs: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
    }
}
