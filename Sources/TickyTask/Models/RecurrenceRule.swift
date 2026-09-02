import Foundation

/// How often a recurring task repeats.
///
/// The raw values map 1:1 to the 7 legacy WeekToDo recurrence "type" integers
/// (see the Electron app's `repeatingEvent.vue`) so imported data round-trips
/// exactly.
enum RecurrenceFrequency: Int, Codable, CaseIterable, Identifiable, Sendable {
    case yearly = 0
    case monthly = 1
    case weekly = 2
    case daily = 3
    case weekdays = 4          // Monday–Friday
    case customWeekdays = 5    // user-selected weekdays
    case daysOfMonth = 6       // specific day numbers, e.g. the 1st & 15th

    var id: Int { rawValue }
}

/// When a recurrence stops repeating.
enum RecurrenceEnd: Codable, Equatable, Sendable {
    case never
    case afterCount(Int)
    case until(Date)
}

/// Value type describing a repeating task.
///
/// Persisted as a single `Codable` attribute on `TaskItem.recurrence` (nil for
/// one-off tasks). Concrete occurrences are computed on the fly by
/// `RecurrenceEngine`; only user-touched instances get a stored
/// `TaskOccurrence` override, which avoids the legacy
/// `repeating_events_by_date` per-date bloat.
struct RecurrenceRule: Codable, Equatable, Sendable {
    var frequency: RecurrenceFrequency
    /// Repeat every N periods; always >= 1.
    var interval: Int
    /// Weekday numbers using `Calendar`'s convention: 1 = Sunday … 7 = Saturday.
    var weekdays: Set<Int>
    /// Day-of-month numbers (1…31) for `.daysOfMonth`.
    var monthDays: [Int]
    var end: RecurrenceEnd
    var startDate: Date

    init(frequency: RecurrenceFrequency,
         interval: Int = 1,
         weekdays: Set<Int> = [],
         monthDays: [Int] = [],
         end: RecurrenceEnd = .never,
         startDate: Date) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.monthDays = monthDays
        self.end = end
        self.startDate = startDate
    }
}
