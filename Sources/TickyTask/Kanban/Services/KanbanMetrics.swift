import Foundation
import SwiftData

/// A value snapshot of one board for the dashboard (design 02 §0). Every metric is a pure
/// function of a snapshot: no SwiftData, `Date()` or `Calendar.current` inside.
struct MetricsSnapshot: Sendable {
    struct Column: Sendable, Equatable {
        var id: UUID
        var name: String
        var kind: KanbanColumnKind
    }

    /// A board membership, with its person's details.
    struct Member: Sendable, Equatable {
        var id: UUID
        var personID: UUID
        var name: String
        var employment: KanbanEmployment = .fte
        var assignment: KanbanAssignment = .fullTime
        var allocationPercent = 100
        var capacityHoursOverride: Double?
        var openTaskTargetOverride: Double?
        var startDate: Date?
        var endDate: Date?
        var archived = false
    }

    struct Card: Sendable, Equatable {
        var id: UUID
        var title = ""
        var column: UUID
        var resource: UUID?
        var priority = 0
        var isCritical = false
        var dueDate: Date?
        var startDate: Date?
        var estimateHours: Double?
        var isBlocked = false
        var blockedReason: String?
        var dependsOn: [UUID] = []
        var labels: [UUID] = []
        var subtasksDone = 0
        var subtasksTotal = 0
        var jiraURL: String?
        var createdAt: Date
        var updatedAt: Date
        var archived = false
    }

    var projectID: UUID
    var projectName: String
    var projectArchived = false
    var loadMeasure: KanbanLoadMeasure = .taskCount
    var weightedLoad = false
    var openTaskTarget: Double = 5
    var defaultCapacityHoursPerWeek: Double = 40
    var defaultEstimateHours: Double = 4
    var workWeekDays: Set<Int> = [2, 3, 4, 5, 6]
    /// In board order.
    var columns: [Column]
    var members: [Member]
    var cards: [Card]
    /// When each card was last marked blocked, from the change log.
    var blockedSince: [UUID: Date] = [:]
    var now: Date
    /// The user's time zone, with `firstWeekday` set from the week-start preference.
    var calendar: Calendar

    func kind(of card: Card) -> KanbanColumnKind? { columns.first { $0.id == card.column }?.kind }
    func isOpen(_ card: Card) -> Bool { !card.archived && kind(of: card) != .done }
    func isDone(_ card: Card) -> Bool { !card.archived && kind(of: card) == .done }

    var today: Date { calendar.startOfDay(for: now) }
    func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    /// Calendar days from `a` to `b` (DST-safe, never `/86400`).
    func days(from a: Date, to b: Date) -> Int { calendar.dateComponents([.day], from: day(a), to: day(b)).day ?? 0 }
    func addDays(_ n: Int, to date: Date) -> Date { calendar.date(byAdding: .day, value: n, to: date) ?? date }
    func weekStart(_ date: Date) -> Date {
        WeekMath.startOfWeek(containing: date, weekStartsMonday: calendar.firstWeekday == 2, calendar: calendar)
    }
}

/// Dates as whole days from the start of the current week (day 0), so week `k` is days
/// `7k…7k+6` and the per-week arithmetic needs no calendar calls.
struct MetricsDays {
    let week0: Date
    let today: Int
    private let snapshot: MetricsSnapshot
    private let weekday0: Int

    init(_ s: MetricsSnapshot) {
        snapshot = s
        week0 = s.weekStart(s.today)
        weekday0 = s.calendar.component(.weekday, from: week0)
        today = s.days(from: week0, to: s.today)
    }

    func offset(_ date: Date) -> Int { snapshot.days(from: week0, to: date) }

    func isWorkDay(_ offset: Int) -> Bool {
        snapshot.workWeekDays.contains(((weekday0 - 1 + offset) % 7 + 7) % 7 + 1)
    }

    /// The number of work days in `[a, b]`, both inclusive.
    func workDays(_ a: Int, _ b: Int) -> Int {
        guard a <= b else { return 0 }
        let length = b - a + 1
        let perWeek = (0..<7).filter { isWorkDay(a + $0) }.count
        return length / 7 * perWeek + (0..<(length % 7)).filter { isWorkDay(a + $0) }.count
    }
}

/// The dashboard's formulas (design 02-metrics.md).
enum KanbanMetrics {
    // MARK: - §0 Load, weight, target, utilisation

    static func measure(_ s: MetricsSnapshot, _ c: MetricsSnapshot.Card) -> Double {
        s.loadMeasure == .taskCount ? 1 : (c.estimateHours ?? s.defaultEstimateHours)
    }

    /// Critical ×2 and High ×1.5, combined with `max` so flags never compound (02 §0).
    static func weight(_ s: MetricsSnapshot, _ c: MetricsSnapshot.Card) -> Double {
        guard s.weightedLoad else { return 1 }
        return max(c.isCritical ? 2 : 1, c.priority == TaskPriority.high.rawValue ? 1.5 : 1)
    }

    static func load(_ s: MetricsSnapshot, _ c: MetricsSnapshot.Card) -> Double { measure(s, c) * weight(s, c) }

    /// A card's load in each of the weeks `0..<weeks` (02 §1 (2)). Count mode adds the whole
    /// load to every week the window touches; hours mode spreads it over the window's
    /// remaining work days, or puts it all in the end week if there are none.
    static func weeklyLoads(_ s: MetricsSnapshot, _ d: MetricsDays, _ c: MetricsSnapshot.Card, weeks: Int) -> [Double] {
        let s0 = c.startDate.map(d.offset) ?? c.dueDate.map(d.offset) ?? d.today
        let e0 = c.dueDate.map(d.offset) ?? s0
        let start = min(s0, e0), end = max(s0, e0, d.today)
        let v = load(s, c)
        guard s.loadMeasure == .hours else {
            return (0..<weeks).map { start <= 7 * $0 + 6 && end >= 7 * $0 ? v : 0 }
        }
        let from = max(start, d.today)
        let spread = d.workDays(from, end)
        guard spread > 0 else {
            let endWeek = end / 7
            return (0..<weeks).map { $0 == endWeek ? v : 0 }
        }
        return (0..<weeks).map { k in v * Double(d.workDays(max(from, 7 * k), min(end, 7 * k + 6))) / Double(spread) }
    }

    /// v₀: this week's share of a card's load.
    static func thisWeek(_ s: MetricsSnapshot, _ d: MetricsDays, _ c: MetricsSnapshot.Card) -> Double {
        weeklyLoads(s, d, c, weeks: 1)[0]
    }

    static func countTarget(_ s: MetricsSnapshot, _ m: MetricsSnapshot.Member) -> Double {
        m.openTaskTargetOverride ?? s.openTaskTarget * Double(m.allocationPercent) / 100
    }

    static func hoursTarget(_ s: MetricsSnapshot, _ m: MetricsSnapshot.Member) -> Double {
        m.capacityHoursOverride ?? s.defaultCapacityHoursPerWeek * Double(m.allocationPercent) / 100
    }

    static func target(_ s: MetricsSnapshot, _ m: MetricsSnapshot.Member) -> Double {
        s.loadMeasure == .taskCount ? countTarget(s, m) : hoursTarget(s, m)
    }

    enum Band: String, Sendable { case green, amber, red }

    enum Utilisation: Sendable, Equatable {
        case ratio(Double, Band)
        case noCapacity(load: Double)

        var band: Band? { if case let .ratio(_, band) = self { band } else { nil } }
        var value: Double? { if case let .ratio(u, _) = self { u } else { nil } }
    }

    static func utilisation(load: Double, target: Double) -> Utilisation {
        guard target > 0 else { return .noCapacity(load: load) }
        let u = load / target, ε = 1e-9
        return .ratio(u, u <= 0.8 + ε ? .green : u <= 1.0 + ε ? .amber : .red)
    }

    static func isActive(_ s: MetricsSnapshot, _ m: MetricsSnapshot.Member) -> Bool {
        !m.archived && (m.startDate.map { s.day($0) <= s.today } ?? true) && (m.endDate.map { s.day($0) >= s.today } ?? true)
    }

    // MARK: - (1) Load vs capacity

    struct LoadRow: Sendable, Equatable {
        /// nil is the Unassigned row.
        var memberID: UUID?
        var name: String
        /// This week's load in each non-done column, in board order.
        var segments: [Segment]
        var load: Double
        /// nil for the Unassigned row.
        var target: Double?
        var utilisation: Utilisation?
        /// Hours mode only: total open hours ÷ weekly hours, in weeks. Never part of the band.
        var backlogCoverageWeeks: Double?

        struct Segment: Sendable, Equatable {
            var column: UUID
            var load: Double
        }
    }

    struct Filter: Sendable {
        var employment: Set<KanbanEmployment> = [.fte, .contractor]
        var assignment: Set<KanbanAssignment> = [.fullTime, .partTime]
        static let all = Filter()
    }

    static func loadVsCapacity(_ s: MetricsSnapshot, filter: Filter = .all) -> [LoadRow] {
        guard !filter.employment.isEmpty, !filter.assignment.isEmpty else { return [] }
        let d = MetricsDays(s)
        let openColumns = s.columns.filter { $0.kind != .done }
        let byResource = Dictionary(grouping: s.cards.filter(s.isOpen)) { $0.resource }
        func row(_ member: MetricsSnapshot.Member?) -> LoadRow {
            let cards = byResource[member?.id] ?? []
            let segments = openColumns.map { column in
                LoadRow.Segment(column: column.id, load: cards.filter { $0.column == column.id }.reduce(0) { $0 + thisWeek(s, d, $1) })
            }
            let total = segments.reduce(0) { $0 + $1.load }
            guard let member else {
                return LoadRow(memberID: nil, name: "Unassigned", segments: segments, load: total)
            }
            let t = target(s, member), hours = hoursTarget(s, member)
            let coverage = s.loadMeasure == .hours && hours > 0 ? cards.reduce(0) { $0 + load(s, $1) } / hours : nil
            return LoadRow(memberID: member.id, name: member.name, segments: segments, load: total, target: t,
                           utilisation: utilisation(load: total, target: t), backlogCoverageWeeks: coverage)
        }
        let members = s.members.filter {
            !$0.archived && filter.employment.contains($0.employment) && filter.assignment.contains($0.assignment)
        }
        return [row(nil)] + members.map { row($0) }
    }

    /// The drag preview (02 §1): `member`'s load if the `dragged` cards were dropped on
    /// `toColumn` / `toResource`, in the same weekly units as the headline.
    static func projectedLoad(_ s: MetricsSnapshot, member: MetricsSnapshot.Member, dragged: Set<UUID>,
                              toColumn: UUID, toResource: UUID?) -> (load: Double, target: Double, utilisation: Utilisation) {
        let d = MetricsDays(s)
        let current = s.cards.filter { s.isOpen($0) && $0.resource == member.id }.reduce(0) { $0 + thisWeek(s, d, $1) }
        let landsOpen = s.columns.first { $0.id == toColumn }?.kind != .done
        var delta = 0.0
        for card in s.cards where dragged.contains(card.id) && !card.archived {
            let countedBefore = card.resource == member.id && s.isOpen(card)
            let countedAfter = toResource == member.id && landsOpen
            if countedBefore != countedAfter { delta += countedAfter ? thisWeek(s, d, card) : -thisWeek(s, d, card) }
        }
        let t = target(s, member)
        return (current + delta, t, utilisation(load: current + delta, target: t))
    }

    // MARK: - (2) Capacity heatmap

    enum HeatCell: Sendable, Equatable {
        case ratio(load: Double, target: Double, Band)
        /// The member isn't on the board on any work day that week.
        case unavailable(load: Double)
        /// The board has no work days.
        case noCapacity
    }

    struct HeatRow: Sendable, Equatable {
        var memberID: UUID
        var name: String
        var weeks: [HeatCell]
    }

    static func capacityHeatmap(_ s: MetricsSnapshot, weeks: Int = 12) -> [HeatRow] {
        let n = min(max(weeks, 1), 26)
        let d = MetricsDays(s)
        let byResource = Dictionary(grouping: s.cards.filter(s.isOpen)) { $0.resource }
        return s.members.filter { !$0.archived }.map { member in
            guard !s.workWeekDays.isEmpty else {
                return HeatRow(memberID: member.id, name: member.name, weeks: Array(repeating: .noCapacity, count: n))
            }
            var loads = Array(repeating: 0.0, count: n)
            for card in byResource[member.id] ?? [] {
                for (k, v) in weeklyLoads(s, d, card, weeks: n).enumerated() { loads[k] += v }
            }
            let lower = member.startDate.map(d.offset) ?? .min / 2, upper = member.endDate.map(d.offset) ?? .max / 2
            let cells = (0..<n).map { k -> HeatCell in
                let available = Double(d.workDays(max(7 * k, lower), min(7 * k + 6, upper)))
                let target = KanbanMetrics.target(s, member) * available / Double(d.workDays(7 * k, 7 * k + 6))
                guard target > 0 else { return .unavailable(load: loads[k]) }
                return .ratio(load: loads[k], target: target, utilisation(load: loads[k], target: target).band ?? .green)
            }
            return HeatRow(memberID: member.id, name: member.name, weeks: cells)
        }
    }

    // MARK: - (3) Team composition

    struct Composition: Sendable, Equatable {
        struct Cell: Sendable, Equatable {
            var count = 0
            var hours = 0.0
        }

        struct RollOff: Sendable, Equatable {
            var memberID: UUID
            var daysLeft: Int
            var openCards: Int
        }

        var grid: [KanbanEmployment: [KanbanAssignment: Cell]]
        var notStarted: [UUID]
        /// Contractors ending within 0…30, 31…60 and 61…90 days, keyed 30, 60 and 90.
        var rollOff: [Int: [RollOff]]
    }

    static func composition(_ s: MetricsSnapshot) -> Composition {
        var result = Composition(
            grid: Dictionary(uniqueKeysWithValues: KanbanEmployment.allCases.map { e in
                (e, Dictionary(uniqueKeysWithValues: KanbanAssignment.allCases.map { ($0, Composition.Cell()) }))
            }),
            notStarted: [], rollOff: [30: [], 60: [], 90: []])
        for m in s.members where !m.archived {
            if let start = m.startDate, s.day(start) > s.today {
                result.notStarted.append(m.id)
                continue
            }
            guard isActive(s, m) else { continue }
            result.grid[m.employment]?[m.assignment]?.count += 1
            result.grid[m.employment]?[m.assignment]?.hours += hoursTarget(s, m)
            guard m.employment == .contractor, let end = m.endDate else { continue }
            let daysLeft = s.days(from: s.today, to: end)
            guard let bucket = [30, 60, 90].first(where: { daysLeft <= $0 }) else { continue }
            let open = s.cards.filter { s.isOpen($0) && $0.resource == m.id }.count
            result.rollOff[bucket]?.append(.init(memberID: m.id, daysLeft: daysLeft, openCards: open))
        }
        return result
    }

    // MARK: - (3b) People rollup across boards

    struct PersonRow: Sendable, Equatable {
        struct Figure: Sendable, Equatable {
            var load: Double
            var target: Double
            var utilisation: Utilisation
        }

        struct BoardCell: Sendable, Equatable {
            var projectID: UUID
            var projectName: String
            var row: LoadRow
        }

        var personID: UUID
        var name: String
        var totalAllocation: Int
        var overAllocated: Bool
        /// Weighted open cards against the summed count targets, whatever each board's mode.
        var count: Figure
        /// This week's hours, only when every board is in hours mode.
        var hours: Figure?
        /// What the band, badge and ordering use: hours if present, otherwise the count.
        var headline: Utilisation { hours?.utilisation ?? count.utilisation }
        var boards: [BoardCell]
    }

    static func peopleRollup(_ boards: [MetricsSnapshot]) -> [PersonRow] {
        var memberships: [UUID: [(board: MetricsSnapshot, member: MetricsSnapshot.Member, row: LoadRow?)]] = [:]
        for board in boards where !board.projectArchived {
            let rows = Dictionary(loadVsCapacity(board).compactMap { row in row.memberID.map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
            for m in board.members where isActive(board, m) {
                memberships[m.personID, default: []].append((board, m, rows[m.id]))
            }
        }
        let rows = memberships.map { personID, entries -> PersonRow in
            var countLoad = 0.0, countTarget = 0.0, hoursLoad = 0.0, hoursTarget = 0.0
            for (board, m, row) in entries {
                countLoad += board.cards.filter { board.isOpen($0) && $0.resource == m.id }.reduce(0) { $0 + weight(board, $1) }
                countTarget += KanbanMetrics.countTarget(board, m)
                hoursLoad += row?.load ?? 0
                hoursTarget += KanbanMetrics.hoursTarget(board, m)
            }
            let allHours = entries.allSatisfy { $0.board.loadMeasure == .hours }
            let total = entries.reduce(0) { $0 + $1.member.allocationPercent }
            return PersonRow(
                personID: personID, name: entries[0].member.name, totalAllocation: total, overAllocated: total > 100,
                count: .init(load: countLoad, target: countTarget, utilisation: utilisation(load: countLoad, target: countTarget)),
                hours: allHours ? .init(load: hoursLoad, target: hoursTarget, utilisation: utilisation(load: hoursLoad, target: hoursTarget)) : nil,
                boards: entries.compactMap { e in e.row.map { .init(projectID: e.board.projectID, projectName: e.board.projectName, row: $0) } })
        }
        func rank(_ r: PersonRow) -> Double {
            switch r.headline {
            case let .ratio(u, _): u
            case let .noCapacity(load): load > 0 ? .infinity : -1
            }
        }
        return rows.sorted { rank($0) != rank($1) ? rank($0) > rank($1) : ($0.name, $0.personID.uuidString) < ($1.name, $1.personID.uuidString) }
    }

    // MARK: - (4) Tasks by column and by resource

    static func tasksByColumn(_ s: MetricsSnapshot) -> [(column: UUID, count: Int, load: Double)] {
        let live = s.cards.filter { !$0.archived }
        return s.columns.map { column in
            let cards = live.filter { $0.column == column.id }
            return (column.id, cards.count, cards.reduce(0) { $0 + measure(s, $1) })
        }
    }

    /// Per member (nil = Unassigned), per column: Σ m over live cards.
    static func tasksByResource(_ s: MetricsSnapshot) -> [UUID?: [UUID: Double]] {
        var result: [UUID?: [UUID: Double]] = [:]
        for card in s.cards where !card.archived { result[card.resource, default: [:]][card.column, default: 0] += measure(s, card) }
        return result
    }

    // MARK: - (5) Unassigned backlog

    enum PriorityRow: String, CaseIterable, Sendable { case critical = "Critical", high = "High", medium = "Medium", low = "Low" }

    /// Critical is its own, exclusive row.
    static func priorityRow(_ c: MetricsSnapshot.Card) -> PriorityRow {
        if c.isCritical { return .critical }
        switch TaskPriority(rawValue: c.priority) ?? .low {
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }

    struct Backlog: Sendable, Equatable {
        /// Oldest first.
        var items: [UUID]
        var byPriority: [PriorityRow: Int]
        /// nil is "No label".
        var byLabel: [UUID?: Int]
        var ready: [UUID]
        /// Ready except for a prerequisite that is archived: "Waiting on an archived task".
        var waitingOnArchived: [UUID]
        var unassignedActiveCount: Int
    }

    static func unassignedBacklog(_ s: MetricsSnapshot) -> Backlog {
        let byID = Dictionary(s.cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cards = s.cards.filter { !$0.archived && $0.resource == nil && s.kind(of: $0) == .backlog }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var result = Backlog(items: cards.map(\.id), byPriority: Dictionary(uniqueKeysWithValues: PriorityRow.allCases.map { ($0, 0) }),
                             byLabel: [:], ready: [], waitingOnArchived: [],
                             unassignedActiveCount: s.cards.filter { !$0.archived && $0.resource == nil && s.kind(of: $0) == .active }.count)
        for c in cards {
            result.byPriority[priorityRow(c), default: 0] += 1
            if c.labels.isEmpty { result.byLabel[nil, default: 0] += 1 }
            for label in c.labels { result.byLabel[label, default: 0] += 1 }
            // A prerequisite that no longer exists can't block; an archived one does, because
            // archiving can be undone.
            let prerequisites = c.dependsOn.compactMap { byID[$0] }
            guard !c.isBlocked else { continue }
            if prerequisites.allSatisfy(s.isDone) {
                result.ready.append(c.id)
            } else if prerequisites.allSatisfy({ s.isDone($0) || $0.archived }) {
                result.waitingOnArchived.append(c.id)
            }
        }
        return result
    }

    // MARK: - (6) Priority × column, (7) label mix

    static func priorityMatrix(_ s: MetricsSnapshot) -> [PriorityRow: [UUID: Double]] {
        var result = Dictionary(uniqueKeysWithValues: PriorityRow.allCases.map { ($0, [UUID: Double]()) })
        for c in s.cards where !c.archived { result[priorityRow(c), default: [:]][c.column, default: 0] += measure(s, c) }
        return result
    }

    /// Per column, per label (nil = no label). A card with k labels counts once per label.
    static func labelMix(_ s: MetricsSnapshot) -> [UUID: [UUID?: Double]] {
        var result: [UUID: [UUID?: Double]] = [:]
        for c in s.cards where !c.archived {
            let labels: [UUID?] = c.labels.isEmpty ? [nil] : c.labels
            for label in labels { result[c.column, default: [:]][label, default: 0] += measure(s, c) }
        }
        return result
    }

    // MARK: - (8) Blocked

    struct Blocked: Sendable, Equatable {
        var cardID: UUID
        var reason: String
        var ageDays: Int
    }

    /// Oldest first.
    static func blockedTasks(_ s: MetricsSnapshot) -> [Blocked] {
        s.cards.filter { s.isOpen($0) && $0.isBlocked }.map { c in
            let reason = c.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Blocked(cardID: c.id, reason: reason.isEmpty ? "No reason given" : reason,
                           ageDays: s.days(from: s.blockedSince[c.id] ?? c.updatedAt, to: s.now))
        }.sorted { $0.ageDays != $1.ageDays ? $0.ageDays > $1.ageDays : $0.cardID.uuidString < $1.cardID.uuidString }
    }

    // MARK: - (9) Due dates

    struct Due: Sendable, Equatable {
        /// Most overdue first.
        var overdue: [UUID] = []
        var thisWeek: [UUID] = []
        var nextWeek: [UUID] = []
        /// nil is Unassigned.
        var overdueByResource: [UUID?: [UUID]] = [:]
    }

    static func dueBuckets(_ s: MetricsSnapshot) -> Due {
        let d = MetricsDays(s)
        var due = Due()
        let dated = s.cards.compactMap { c in c.dueDate.map { (card: c, day: d.offset($0)) } }
            .filter { s.isOpen($0.card) }
            .sorted { ($0.day, $0.card.id.uuidString) < ($1.day, $1.card.id.uuidString) }
        for (card, day) in dated {
            if day < d.today {
                due.overdue.append(card.id)
                due.overdueByResource[card.resource, default: []].append(card.id)
            } else if day < 7 {
                due.thisWeek.append(card.id)
            } else if day < 14 {
                due.nextWeek.append(card.id)
            }
        }
        return due
    }

    // MARK: - (13) Hygiene

    struct Hygiene: Sendable, Equatable {
        var missingDue: [UUID] = []
        var missingJira: [UUID] = []
        var missingEstimate: [UUID] = []
        var subtasksDoneNotDone: [UUID] = []
        var doneWithOpenSubtasks: [UUID] = []
        var idleResources: [UUID] = []
        /// Archived memberships included.
        var pastEndHoldingWork: [UUID] = []
    }

    static func hygieneReport(_ s: MetricsSnapshot) -> Hygiene {
        var h = Hygiene()
        for c in s.cards where !c.archived {
            if s.isOpen(c) {
                if c.dueDate == nil { h.missingDue.append(c.id) }
                let url = (c.jiraURL ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if !(url.hasPrefix("http://") || url.hasPrefix("https://")) { h.missingJira.append(c.id) }
                if s.loadMeasure == .hours, c.estimateHours == nil { h.missingEstimate.append(c.id) }
                if c.subtasksTotal > 0, c.subtasksDone == c.subtasksTotal { h.subtasksDoneNotDone.append(c.id) }
            } else if c.subtasksDone < c.subtasksTotal {
                h.doneWithOpenSubtasks.append(c.id)
            }
        }
        let openByResource = Dictionary(grouping: s.cards.filter(s.isOpen)) { $0.resource }
        for m in s.members {
            let holding = openByResource[m.id]?.count ?? 0
            if isActive(s, m), holding == 0 { h.idleResources.append(m.id) }
            if let end = m.endDate, s.day(end) < s.today, holding > 0 { h.pastEndHoldingWork.append(m.id) }
        }
        return h
    }

    // MARK: - All projects overview

    struct ProjectSummary: Sendable, Equatable {
        var projectID: UUID
        var name: String
        /// This week's load and target summed over the board's members.
        var load: Double
        var target: Double
        var utilisation: Utilisation
        var openCards: Int
        var doneCards: Int
        var overdue: Int
        var rollingOffWithin30Days: Int
        var membersOverCapacity: Int
    }

    static func summary(_ s: MetricsSnapshot) -> ProjectSummary {
        let rows = loadVsCapacity(s).filter { $0.memberID != nil }
        let load = rows.reduce(0) { $0 + $1.load }, target = rows.reduce(0) { $0 + ($1.target ?? 0) }
        return ProjectSummary(
            projectID: s.projectID, name: s.projectName, load: load, target: target,
            utilisation: utilisation(load: load, target: target),
            openCards: s.cards.filter(s.isOpen).count, doneCards: s.cards.filter(s.isDone).count,
            overdue: dueBuckets(s).overdue.count, rollingOffWithin30Days: composition(s).rollOff[30]?.count ?? 0,
            membersOverCapacity: rows.filter { $0.utilisation?.band == .red }.count)
    }
}

extension MetricsSnapshot {
    /// A snapshot of `project`. `now` and `calendar` are passed in so the numbers are
    /// reproducible: the app passes the current time and its week-start calendar.
    @MainActor
    init(project: KanbanProject, now: Date, calendar: Calendar) {
        var blockedSince: [UUID: Date] = [:]
        for activity in project.activities.sorted(by: { $0.seq < $1.seq }) where activity.kindRaw == KanbanActivityKind.edited.rawValue {
            guard let payload = try? KanbanActivityPayload.decode(activity.payload) else { continue }
            for change in payload.changes where change.entity == .task && change.field == "isBlocked" && change.new == .bool(true) {
                blockedSince[change.id] = activity.at
            }
        }
        self.init(
            projectID: project.id, projectName: project.name, projectArchived: project.archivedAt != nil,
            loadMeasure: project.loadMeasure, weightedLoad: project.weightedLoad, openTaskTarget: project.openTaskTarget,
            defaultCapacityHoursPerWeek: project.defaultCapacityHoursPerWeek, defaultEstimateHours: project.defaultEstimateHours,
            workWeekDays: Set(project.workWeekDays),
            columns: project.orderedColumns.map { Column(id: $0.id, name: $0.name, kind: $0.kind) },
            members: project.resources.sorted { $0.sortIndex < $1.sortIndex }.map { r in
                Member(id: r.id, personID: r.person?.id ?? r.id, name: r.displayName, employment: r.person?.employment ?? .fte,
                       assignment: r.assignment, allocationPercent: r.allocationPercent,
                       capacityHoursOverride: r.capacityHoursPerWeekOverride, openTaskTargetOverride: r.openTaskTargetOverride,
                       startDate: r.startDate, endDate: r.endDate, archived: r.archivedAt != nil)
            },
            cards: project.tasks.compactMap { t in
                guard let column = t.column else { return nil }
                return Card(id: t.id, title: t.title, column: column.id, resource: t.resource?.id, priority: t.priority,
                            isCritical: t.isCritical, dueDate: t.dueDate, startDate: t.startDate, estimateHours: t.estimateHours,
                            isBlocked: t.isBlocked, blockedReason: t.blockedReason, dependsOn: t.dependsOn.map(\.id),
                            labels: t.labels.map(\.id), subtasksDone: t.subtasks.filter(\.isDone).count, subtasksTotal: t.subtasks.count,
                            jiraURL: t.jiraURL, createdAt: t.createdAt, updatedAt: t.updatedAt, archived: t.archivedAt != nil)
            },
            blockedSince: blockedSince, now: now, calendar: calendar)
    }
}
