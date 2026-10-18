import Foundation

/// A calendar day as its `yyyyMMdd` key. Arithmetic runs in a fixed Gregorian calendar
/// (UTC), so a day never shifts when the Mac's time zone changes.
struct KanbanDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int, month: Int, day: Int

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year),
              let date = Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let back = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }   // rejects 31 Feb
        (self.year, self.month, self.day) = (year, month, day)
    }

    /// From a `yyyyMMdd` key; nil when it isn't a real day.
    init?(key: String) {
        guard key.count == 8, key.allSatisfy(\.isASCII), let value = Int(key) else { return nil }
        self.init(year: value / 10000, month: value / 100 % 100, day: value % 100)
    }

    /// The day `date` falls on in `calendar` (the app's), as membership dates are read.
    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)!
    }

    var key: String { String(format: "%04d%02d%02d", year, month, day) }
    var description: String { key }

    /// Midnight UTC; for formatting with a UTC formatter, and for arithmetic.
    var utcDate: Date { Self.calendar.date(from: DateComponents(year: year, month: month, day: day))! }

    /// This day at the start of the day in `calendar`, for date pickers and labels.
    func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? utcDate
    }

    func adding(days: Int) -> KanbanDay { KanbanDay(utcDate, offset: days) }

    private init(_ base: Date, offset: Int) {
        let date = Self.calendar.date(byAdding: .day, value: offset, to: base)!
        let c = Self.calendar.dateComponents([.year, .month, .day], from: date)
        (year, month, day) = (c.year!, c.month!, c.day!)
    }

    /// 1 = Sunday … 7 = Saturday, as `Calendar` and `KanbanProject.workWeekDays` count.
    var weekday: Int { Self.calendar.component(.weekday, from: utcDate) }

    /// The Monday of this day's Monday–Sunday week.
    var monday: KanbanDay { adding(days: -((weekday + 5) % 7)) }

    /// Whole days from `self` to `other`.
    func days(to other: KanbanDay) -> Int {
        Self.calendar.dateComponents([.day], from: utcDate, to: other.utcDate).day ?? 0
    }

    static func < (a: KanbanDay, b: KanbanDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    static func today(calendar: Calendar = .current) -> KanbanDay { KanbanDay(Date(), calendar: calendar) }
}

/// Weekly availability from recorded time off (design 03): pure, so the grid, the CSV and
/// the tests agree. Everything counts in half days so 4.5 and the 60 % bands are exact.
enum KanbanAvailability {
    /// One time-off entry as the arithmetic needs it.
    struct Absence: Equatable, Sendable {
        var id: UUID
        var start: KanbanDay
        var end: KanbanDay
        var portion: KanbanTimeOffPortion

        init(id: UUID, start: KanbanDay, end: KanbanDay, portion: KanbanTimeOffPortion) {
            (self.id, self.start, self.end, self.portion) = (id, start, end, portion)
        }

        init?(_ entry: KanbanTimeOff) {
            guard let start = KanbanDay(key: entry.startDay), let end = KanbanDay(key: entry.endDay), start <= end else { return nil }
            self.init(id: entry.id, start: start, end: end, portion: entry.portion)
        }

        /// The half-day slots this takes on `day` (0 morning, 1 afternoon).
        func slots(on day: KanbanDay) -> [Int] {
            guard start <= day, day <= end else { return [] }
            switch portion {
            case .full: return [0, 1]
            case .am: return [0]
            case .pm: return [1]
            }
        }
    }

    /// A board member as the arithmetic needs them.
    struct Member: Equatable, Sendable {
        var resourceID: UUID
        var start: KanbanDay?
        var end: KanbanDay?
        var absences: [Absence]
        /// Week Monday → stored half days.
        var overrides: [KanbanDay: Int]
    }

    /// The board's side: its dates and work days.
    struct Board: Equatable, Sendable {
        var start: KanbanDay?
        var end: KanbanDay?
        var workWeekDays: Set<Int>
    }

    enum Band: Equatable, Sendable { case green, yellow, red }

    struct Cell: Equatable, Sendable {
        var possibleHalfDays: Int
        var absentHalfDays: Int
        var overrideHalfDays: Int?
        /// The time off counted this week.
        var absenceIDs: [UUID]

        var computedHalfDays: Int { possibleHalfDays - absentHalfDays }
        /// A stored override above the possible days (after the dates changed) is kept but not used.
        var overrideNeedsReview: Bool { overrideHalfDays.map { $0 > possibleHalfDays } ?? false }
        var isOverridden: Bool { overrideHalfDays != nil && !overrideNeedsReview && isActive }
        var effectiveHalfDays: Int { isOverridden ? overrideHalfDays! : computedHalfDays }
        /// False when the member can't work any day that week (outside a range, no work days): "—".
        var isActive: Bool { possibleHalfDays > 0 }
        var band: Band? { KanbanAvailability.band(effectiveHalfDays, of: possibleHalfDays) }
    }

    /// Green above 60 % of the week's possible days, yellow at exactly 60 %, red below (owner's
    /// choice: on a five-day week, more than 3 / exactly 3 / fewer than 3).
    static func band(_ available: Int, of possible: Int) -> Band? {
        guard possible > 0 else { return nil }
        let (lhs, rhs) = (5 * available, 3 * possible)
        return lhs > rhs ? .green : lhs == rhs ? .yellow : .red
    }

    /// Days a member could work in the week starting `monday`: inside the board's and the
    /// membership's dates, on the board's work days.
    static func workDays(week monday: KanbanDay, board: Board, member: Member) -> [KanbanDay] {
        (0..<7).map { monday.adding(days: $0) }.filter { day in
            board.workWeekDays.contains(day.weekday)
                && board.start.map { day >= $0 } ?? true && board.end.map { day <= $0 } ?? true
                && member.start.map { day >= $0 } ?? true && member.end.map { day <= $0 } ?? true
        }
    }

    static func cell(week monday: KanbanDay, board: Board, member: Member) -> Cell {
        let days = workDays(week: monday, board: board, member: member)
        var absent = 0
        var counted: [UUID] = []
        for day in days {
            // The union of slots, so overlapping or duplicate entries count once.
            var slots = Set<Int>()
            for absence in member.absences {
                let taken = absence.slots(on: day)
                if !taken.isEmpty, !counted.contains(absence.id) { counted.append(absence.id) }
                slots.formUnion(taken)
            }
            absent += slots.count
        }
        return Cell(possibleHalfDays: 2 * days.count, absentHalfDays: absent, overrideHalfDays: member.overrides[monday],
                    absenceIDs: counted)
    }

    /// Effective over possible, summed (not an average of percentages); nil when nobody can work.
    static func total(_ cells: [Cell]) -> (available: Int, possible: Int)? {
        let possible = cells.reduce(0) { $0 + $1.possibleHalfDays }
        guard possible > 0 else { return nil }
        return (cells.reduce(0) { $0 + ($1.isActive ? $1.effectiveHalfDays : 0) }, possible)
    }

    /// The weeks (Mondays) shown: every week of a dated board; otherwise 12 weeks from this
    /// week, kept inside whichever bound is set. `shift` moves an open window by whole weeks.
    static func window(board: Board, today: KanbanDay, shift: Int = 0) -> [KanbanDay] {
        let length = 12
        let thisWeek = today.monday
        switch (board.start?.monday, board.end?.monday) {
        case let (start?, end?):
            let count = max(start.days(to: end) / 7 + 1, 1)
            return (0..<count).map { start.adding(days: 7 * $0) }
        case let (start?, nil):
            let first = max(start, thisWeek.adding(days: 7 * shift))
            return (0..<length).map { first.adding(days: 7 * $0) }
        case let (nil, end?):
            let last = min(end, thisWeek.adding(days: 7 * (length - 1 + shift)))
            return (0..<length).map { last.adding(days: -7 * (length - 1 - $0)) }
        case (nil, nil):
            let first = thisWeek.adding(days: 7 * shift)
            return (0..<length).map { first.adding(days: 7 * $0) }
        }
    }

    /// Why a board's optional dates can't be used, or nil.
    static func boardDatesProblem(_ startDay: String?, _ endDay: String?) -> String? {
        let start = startDay.map(KanbanDay.init(key:)), end = endDay.map(KanbanDay.init(key:))
        if start == .some(nil) { return "That start date isn't a real day." }
        if end == .some(nil) { return "That end date isn't a real day." }
        if let start = start ?? nil, let end = end ?? nil, end < start { return "A board can't end before it starts." }
        return nil
    }

    /// "4.5", "5", "0": at most one decimal.
    static func days(_ halfDays: Int) -> String {
        halfDays % 2 == 0 ? "\(halfDays / 2)" : "\(halfDays / 2).5"
    }
}

extension KanbanAvailability.Board {
    init(_ project: KanbanProject) {
        self.init(start: project.startDay.flatMap(KanbanDay.init(key:)), end: project.endDay.flatMap(KanbanDay.init(key:)),
                  workWeekDays: Set(project.workWeekDays))
    }
}

extension KanbanAvailability.Member {
    init(_ resource: KanbanResource, calendar: Calendar = .current) {
        var overrides: [KanbanDay: Int] = [:]
        for o in resource.availabilityOverrides {
            if let monday = KanbanDay(key: o.weekStart) { overrides[monday] = o.halfDays }
        }
        self.init(resourceID: resource.id, start: resource.startDate.map { KanbanDay($0, calendar: calendar) },
                  end: resource.endDate.map { KanbanDay($0, calendar: calendar) },
                  absences: (resource.person?.timeOff ?? []).compactMap(KanbanAvailability.Absence.init), overrides: overrides)
    }
}
