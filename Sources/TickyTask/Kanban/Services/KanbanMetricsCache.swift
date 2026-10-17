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
    private var logs: [UUID: [MetricsActivity]] = [:]

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

    private func reset(for key: Key) {
        guard self.key != key else { return }
        self.key = key
        snapshots = [:]
        rollup = nil
        logs = [:]
    }
}

extension AppState {
    /// The cache key for now; reading it makes a view redraw when the store or the day changes.
    func kanbanMetricsKey(weekStartsMonday: Bool) -> KanbanMetricsCache.Key {
        .init(generation: kanbanGeneration.value, clock: kanbanClock, weekStartsMonday: weekStartsMonday)
    }
}
