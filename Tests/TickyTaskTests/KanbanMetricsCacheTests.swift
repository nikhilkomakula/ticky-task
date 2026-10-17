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

    @Test("Same key returns cached CFD results")
    func cacheCFDOnSameKey() throws {
        let cache = KanbanMetricsCache()
        let b = try Board()
        let _ = try b.card("A", on: F.date(10, 1))
        let calendar = F.calendar()
        let key = KanbanMetricsCache.Key(generation: 1, clock: "test", weekStartsMonday: true)

        let flow1 = cache.flow(of: b.project, key: key, calendar: calendar)
        let flow2 = cache.flow(of: b.project, key: key, calendar: calendar)
        #expect(flow1 === flow2, "Same key returns the same cached object")
    }

    @Test("Generation change recomputes CFD")
    func cfdRecomputesOnGenerationChange() throws {
        let cache = KanbanMetricsCache()
        let b = try Board()
        let _ = try b.card("A", on: F.date(10, 1))
        let calendar = F.calendar()
        let key1 = KanbanMetricsCache.Key(generation: 1, clock: "test", weekStartsMonday: true)
        let key2 = KanbanMetricsCache.Key(generation: 2, clock: "test", weekStartsMonday: true)

        let flow1 = cache.flow(of: b.project, key: key1, calendar: calendar)
        let flow2 = cache.flow(of: b.project, key: key2, calendar: calendar)
        #expect(flow1 !== flow2, "Different generation clears cache and recomputes")
    }

    @Test("CFD cache result equals direct call")
    func cfdCacheEqualsDirectCall() throws {
        let cache = KanbanMetricsCache()
        let b = try Board()
        let _ = try b.card("A", on: F.date(10, 1))
        let calendar = F.calendar()
        let key = KanbanMetricsCache.Key(generation: 1, clock: "test", weekStartsMonday: true)
        let snapshot = b.snapshot()
        let activities = b.activities

        let cached = cache.flow(of: b.project, key: key, calendar: calendar)
        let direct = R.cfd(snapshot, activities: activities)
        #expect(cached == direct, "Cached result matches direct computation")
    }

    @Test("Throughput cached separately by weeks parameter")
    func throughputCachedByWeeks() throws {
        let cache = KanbanMetricsCache()
        let b = try Board()
        let _ = try b.card("A", on: F.date(10, 1))
        let calendar = F.calendar()
        let key = KanbanMetricsCache.Key(generation: 1, clock: "test", weekStartsMonday: true)

        let throughput12 = cache.throughput(of: b.project, key: key, calendar: calendar, weeks: 12)
        let throughput6 = cache.throughput(of: b.project, key: key, calendar: calendar, weeks: 6)
        #expect(throughput12 !== throughput6, "Different weeks parameters compute separately")
        let throughput12Again = cache.throughput(of: b.project, key: key, calendar: calendar, weeks: 12)
        #expect(throughput12 === throughput12Again, "Same weeks returns cached result")
    }

    @Test("Summary cache result equals direct call")
    func summaryCacheEqualsDirectCall() throws {
        let cache = KanbanMetricsCache()
        let b = try Board()
        let _ = try b.card("A", on: F.date(10, 1))
        let calendar = F.calendar()
        let key = KanbanMetricsCache.Key(generation: 1, clock: "test", weekStartsMonday: true)
        let snapshot = b.snapshot()

        let cached = cache.summary(of: b.project, key: key, calendar: calendar)
        let direct = KanbanMetrics.summary(snapshot)
        #expect(cached == direct, "Cached summary matches direct computation")
    }

    @Test("Aging cache result equals direct call")
    func agingCacheEqualsDirectCall() throws {
        let cache = KanbanMetricsCache()
        let b = try Board()
        let _ = try b.card("A", on: F.date(10, 1))
        let calendar = F.calendar()
        let key = KanbanMetricsCache.Key(generation: 1, clock: "test", weekStartsMonday: true)
        let snapshot = b.snapshot()
        let activities = b.activities

        let cached = cache.aging(of: b.project, key: key, calendar: calendar)
        let direct = R.agingWIP(snapshot, activities: activities)
        #expect(cached == direct, "Cached aging matches direct computation")
    }

    @Test("Load rows cache result equals direct call")
    func loadRowsCacheEqualsDirectCall() throws {
        let cache = KanbanMetricsCache()
        let b = try Board()
        let _ = try b.card("A", on: F.date(10, 1))
        let calendar = F.calendar()
        let key = KanbanMetricsCache.Key(generation: 1, clock: "test", weekStartsMonday: true)
        let snapshot = b.snapshot()

        let cached = cache.loadRows(of: b.project, key: key, calendar: calendar)
        let direct = KanbanMetrics.loadVsCapacity(snapshot)
        #expect(cached == direct, "Cached load rows match direct computation")
    }

    @Test("Ordered people array preserves ranking across calls")
    func orderedPeoplePreservesRanking() throws {
        let cache = KanbanMetricsCache()
        let b = try Board()
        let _ = try b.card("A", on: F.date(10, 1))
        let calendar = F.calendar()
        let key = KanbanMetricsCache.Key(generation: 1, clock: "test", weekStartsMonday: true)

        let people1 = cache.peopleOrdered([b.project], key: key, calendar: calendar)
        let people2 = cache.peopleOrdered([b.project], key: key, calendar: calendar)
        #expect(people1 === people2, "Same key returns the same cached ordered people array")
    }

    @Test("Clock change recomputes all caches")
    func clockChangeInvalidatesAll() throws {
        let cache = KanbanMetricsCache()
        let b = try Board()
        let _ = try b.card("A", on: F.date(10, 1))
        let calendar = F.calendar()
        let key1 = KanbanMetricsCache.Key(generation: 1, clock: "clock1", weekStartsMonday: true)
        let key2 = KanbanMetricsCache.Key(generation: 1, clock: "clock2", weekStartsMonday: true)

        let flow1 = cache.flow(of: b.project, key: key1, calendar: calendar)
        let summary1 = cache.summary(of: b.project, key: key1, calendar: calendar)
        let aging1 = cache.aging(of: b.project, key: key1, calendar: calendar)

        let flow2 = cache.flow(of: b.project, key: key2, calendar: calendar)
        let summary2 = cache.summary(of: b.project, key: key2, calendar: calendar)
        let aging2 = cache.aging(of: b.project, key: key2, calendar: calendar)

        #expect(flow1 !== flow2, "Clock change recomputes CFD")
        #expect(summary1 !== summary2, "Clock change recomputes summary")
        #expect(aging1 !== aging2, "Clock change recomputes aging")
    }
}
