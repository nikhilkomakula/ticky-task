import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Finished work that piles up: a Done cell shows its five most recent cards, and Archive
/// done cards… archives a board's finished cards in one entry.
@MainActor
@Suite("Kanban done cards", .serialized)
struct KanbanDoneCompactionTests {
    private let now = Date()

    private func board() throws -> (KanbanService, KanbanHistory, KanbanProject, ModelContext) {
        let history = KanbanHistory()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        history.clear()
        return (service, history, project, context)
    }

    private func done(_ project: KanbanProject) throws -> KanbanColumn {
        try #require(project.orderedColumns.first { $0.kind == .done })
    }

    /// A card in `column`, finished `daysAgo` days ago (nil: no completion date).
    private func card(_ s: KanbanService, _ project: KanbanProject, _ title: String, in column: KanbanColumn,
                      finished daysAgo: Int?) throws -> KanbanTask {
        let task = try s.createTask(in: project, title: title)
        _ = try s.move(.cards([task.id], to: .cell(columnID: column.id, row: .unassigned, beforeCardID: nil)), in: project)
        task.completedAt = daysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) }
        try s.context.save()
        return task
    }

    @Test("A Done cell keeps its five newest cards and every undated one, in the cell's order")
    func recentFive() throws {
        let (s, _, project, _) = try board()
        let column = try done(project)
        let cell = try (0..<8).map { try card(s, project, "Done \($0)", in: column, finished: $0 + 1) }
            + [try card(s, project, "Undated", in: column, finished: nil)]
        let shown = KanbanDoneCards.recent(cell)
        #expect(shown.map(\.title) == ["Done 0", "Done 1", "Done 2", "Done 3", "Done 4", "Undated"])
        #expect(KanbanDoneCards.recent(Array(cell.prefix(5))).count == 5, "five or fewer: nothing hidden")
    }

    @Test("Cards finished at the same moment are chosen the same way every time")
    func ties() throws {
        let (s, _, project, _) = try board()
        let column = try done(project)
        let cell = try (0..<7).map { try card(s, project, "Same \($0)", in: column, finished: 2) }
        let expected = Set(cell.sorted { $0.id.uuidString > $1.id.uuidString }.prefix(5).map(\.id))
        #expect(Set(KanbanDoneCards.recent(cell).map(\.id)) == expected)
        #expect(Set(KanbanDoneCards.recent(cell.reversed()).map(\.id)) == expected, "whatever order the cell is in")
    }

    @Test("Showing all, a filter or Show Archived turns shortening off; older states shorten")
    func compactsDone() {
        #expect(KanbanBoardState.decode(Data(#"{"view":"board","sort":"manual"}"#.utf8)).compactsDone, "older states: on")
        #expect(KanbanBoardState.decode(Data(#"{"showAllDone":"yes"}"#.utf8)).showAllDone == false, "a bad value: off")
        var state = KanbanBoardState()
        state.showAllDone = true
        #expect(KanbanBoardState.decode(state.encoded()).showAllDone && !state.compactsDone)
        var archived = KanbanBoardState(); archived.showArchived = true
        var filtered = KanbanBoardState(); filtered.filter.text = "API"
        #expect(!archived.compactsDone && !filtered.compactsDone)
    }

    @Test("Archivable cards: every Done column and person, by the auto-archive cutoff; undated only for All")
    func archivable() throws {
        let (s, _, project, _) = try board()
        let column = try done(project)
        let second = try s.addColumn(to: project, name: "Shipped", at: project.orderedColumns.count)
        try s.editColumn(second, kind: .done)
        let ravi = try s.addMembership(try s.createPerson(name: "Ravi", initials: "RV"), to: project)
        let old = try card(s, project, "Old", in: column, finished: 40)
        let shipped = try card(s, project, "Shipped long ago", in: second, finished: 31)
        _ = try s.move(.cards([shipped.id], to: .cell(columnID: second.id, row: .resource(ravi.id), beforeCardID: nil)), in: project)
        shipped.completedAt = now.addingTimeInterval(-31 * 86_400)
        try s.context.save()
        let recent = try card(s, project, "Recent", in: column, finished: 29)
        let undated = try card(s, project, "Undated", in: column, finished: nil)
        let open = try s.createTask(in: project, title: "Open")
        let older = Set(KanbanDoneCards.archivable(in: project, finishedMoreThan: 30, now: now).map(\.id))
        #expect(older == [old.id, shipped.id])
        let all = Set(KanbanDoneCards.archivable(in: project).map(\.id))
        #expect(all == [old.id, shipped.id, recent.id, undated.id] && !all.contains(open.id))
    }

    @Test("Archiving them is one Change Log entry, and undo brings them all back")
    func archiveAndUndo() throws {
        let (s, history, project, context) = try board()
        let column = try done(project)
        let cards = try (0..<3).map { try card(s, project, "Done \($0)", in: column, finished: 60) }
        let id = project.id
        let entries = { try context.fetchCount(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id })) }
        let before = try entries()
        try s.setArchived(KanbanDoneCards.archivable(in: project, finishedMoreThan: 30, now: now), true)
        let archivedAll = cards.allSatisfy { $0.archivedAt != nil }
        let after = try entries()
        #expect(archivedAll && after == before + 1)
        #expect(KanbanDoneCards.archivable(in: project).isEmpty, "nothing left to archive")
        #expect(history.canUndo(project.id))
        try s.undo(in: project)
        let restoredAll = cards.allSatisfy { $0.archivedAt == nil }
        #expect(restoredAll)
    }
}
