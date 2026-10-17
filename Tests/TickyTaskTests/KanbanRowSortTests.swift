import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// A row header's priority sort: sort a person's cards once (their manual order, one undoable
/// entry), or keep the row sorted (view state, no entry).
@MainActor
@Suite("Kanban row priority sort", .serialized)
struct KanbanRowSortTests {
    private func board() throws -> (KanbanService, KanbanHistory, KanbanProject, ModelContext, KanbanResource) {
        let history = KanbanHistory()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let ravi = try service.addMembership(try service.createPerson(name: "Ravi", initials: "RV"), to: project)
        history.clear()
        return (service, history, project, context, ravi)
    }

    private func card(_ s: KanbanService, _ project: KanbanProject, _ title: String, column: Int, row: KanbanRowKey,
                      priority: Int, critical: Bool = false) throws -> KanbanTask {
        let task = try s.createTask(in: project, title: title, column: project.orderedColumns[column], row: row)
        try s.edit(task, [.priority: .int(priority), .isCritical: .bool(critical)])
        return task
    }

    private func titles(_ project: KanbanProject, column: Int, resource: KanbanResource?) -> [String] {
        let id = project.orderedColumns[column].id
        return project.tasks.filter { $0.archivedAt == nil && $0.column?.id == id && $0.resource?.id == resource?.id }
            .sorted { $0.sortIndex < $1.sortIndex }.map(\.title)
    }

    @Test("Sorting a row orders each of its cells Critical, High, Medium, Low (ties keep their order), in one undoable entry")
    func sortOnce() throws {
        let (s, history, project, context, ravi) = try board()
        let row = KanbanRowKey.resource(ravi.id)
        for (title, p) in [("Low A", 0), ("High", 2), ("Low B", 0), ("Medium", 1)] { _ = try card(s, project, title, column: 1, row: row, priority: p) }
        _ = try card(s, project, "Critical low", column: 1, row: row, priority: 0, critical: true)
        _ = try card(s, project, "Later", column: 2, row: row, priority: 0)
        _ = try card(s, project, "Soon", column: 2, row: row, priority: 2)
        _ = try card(s, project, "Other person", column: 1, row: .unassigned, priority: 0)
        _ = try card(s, project, "Other high", column: 1, row: .unassigned, priority: 2)
        history.clear()
        let id = project.id
        let entries = { try context.fetchCount(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id })) }
        let before = try entries()
        #expect(try s.sortRowByPriority(row, in: project))
        #expect(titles(project, column: 1, resource: ravi) == ["Critical low", "High", "Medium", "Low A", "Low B"])
        #expect(titles(project, column: 2, resource: ravi) == ["Soon", "Later"])
        #expect(titles(project, column: 1, resource: nil) == ["Other person", "Other high"], "other rows are untouched")
        let after = try entries()
        #expect(after == before + 1, "one entry for the whole row")
        #expect(try !s.sortRowByPriority(row, in: project), "already in order: nothing to do")
        let again = try entries()
        #expect(again == after, "and no entry")
        try s.undo(in: project)
        #expect(titles(project, column: 1, resource: ravi) == ["Low A", "High", "Low B", "Medium", "Critical low"])
    }

    @Test("Cards a filter hides are sorted too; archived ones keep their place")
    func hiddenAndArchived() throws {
        let (s, _, project, _, ravi) = try board()
        let row = KanbanRowKey.resource(ravi.id)
        let low = try card(s, project, "Low", column: 1, row: row, priority: 0)
        let old = try card(s, project, "Old high", column: 1, row: row, priority: 2)
        _ = try card(s, project, "High", column: 1, row: row, priority: 2)
        try s.setArchived([old], true)
        let oldIndex = old.sortIndex
        try s.sortRowByPriority(row, in: project)
        #expect(titles(project, column: 1, resource: ravi) == ["High", "Low"])
        #expect(old.sortIndex == oldIndex && low.archivedAt == nil)
    }

    @Test("Keep sorted is remembered per row and read tolerantly; a hand reorder turns it and the board Sort to manual")
    func keepSorted() throws {
        let (s, _, project, _, ravi) = try board()
        let row = KanbanRowKey.resource(ravi.id)
        var state = KanbanBoardState()
        state.setKeepsSortedByPriority(row, true)
        state.setKeepsSortedByPriority(row, true)
        #expect(state.prioritySortedRows == [row.storageKey], "once")
        let restored = KanbanBoardState.decode(state.encoded())
        #expect(restored.keepsSortedByPriority(row) && !restored.keepsSortedByPriority(.unassigned))
        let messy = KanbanBoardState.decode(Data(#"{"sort":"title","prioritySortedRows":["unassigned","bogus","unassigned"]}"#.utf8))
        #expect(messy.sort == .title && messy.prioritySortedRows == ["unassigned"], "unknown keys dropped, duplicates merged")
        #expect(KanbanBoardState.decode(Data(#"{"prioritySortedRows":7}"#.utf8)).prioritySortedRows == nil)

        let low = try card(s, project, "Low", column: 1, row: row, priority: 0)
        let high = try card(s, project, "High", column: 1, row: row, priority: 2)
        #expect(restored.sorted([low, high], row: row).map(\.title) == ["High", "Low"], "a kept row shows by priority")
        var titled = KanbanBoardState(); titled.sort = .title
        titled.setKeepsSortedByPriority(row, true)
        #expect(titled.sorted([low, high], row: .unassigned).map(\.title) == ["High", "Low"], "other rows follow the board Sort")
        #expect(titled.sorted([high, low], row: row).map(\.title) == ["High", "Low"], "the row's setting wins over the board Sort")
        titled.becomeManual(in: row)
        #expect(titled.sort == .manual && !titled.keepsSortedByPriority(row))
    }
}
