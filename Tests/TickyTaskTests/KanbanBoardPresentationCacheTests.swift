import Testing
import Foundation
import SwiftData
@testable import TickyTask

@MainActor
@Suite("Kanban board presentation cache", .serialized)
struct KanbanBoardPresentationCacheTests {
    private let today = Date(timeIntervalSince1970: 1_791_936_000) // 14 Oct 2026, UTC.

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private var key: KanbanMetricsCache.Key {
        .init(generation: 1, clock: "day1", weekStartsMonday: true)
    }

    private func board() throws -> (KanbanService, KanbanProject) {
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()))
        return (service, try service.createProject(name: "Platform", key: "PLAT"))
    }

    private func cache() -> KanbanBoardPresentationCache {
        let cache = KanbanBoardPresentationCache()
        cache.now = { today }
        return cache
    }

    @Test("Unchanged inputs reuse the presentation; a data revision sees added cards")
    func generationAndProject() throws {
        let (service, project) = try board()
        let cache = cache(), state = KanbanBoardState()
        _ = try service.createTask(in: project, title: "A")
        let first = cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: [])
        _ = try service.createTask(in: project, title: "B")
        let reused = cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: [])
        #expect(first === reused)
        #expect(reused.snapshot.cards.count == 1)
        var revision = key
        revision.generation += 1
        let revised = cache.presentation(of: project, key: revision, state: state, calendar: calendar, expandedDone: [])
        #expect(revised !== first && revised.snapshot.cards.count == 2)
        let other = try service.createProject(name: "Other", key: "OTHER")
        let switched = cache.presentation(of: other, key: revision, state: state, calendar: calendar, expandedDone: [])
        #expect(switched !== revised && switched.snapshot.projectID == other.id && switched.tasks.isEmpty)
    }

    @Test("Filters, sort and Show Archived rebuild the same grouping used by the board")
    func stateChanges() throws {
        let (service, project) = try board()
        let cache = cache()
        let z = try service.createTask(in: project, title: "Keep Z")
        let a = try service.createTask(in: project, title: "Keep A")
        _ = try service.createTask(in: project, title: "Other")
        let archived = try service.createTask(in: project, title: "Keep archived")
        archived.archivedAt = today
        let cell = KanbanBoardPresentationCache.CellKey(column: try #require(a.column?.id), row: .unassigned)
        var state = KanbanBoardState()
        let initial = cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: [])
        #expect(initial.cells[cell]?.count == 3 && initial.tasks.count == 4)
        state.filter.text = "Keep"
        state.sort = .title
        let filtered = cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: [])
        #expect(filtered !== initial)
        let filteredIDs: [UUID] = filtered.cells[cell]?.map(\.id) ?? []
        #expect(filteredIDs == [a.id, z.id])
        state.showArchived = true
        let all = cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: [])
        #expect(all !== filtered)
        let allIDs: Set<UUID> = Set(all.cells[cell]?.map(\.id) ?? [])
        #expect(allIDs == [a.id, z.id, archived.id])
        let columnIDs: [UUID] = all.columns.map(\.id), expected: [UUID] = project.orderedColumns.map(\.id)
        #expect(columnIDs == expected)
    }

    @Test("Done expansion updates shown cards, tucked ids and column totals together")
    func doneExpansion() throws {
        let (service, project) = try board()
        let cache = cache()
        let done = try #require(project.orderedColumns.first { $0.kind == .done })
        let cards = try (0..<8).map { index in
            let card = try service.createTask(in: project, title: "Done \(index)", column: done)
            card.completedAt = today.addingTimeInterval(-Double(index) * 86_400)
            return card
        }
        let cell = KanbanBoardPresentationCache.CellKey(column: done.id, row: .unassigned)
        let state = KanbanBoardState()
        let compact = cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: [])
        #expect(compact.shown[cell]?.map(\.id) == Array(cards.prefix(5)).map(\.id))
        #expect(compact.doneHidden[cell] == 3 && compact.hiddenByColumn[done.id] == 3)
        #expect(compact.tucked == Set(cards.suffix(3).map(\.id)))
        let expanded = cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: [cell])
        #expect(expanded !== compact && expanded.shown[cell]?.count == 8)
        #expect(expanded.doneHidden[cell] == 3 && expanded.hiddenByColumn.isEmpty && expanded.tucked.isEmpty)
        var showAll = state
        showAll.showAllDone = true
        let all = cache.presentation(of: project, key: key, state: showAll, calendar: calendar, expandedDone: [])
        #expect(all.shown[cell]?.count == 8 && all.doneHidden.isEmpty && all.tucked.isEmpty)
    }

    @Test("Day, calendar and metrics clock changes invalidate date-sensitive filters")
    func clockAndCalendar() throws {
        let (service, project) = try board()
        let cache = cache()
        _ = try service.createTask(in: project, title: "Due today", dueDate: today)
        var state = KanbanBoardState()
        state.filter.due = .overdue
        let first = cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: [])
        #expect(first.cells.isEmpty)
        cache.now = { today.addingTimeInterval(3_600) }
        #expect(cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: []) === first)
        cache.now = { today.addingTimeInterval(86_400) }
        let tomorrow = cache.presentation(of: project, key: key, state: state, calendar: calendar, expandedDone: [])
        #expect(tomorrow !== first && tomorrow.cells.values.reduce(0) { $0 + $1.count } == 1)
        var sunday = calendar
        sunday.firstWeekday = 1
        let calendarChanged = cache.presentation(of: project, key: key, state: state, calendar: sunday, expandedDone: [])
        #expect(calendarChanged !== tomorrow)
        var clock = key
        clock.clock = "day2"
        let clockChanged = cache.presentation(of: project, key: clock, state: state, calendar: sunday, expandedDone: [])
        #expect(clockChanged !== calendarChanged)
        clock.weekStartsMonday = false
        #expect(cache.presentation(of: project, key: clock, state: state, calendar: sunday, expandedDone: []) !== clockChanged)
    }
}
