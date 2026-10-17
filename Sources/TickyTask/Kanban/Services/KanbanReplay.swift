import Foundation
import SwiftData

/// A change-log entry for replay: the board's history as data (design 02 §3).
struct MetricsActivity: Sendable {
    var seq: Int
    var at: Date
    var kind: KanbanActivityKind
    var payload: KanbanActivityPayload
}

/// The time metrics (design 02 §3, metrics 10–12 and aging): one sweep over the change log
/// in `seq` order rebuilds each day's board, so the charts show what the board looked like.
enum KanbanReplay {
    struct Band: Equatable, Sendable {
        var columnID: UUID
        var name: String
        var kind: KanbanColumnKind
        /// The column no longer exists; drawn grey, named from the stored snapshot.
        var isDeleted: Bool
        var count: Int
        var load: Double
    }

    struct Day: Equatable, Sendable {
        var day: Date
        /// Done first, then active, then backlog, then deleted columns (stacking order).
        var bands: [Band]
    }

    private struct CardState {
        var column: UUID
        var visible: Bool
    }

    /// Each day in `[from, through]`, after the activities before the next day's start.
    static func replay(_ s: MetricsSnapshot, activities: [MetricsActivity], from: Date, through: Date) -> [Day] {
        var known: [UUID: (name: String, kind: KanbanColumnKind)] = [:]
        for column in s.columns { known[column.id] = (column.name, column.kind) }
        let live = Set(s.columns.map(\.id))
        let order = Dictionary(s.columns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let estimates = Dictionary(s.cards.map { ($0.id, KanbanMetrics.measure(s, $0)) }, uniquingKeysWith: { a, _ in a })

        let events = activities.sorted { $0.seq < $1.seq }
        // Applied in seq order. A clock change can date an entry later than ones after it;
        // it then counts from the next entry's time, so it can't hold back what follows.
        var effective = events.map(\.at)
        for i in effective.indices.reversed().dropFirst() { effective[i] = min(effective[i], effective[i + 1]) }
        // Cards with no `created` entry (from before the log existed) get one at createdAt, in
        // the column their earliest move left, or else their current column.
        var created = Set<UUID>()
        var firstFrom: [UUID: UUID] = [:]
        for event in events {
            if event.kind == .created || event.kind == .restoredGraph { event.payload.graph?.tasks.forEach { created.insert($0.id) } }
            for t in event.payload.transitions where firstFrom[t.taskID] == nil { firstFrom[t.taskID] = t.from.columnID }
        }
        var synthesized: [(Date, UUID, UUID)] = []
        for card in s.cards where !created.contains(card.id) {
            synthesized.append((card.createdAt, card.id, firstFrom[card.id] ?? card.column))
        }

        var cards: [UUID: CardState] = [:]
        func record(_ r: KanbanPlacementRecord) {
            if known[r.columnID] == nil, let kind = KanbanColumnKind(rawValue: r.columnKind) { known[r.columnID] = (r.columnName, kind) }
        }
        func apply(_ event: MetricsActivity) {
            let graph = event.payload.graph
            graph?.columns.forEach { dto in
                if known[dto.id] == nil, let kind = KanbanColumnKind(rawValue: dto.kindRaw) { known[dto.id] = (dto.name, kind) }
            }
            switch event.kind {
            case .created, .restoredGraph:
                for dto in graph?.tasks ?? [] {
                    if let column = dto.columnId { cards[dto.id] = CardState(column: column, visible: dto.archivedAt == nil) }
                }
            case .deleted:
                for dto in graph?.tasks ?? [] { cards[dto.id] = nil }
            default:
                break
            }
            for t in event.payload.transitions {
                record(t.from)
                record(t.to)
                cards[t.taskID]?.column = t.to.columnID
            }
            for change in event.payload.changes where change.entity == .task && change.field == "archivedAt" {
                cards[change.id]?.visible = change.new == nil
            }
        }

        let cal = s.calendar
        var days: [Day] = []
        var day = cal.startOfDay(for: from)
        let last = cal.startOfDay(for: through)
        var index = 0
        synthesized.sort { $0.0 < $1.0 }
        var syntheticIndex = 0
        while day <= last {
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            while syntheticIndex < synthesized.count, synthesized[syntheticIndex].0 < next {
                let (_, id, column) = synthesized[syntheticIndex]
                cards[id] = CardState(column: column, visible: true)
                syntheticIndex += 1
            }
            while index < events.count, effective[index] < next {
                apply(events[index])
                index += 1
            }
            var bands: [UUID: Band] = [:]
            for (id, card) in cards where card.visible {
                guard let info = known[card.column] else { continue }
                bands[card.column, default: Band(columnID: card.column, name: info.name, kind: info.kind,
                                                 isDeleted: !live.contains(card.column), count: 0, load: 0)].count += 1
                bands[card.column]?.load += estimates[id] ?? (s.loadMeasure == .taskCount ? 1 : s.defaultEstimateHours)
            }
            // Live columns always appear (zero when empty), so bands line up from day to day.
            for column in s.columns where bands[column.id] == nil {
                bands[column.id] = Band(columnID: column.id, name: column.name, kind: column.kind, isDeleted: false, count: 0, load: 0)
            }
            func rank(_ b: Band) -> (Int, Int) {
                let kindRank = b.isDeleted ? 3 : b.kind == .done ? 0 : b.kind == .active ? 1 : 2
                return (kindRank, order[b.columnID] ?? .max)
            }
            days.append(Day(day: day, bands: bands.values.sorted { rank($0) < rank($1) }))
            day = next
        }
        return days
    }

    // MARK: - (10) Cumulative flow, (12) burn-up

    /// The last `days` days of the replay (count, or hours in hours mode, per band).
    static func cfd(_ s: MetricsSnapshot, activities: [MetricsActivity], days: Int = 90) -> [Day] {
        let today = s.calendar.startOfDay(for: s.now)
        let from = s.calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        return replay(s, activities: activities, from: from, through: today)
    }

    struct BurnUpPoint: Equatable, Sendable {
        var day: Date
        var scope: Double
        var completed: Double
    }

    /// Scope (every visible band) and completed (the Done bands), in tasks or current-estimate hours.
    static func burnUp(_ s: MetricsSnapshot, activities: [MetricsActivity], days: Int = 90) -> [BurnUpPoint] {
        cfd(s, activities: activities, days: days).map { day in
            let value: (Band) -> Double = { s.loadMeasure == .hours ? $0.load : Double($0.count) }
            return BurnUpPoint(day: day.day, scope: day.bands.reduce(0) { $0 + value($1) },
                               completed: day.bands.filter { $0.kind == .done }.reduce(0) { $0 + value($1) })
        }
    }

    // MARK: - (11) Throughput, aging

    struct Week: Equatable, Sendable {
        var start: Date
        var completed: Int
        var reopened: Int
        /// The current week, still in progress.
        var partial: Bool
    }

    /// "Completed work (by latest completion)": each card counts once, in the week of its
    /// latest completion, if it's in Done now (archived ones too). Reopens are their own series.
    static func throughput(_ s: MetricsSnapshot, activities: [MetricsActivity], weeks: Int = 12) -> [Week] {
        let n = max(weeks, 1)
        let current = s.weekStart(s.today)
        let starts = (0..<n).reversed().compactMap { s.calendar.date(byAdding: .day, value: -7 * $0, to: current) }
        let doneNow = Set(s.cards.filter { s.kind(of: $0) == .done }.map(\.id))
        var latest: [UUID: Date] = [:]
        var reopens: [Date] = []
        for event in activities.sorted(by: { $0.seq < $1.seq }) where event.kind == .moved {
            for t in event.payload.transitions {
                let from = KanbanColumnKind(rawValue: t.from.columnKind), to = KanbanColumnKind(rawValue: t.to.columnKind)
                if from != .done, to == .done { latest[t.taskID] = event.at }
                if from == .done, to != .done { reopens.append(event.at) }
            }
        }
        func week(_ date: Date) -> Date { s.weekStart(date) }
        return starts.map { start in
            Week(start: start,
                 completed: latest.filter { doneNow.contains($0.key) && week($0.value) == start }.count,
                 reopened: reopens.filter { week($0) == start }.count,
                 partial: start == current)
        }
    }

    struct Aging: Equatable, Sendable {
        var cardID: UUID
        var columnID: UUID
        var ageDays: Int
    }

    /// Open cards in active columns: days since they entered their current column (a
    /// resource-only move doesn't count), oldest first.
    static func agingWIP(_ s: MetricsSnapshot, activities: [MetricsActivity]) -> [Aging] {
        var entered: [UUID: Date] = [:]
        for event in activities.sorted(by: { $0.seq < $1.seq }) {
            if event.kind == .created || event.kind == .restoredGraph {
                for dto in event.payload.graph?.tasks ?? [] { entered[dto.id] = event.at }
            }
            for t in event.payload.transitions where t.from.columnID != t.to.columnID { entered[t.taskID] = event.at }
        }
        // `entered` is the latest entry into some column; it's the current one because the last
        // column-changing transition put the card where it is now.
        return s.cards.filter { s.isOpen($0) && s.kind(of: $0) == .active }
            .map { Aging(cardID: $0.id, columnID: $0.column, ageDays: s.days(from: entered[$0.id] ?? $0.createdAt, to: s.now)) }
            .sorted { $0.ageDays != $1.ageDays ? $0.ageDays > $1.ageDays : $0.cardID.uuidString < $1.cardID.uuidString }
    }
}

extension MetricsActivity {
    /// A board's change log, decoded for replay (entries that don't decode are skipped).
    @MainActor
    static func records(of project: KanbanProject) -> [MetricsActivity] {
        // Fetched, not `project.activities`: the inverse array can lag behind a save (I-D4).
        let id = project.id
        let entries = (try? project.modelContext?.fetch(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id })))
            ?? project.activities
        return entries.compactMap { activity in
            guard let kind = KanbanActivityKind(rawValue: activity.kindRaw),
                  let payload = try? KanbanActivityPayload.decode(activity.payload) else { return nil }
            return MetricsActivity(seq: activity.seq, at: activity.at, kind: kind, payload: payload)
        }
    }
}
