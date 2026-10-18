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
    /// One pass: per-column counts are kept up to date as entries apply, so each day costs O(C).
    static func replay(_ s: MetricsSnapshot, activities: [MetricsActivity], from: Date, through: Date) -> [Day] {
        let events = activities.sorted { $0.seq < $1.seq }
        // Applied in seq order. A clock change can date an entry later than ones after it;
        // it then counts from the next entry's time, so it can't hold back what follows.
        var effective = events.map(\.at)
        for i in effective.indices.reversed().dropFirst() { effective[i] = min(effective[i], effective[i + 1]) }

        // Every column's name: live ones, then every snapshot in the log (a deleted default
        // column is only described by the entry that deleted it).
        let live = Set(s.columns.map(\.id))
        let order = Dictionary(s.columns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var names: [UUID: String] = Dictionary(s.columns.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var kinds: [UUID: KanbanColumnKind] = Dictionary(s.columns.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        for event in events.reversed() {   // the latest snapshot of a deleted column wins
            for dto in event.payload.graph?.columns ?? [] where names[dto.id] == nil {
                names[dto.id] = dto.name
                kinds[dto.id] = KanbanColumnKind(rawValue: dto.kindRaw)
            }
            for t in event.payload.transitions {
                for r in [t.to, t.from] where names[r.columnID] == nil {
                    names[r.columnID] = r.columnName
                    kinds[r.columnID] = KanbanColumnKind(rawValue: r.columnKind)
                }
            }
        }
        // A column's kind changed only while empty (01 §2.2); walk back to its first kind.
        for event in events.reversed() {
            for change in event.payload.changes where change.entity == .column && change.field == "kind" {
                if case let .string(raw)? = change.old, let kind = KanbanColumnKind(rawValue: raw) { kinds[change.id] = kind }
            }
        }

        // Each card's load: its current measure, or the estimate its deletion recorded.
        var weight = Dictionary(s.cards.map { ($0.id, KanbanMetrics.measure(s, $0)) }, uniquingKeysWith: { a, _ in a })
        var deletedDTO: [UUID: KanbanTaskDTO] = [:]
        for event in events where event.kind == .deleted {
            for dto in event.payload.graph?.tasks ?? [] { deletedDTO[dto.id] = dto }
        }
        for (id, dto) in deletedDTO where weight[id] == nil {
            weight[id] = s.loadMeasure == .taskCount ? 1 : (dto.estimateHours ?? s.defaultEstimateHours)
        }

        // Cards with no `created` entry (from before the log existed) get one at their
        // createdAt, in the column their earliest move left, or else where they are (or
        // were, when deleted). A restoredGraph is a re-creation, not the original one.
        var created = Set<UUID>()
        var firstFrom: [UUID: UUID] = [:]
        for event in events {
            if event.kind == .created { event.payload.graph?.tasks.forEach { created.insert($0.id) } }
            for t in event.payload.transitions where firstFrom[t.taskID] == nil { firstFrom[t.taskID] = t.from.columnID }
        }
        var synthesized: [(at: Date, id: UUID, column: UUID)] = []
        // And an archive at their archivedAt when the log has no archive entry for them.
        var archivedInLog = Set<UUID>()
        var hidden: [(at: Date, id: UUID)] = []
        for event in events {
            for change in event.payload.changes where change.entity == .task && change.field == "archivedAt" {
                // The first logged change of a legacy card that was already archived (a
                // restore) says when: its old value.
                if archivedInLog.insert(change.id).inserted, !created.contains(change.id), case let .date(at)? = change.old {
                    hidden.append((at, change.id))
                }
            }
        }
        let current = Set(s.cards.map(\.id))
        for card in s.cards where !created.contains(card.id) {
            synthesized.append((card.createdAt, card.id, firstFrom[card.id] ?? card.column))
            if let at = card.archivedAt, !archivedInLog.contains(card.id) { hidden.append((at, card.id)) }
        }
        for (id, dto) in deletedDTO where !created.contains(id) && !current.contains(id) {
            if let column = firstFrom[id] ?? dto.columnId { synthesized.append((dto.createdAt, id, column)) }
            if let at = dto.archivedAt, !archivedInLog.contains(id) { hidden.append((at, id)) }
        }
        synthesized.sort { $0.at < $1.at }
        hidden.sort { $0.at < $1.at }

        var cards: [UUID: CardState] = [:]
        var count: [UUID: Int] = [:], load: [UUID: Double] = [:]
        func set(_ id: UUID, _ state: CardState?) {
            if let old = cards[id], old.visible {
                count[old.column, default: 0] -= 1
                load[old.column, default: 0] -= weight[id] ?? 0
            }
            cards[id] = state
            if let state, state.visible {
                count[state.column, default: 0] += 1
                load[state.column, default: 0] += weight[id] ?? 0
            }
        }
        func apply(_ event: MetricsActivity) {
            let graph = event.payload.graph
            switch event.kind {
            case .created, .restoredGraph:
                for dto in graph?.tasks ?? [] {
                    if let column = dto.columnId { set(dto.id, CardState(column: column, visible: dto.archivedAt == nil)) }
                }
            case .deleted:
                for dto in graph?.tasks ?? [] { set(dto.id, nil) }
            default:
                break
            }
            for t in event.payload.transitions {
                if var state = cards[t.taskID] {
                    state.column = t.to.columnID
                    set(t.taskID, state)
                }
            }
            for change in event.payload.changes {
                if change.entity == .task, change.field == "archivedAt", var state = cards[change.id] {
                    state.visible = change.new == nil
                    set(change.id, state)
                }
                if change.entity == .column, change.field == "kind", case let .string(raw)? = change.new, let kind = KanbanColumnKind(rawValue: raw) {
                    kinds[change.id] = kind
                }
            }
        }

        let cal = s.calendar
        var days: [Day] = []
        var day = cal.startOfDay(for: from)
        let last = cal.startOfDay(for: through)
        var index = 0, syntheticIndex = 0, hiddenIndex = 0
        // Inferred archives take their place among the logged events, so a later logged
        // restore still wins.
        func hideLegacy(while isDue: (Date) -> Bool) {
            while hiddenIndex < hidden.count, isDue(hidden[hiddenIndex].at) {
                if var state = cards[hidden[hiddenIndex].id] {
                    state.visible = false
                    set(hidden[hiddenIndex].id, state)
                }
                hiddenIndex += 1
            }
        }
        while day <= last {
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            while syntheticIndex < synthesized.count, synthesized[syntheticIndex].at < next {
                let entry = synthesized[syntheticIndex]
                if cards[entry.id] == nil { set(entry.id, CardState(column: entry.column, visible: true)) }
                syntheticIndex += 1
            }
            while index < events.count, effective[index] < next {
                let eventAt = effective[index]
                hideLegacy { $0 <= eventAt }
                apply(events[index])
                index += 1
            }
            hideLegacy { $0 < next }
            var bands: [Band] = []
            // Live columns always appear (zero when empty), so bands line up from day to day.
            for column in Set(live).union(count.filter { $0.value > 0 }.keys) {
                guard let name = names[column], let kind = kinds[column] else { continue }
                bands.append(Band(columnID: column, name: name, kind: kind, isDeleted: !live.contains(column),
                                  count: max(count[column] ?? 0, 0), load: max(load[column] ?? 0, 0)))
            }
            func rank(_ b: Band) -> (Int, Int, String) {
                let kindRank = b.isDeleted ? 3 : b.kind == .done ? 0 : b.kind == .active ? 1 : 2
                return (kindRank, order[b.columnID] ?? .max, b.columnID.uuidString)
            }
            days.append(Day(day: day, bands: bands.sorted { rank($0) < rank($1) }))
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
        burnUp(cfd(s, activities: activities, days: days), hours: s.loadMeasure == .hours)
    }

    /// The burn-up of an already replayed range (the dashboard replays once for both charts).
    static func burnUp(_ days: [Day], hours: Bool) -> [BurnUpPoint] {
        days.map { day in
            let value: (Band) -> Double = { hours ? $0.load : Double($0.count) }
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
        var completed: [Date: Int] = [:]
        var reopened: [Date: Int] = [:]
        for (id, date) in latest where doneNow.contains(id) {
            let week = s.weekStart(date)
            completed[week, default: 0] += 1
        }
        for date in reopens {
            let week = s.weekStart(date)
            reopened[week, default: 0] += 1
        }
        return starts.map { Week(start: $0, completed: completed[$0, default: 0],
                                 reopened: reopened[$0, default: 0], partial: $0 == current) }
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
