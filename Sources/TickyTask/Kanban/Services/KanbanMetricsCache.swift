import Foundation

/// Board snapshots and the people rollup, rebuilt only when the store generation, the
/// day, the week start or the time zone changes (design 01 §2.5, 02 §5). Scrolling and
/// other redraws read them for free.
@MainActor
final class KanbanMetricsCache {
    struct Key: Equatable {
        var generation: Int
        /// Day key and time zone (`AppState.kanbanClock`).
        var clock: String
        var weekStartsMonday: Bool
    }

    private var key: Key?
    private var snapshots: [UUID: MetricsSnapshot] = [:]
    private var rollup: (projects: [UUID], rows: [UUID: KanbanMetrics.PersonRow])?
    private var orderedPeople: (projects: [UUID], array: [KanbanMetrics.PersonRow])?
    private var logs: [UUID: [MetricsActivity]] = [:]
    private var flows: [UUID: [(days: Int, result: [KanbanReplay.Day])]] = [:]
    private var throughputs: [UUID: [(weeks: Int, result: [KanbanReplay.Week])]] = [:]
    private var agingCaches: [UUID: [KanbanReplay.Aging]] = [:]
    private var summaries: [UUID: KanbanMetrics.ProjectSummary] = [:]
    private var loadRowsCaches: [UUID: [KanbanMetrics.LoadRow]] = [:]

    /// A board's decoded change log, for the history charts.
    func activities(of project: KanbanProject, key: Key) -> [MetricsActivity] {
        reset(for: key)
        if let log = logs[project.id] { return log }
        let log = MetricsActivity.records(of: project)
        logs[project.id] = log
        return log
    }

    func snapshot(of project: KanbanProject, key: Key, calendar: Calendar) -> MetricsSnapshot {
        reset(for: key)
        if let snapshot = snapshots[project.id] { return snapshot }
        let snapshot = MetricsSnapshot(project: project, now: Date(), calendar: calendar)
        snapshots[project.id] = snapshot
        return snapshot
    }

    /// Each person's rollup across `projects`, by person id.
    func people(_ projects: [KanbanProject], key: Key, calendar: Calendar) -> [UUID: KanbanMetrics.PersonRow] {
        reset(for: key)
        let ids = projects.map(\.id)
        if let rollup, rollup.projects == ids { return rollup.rows }
        let rows = KanbanMetrics.peopleRollup(projects.map { snapshot(of: $0, key: key, calendar: calendar) })
        let result = Dictionary(rows.map { ($0.personID, $0) }, uniquingKeysWith: { a, _ in a })
        rollup = (ids, result)
        return result
    }

    /// The ordered people array for the People tab, preserving ranking.
    func peopleOrdered(_ projects: [KanbanProject], key: Key, calendar: Calendar) -> [KanbanMetrics.PersonRow] {
        reset(for: key)
        let ids = projects.map(\.id)
        if let orderedPeople, orderedPeople.projects == ids { return orderedPeople.array }
        let array = KanbanMetrics.peopleRollup(projects.map { snapshot(of: $0, key: key, calendar: calendar) })
        self.orderedPeople = (ids, array)
        return array
    }

    /// CFD (cumulative flow) for a board, optionally constrained to `days`.
    func flow(of project: KanbanProject, key: Key, calendar: Calendar, days: Int = 90) -> [KanbanReplay.Day] {
        reset(for: key)
        let snapshot = self.snapshot(of: project, key: key, calendar: calendar)
        let activities = self.activities(of: project, key: key)
        if var cached = flows[project.id] {
            if let found = cached.first(where: { $0.days == days }) { return found.result }
            let result = KanbanReplay.cfd(snapshot, activities: activities, days: days)
            cached.append((days, result))
            flows[project.id] = cached
            return result
        }
        let result = KanbanReplay.cfd(snapshot, activities: activities, days: days)
        flows[project.id] = [(days, result)]
        return result
    }

    /// Throughput for a board, optionally constrained to `weeks`.
    func throughput(of project: KanbanProject, key: Key, calendar: Calendar, weeks: Int = 12) -> [KanbanReplay.Week] {
        reset(for: key)
        let snapshot = self.snapshot(of: project, key: key, calendar: calendar)
        let activities = self.activities(of: project, key: key)
        if var cached = throughputs[project.id] {
            if let found = cached.first(where: { $0.weeks == weeks }) { return found.result }
            let result = KanbanReplay.throughput(snapshot, activities: activities, weeks: weeks)
            cached.append((weeks, result))
            throughputs[project.id] = cached
            return result
        }
        let result = KanbanReplay.throughput(snapshot, activities: activities, weeks: weeks)
        throughputs[project.id] = [(weeks, result)]
        return result
    }

    /// Aging (age of work in progress) for a board.
    func aging(of project: KanbanProject, key: Key, calendar: Calendar) -> [KanbanReplay.Aging] {
        reset(for: key)
        if let cached = agingCaches[project.id] { return cached }
        let snapshot = self.snapshot(of: project, key: key, calendar: calendar)
        let activities = self.activities(of: project, key: key)
        let result = KanbanReplay.agingWIP(snapshot, activities: activities)
        agingCaches[project.id] = result
        return result
    }

    /// Summary for a board.
    func summary(of project: KanbanProject, key: Key, calendar: Calendar) -> KanbanMetrics.ProjectSummary {
        reset(for: key)
        if let cached = summaries[project.id] { return cached }
        let snapshot = self.snapshot(of: project, key: key, calendar: calendar)
        let result = KanbanMetrics.summary(snapshot)
        summaries[project.id] = result
        return result
    }

    /// Load rows for a board.
    func loadRows(of project: KanbanProject, key: Key, calendar: Calendar) -> [KanbanMetrics.LoadRow] {
        reset(for: key)
        if let cached = loadRowsCaches[project.id] { return cached }
        let snapshot = self.snapshot(of: project, key: key, calendar: calendar)
        let result = KanbanMetrics.loadVsCapacity(snapshot)
        loadRowsCaches[project.id] = result
        return result
    }

    private func reset(for key: Key) {
        guard self.key != key else { return }
        self.key = key
        snapshots = [:]
        rollup = nil
        orderedPeople = nil
        logs = [:]
        flows = [:]
        throughputs = [:]
        agingCaches = [:]
        summaries = [:]
        loadRowsCaches = [:]
    }
}

extension AppState {
    /// The cache key for now; reading it makes a view redraw when the store or the day changes.
    func kanbanMetricsKey(weekStartsMonday: Bool) -> KanbanMetricsCache.Key {
        .init(generation: kanbanGeneration.value, clock: kanbanClock, weekStartsMonday: weekStartsMonday)
    }
}
