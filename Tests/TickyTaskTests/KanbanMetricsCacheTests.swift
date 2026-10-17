import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// The metrics cache: caching derived results (CFD, throughput, aging, summary, load rows,
/// ordered people) keyed by generation, clock, and weekStartsMonday, with per-project granularity.
@MainActor
@Suite("Kanban metrics cache", .serialized)
struct KanbanMetricsCacheTests {
    typealias F = MetricsFixture
    typealias R = KanbanReplay

    @MainActor
    final class Board {
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()))
        let project: KanbanProject
        init() throws { project = try service.createProject(name: "Platform", key: "PLAT") }
        var todo: KanbanColumn { project.orderedColumns[0] }
        var doing: KanbanColumn { project.orderedColumns[1] }
        var done: KanbanColumn { project.orderedColumns.last! }

        func at(_ date: Date) { entries().max { $0.seq < $1.seq }?.at = date }

        func entries() -> [KanbanActivity] {
            let id = project.id
            return (try? project.modelContext?.fetch(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id }))) ?? []
        }

        func card(_ title: String, in column: KanbanColumn? = nil, on date: Date) throws -> KanbanTask {
            let task = try service.createTask(in: project, title: title, column: column)
            at(date)
            task.createdAt = date
            return task
        }

        func move(_ task: KanbanTask, to column: KanbanColumn, on date: Date) throws {
            try service.move(.cards([task.id], to: .columnHeader(column.id)), in: project)
            at(date)
        }

        func snapshot(hours: Bool = false) -> MetricsSnapshot {
            var s = MetricsSnapshot(project: project, now: F.now, calendar: F.calendar())
            if hours { s.loadMeasure = .hours }
            return s
        }

        var activities: [MetricsActivity] { MetricsActivity.records(of: project) }
    }

    /// The fixture's "now" (Wed 14 Oct 2026), so the results don't depend on the test run's date.
    private func pinnedCache() -> KanbanMetricsCache {
        let cache = KanbanMetricsCache()
        cache.now = { F.now }
        return cache
    }

    private func key(_ generation: Int, _ clock: String = "test") -> KanbanMetricsCache.Key {
        KanbanMetricsCache.Key(generation: generation, clock: clock, weekStartsMonday: true)
    }

    @Test("Under one key the derived results are served from the cache; a new generation recomputes them")
    func cachedUntilTheKeyChanges() throws {
        let cache = pinnedCache(), b = try Board(), calendar = F.calendar()
        _ = try b.card("A", on: F.date(10, 1))
        let flow = cache.flow(of: b.project, key: key(1), calendar: calendar)
        let summary = cache.summary(of: b.project, key: key(1), calendar: calendar)
        let rows = cache.loadRows(of: b.project, key: key(1), calendar: calendar)
        _ = try b.card("B", on: F.date(10, 2))   // the board changes, the key doesn't
        #expect(cache.flow(of: b.project, key: key(1), calendar: calendar) == flow)
        #expect(cache.summary(of: b.project, key: key(1), calendar: calendar) == summary)
        #expect(cache.loadRows(of: b.project, key: key(1), calendar: calendar) == rows)
        #expect(cache.summary(of: b.project, key: key(2), calendar: calendar) != summary, "a new generation sees card B")
        #expect(cache.flow(of: b.project, key: key(2), calendar: calendar) != flow)
    }

    @Test("A clock change recomputes too")
    func clockChangeRecomputes() throws {
        let cache = pinnedCache(), b = try Board(), calendar = F.calendar()
        _ = try b.card("A", on: F.date(10, 1))
        let summary = cache.summary(of: b.project, key: key(1, "day1"), calendar: calendar)
        _ = try b.card("B", on: F.date(10, 2))
        #expect(cache.summary(of: b.project, key: key(1, "day2"), calendar: calendar) != summary)
    }

    @Test("Cached results equal the direct calls on the cache's own snapshot and log")
    func cachedEqualsDirect() throws {
        let cache = pinnedCache(), b = try Board(), calendar = F.calendar()
        let a = try b.card("A", on: F.date(10, 1))
        try b.move(a, to: b.doing, on: F.date(10, 3))
        let k = key(1)
        let s = cache.snapshot(of: b.project, key: k, calendar: calendar)
        let log = cache.activities(of: b.project, key: k)
        #expect(cache.flow(of: b.project, key: k, calendar: calendar) == R.cfd(s, activities: log))
        #expect(cache.throughput(of: b.project, key: k, calendar: calendar, weeks: 12) == R.throughput(s, activities: log, weeks: 12))
        #expect(cache.throughput(of: b.project, key: k, calendar: calendar, weeks: 6) == R.throughput(s, activities: log, weeks: 6),
                "each weeks value is cached on its own")
        #expect(cache.aging(of: b.project, key: k, calendar: calendar) == R.agingWIP(s, activities: log))
        #expect(cache.summary(of: b.project, key: k, calendar: calendar) == KanbanMetrics.summary(s))
        #expect(cache.loadRows(of: b.project, key: k, calendar: calendar) == KanbanMetrics.loadVsCapacity(s))
    }

    @Test("The ordered people match the rollup, in the same order every time")
    func orderedPeople() throws {
        let cache = pinnedCache(), b = try Board(), calendar = F.calendar()
        try b.service.addMembership(try b.service.createPerson(name: "Ravi", initials: "RV"), to: b.project)
        try b.service.addMembership(try b.service.createPerson(name: "Mia", initials: "MI"), to: b.project)
        let ordered = cache.peopleOrdered([b.project], key: key(1), calendar: calendar)
        #expect(ordered.count == 2 && cache.peopleOrdered([b.project], key: key(1), calendar: calendar) == ordered)
        #expect(Set(ordered.map(\.personID)) == Set(cache.people([b.project], key: key(1), calendar: calendar).keys))
    }
}
