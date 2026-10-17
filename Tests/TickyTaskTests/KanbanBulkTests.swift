import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Bulk actions from the List view and multi-selection (design 01 §2.2, §5): one grouped
/// Change Log entry each, undone as one.
@MainActor
@Suite("Kanban bulk actions", .serialized)
struct KanbanBulkTests {
    private func board() throws -> (KanbanService, KanbanProject, [KanbanTask]) {
        let history = KanbanHistory()
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()), history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let cards = try ["A", "B", "C"].map { try service.createTask(in: project, title: $0) }
        history.clear()
        return (service, project, cards)
    }

    @Test("A bulk edit is one entry, and ⌘Z undoes it for every card")
    func editMany() throws {
        let (s, project, cards) = try board()
        let entries = project.activities.count
        try s.editMany(cards, [.priority: .int(2), .isCritical: .bool(true)])
        #expect(cards.allSatisfy { $0.priority == 2 && $0.isCritical })
        #expect(project.activities.count == entries + 1)
        try s.undo(in: project)
        #expect(cards.allSatisfy { $0.priority == 0 && !$0.isCritical })
        #expect(throws: KanbanServiceError.self) { try s.editMany(cards, [.priority: .int(5)]) }
    }

    @Test("A bulk label is one entry and keeps each card's other labels")
    func setLabel() throws {
        let (s, project, cards) = try board()
        let labels = project.labels.sorted { $0.sortIndex < $1.sortIndex }
        try s.setLabels(cards[0], [labels[1]])
        try s.setLabel(labels[0], on: cards, true)
        #expect(cards.allSatisfy { $0.labels.contains { $0.id == labels[0].id } })
        #expect(cards[0].labels.count == 2)
        try s.undo(in: project)
        #expect(cards[0].labels.map(\.id) == [labels[1].id] && cards[1].labels.isEmpty)
    }

    @Test("Bulk archive and restore are one entry each; a restore fits the board as it is now")
    func archiveMany() throws {
        let (s, project, cards) = try board()
        let mia = try s.addMembership(try s.createPerson(name: "Mia", initials: "MI"), to: project)
        try s.move(.cards([cards[1].id], to: .rowHeader(.resource(mia.id))), in: project)
        let entries = project.activities.count
        try s.setArchived(cards, true)
        #expect(cards.allSatisfy { $0.archivedAt != nil } && project.activities.count == entries + 1)
        try s.archiveMembership(mia)
        try s.setArchived(cards, false)
        #expect(cards.allSatisfy { $0.archivedAt == nil })
        #expect(cards[1].resource == nil, "Mia left the board meanwhile")
        let sorted = project.tasks.filter { $0.resource == nil }.map(\.sortIndex)
        #expect(Set(sorted).count == sorted.count, "distinct positions in the Unassigned cell")
    }

    @Test("Bulk actions refuse cards from different boards")
    func oneBoardOnly() throws {
        let (s, _, cards) = try board()
        let other = try s.createProject(name: "Data", key: "DATA")
        let foreign = try s.createTask(in: other, title: "F")
        #expect(throws: KanbanServiceError.self) { try s.editMany(cards + [foreign], [.priority: .int(1)]) }
        #expect(throws: KanbanServiceError.self) { try s.setArchived(cards + [foreign], true) }
    }

    @Test("A bulk restore never puts two cards at one position in Unassigned")
    func restoreReservesPositions() throws {
        let (s, project, cards) = try board()
        let mia = try s.addMembership(try s.createPerson(name: "Mia", initials: "MI"), to: project)
        try s.move(.cards([cards[1].id], to: .rowHeader(.resource(mia.id))), in: project)
        try s.setArchived([cards[0], cards[1], cards[2]], true)
        try s.archiveMembership(mia)
        try s.setArchived([cards[0], cards[1], cards[2]], false)
        let unassigned = project.tasks.filter { $0.resource == nil && $0.column?.id == project.orderedColumns[0].id }
        #expect(unassigned.count == 3)
        #expect(Set(unassigned.map(\.sortIndex)).count == 3, "\(unassigned.map(\.sortIndex))")
    }

    @Test("Arranging a cell is one entry and undoable")
    func arrange() throws {
        let (s, project, cards) = try board()
        try s.arrange([cards[2], cards[0], cards[1]])
        #expect([cards[2], cards[0], cards[1]].map(\.sortIndex) == [0, 1, 2])
        try s.undo(in: project)
        #expect(cards.map(\.sortIndex) == [0, 1, 2])
        let mia = try s.addMembership(try s.createPerson(name: "Mia", initials: "MI"), to: project)
        try s.move(.cards([cards[0].id], to: .rowHeader(.resource(mia.id))), in: project)
        #expect(throws: KanbanServiceError.self, "one cell only") { try s.arrange([cards[0], cards[1]]) }
    }

    @Test("Arranging the visible cards of a filtered cell keeps the hidden ones in place, with no shared positions")
    func arrangeKeepsHiddenSiblings() throws {
        let (s, _, cards) = try board()   // A=0, B=1, C=2; A is hidden by a filter
        try s.arrange([cards[2], cards[1]])
        #expect(cards.map(\.title).sorted { a, b in
            cards.first { $0.title == a }!.sortIndex < cards.first { $0.title == b }!.sortIndex
        } == ["A", "C", "B"])
        #expect(Set(cards.map(\.sortIndex)) == [0, 1, 2])
    }

    @Test("Cards restored in place go to the end of their cell when their positions were reused")
    func restoreInPlaceAppends() throws {
        let (s, project, cards) = try board()   // A=0, B=1, C=2
        try s.setArchived([cards[0], cards[1]], true)
        let e = try s.createTask(in: project, title: "E")
        try s.setArchived([cards[0], cards[1]], false)
        let live = project.tasks.filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
        #expect(Set(live.map(\.sortIndex)).count == live.count, "\(live.map { "\($0.title)=\($0.sortIndex)" })")
        #expect(live.map(\.title).suffix(2) == ["A", "B"], "after C and E, in their old order")
        _ = e
        try s.undo(in: project)
        #expect(cards[0].archivedAt != nil && cards[1].archivedAt != nil)
    }

    @Test("Reverting an old reorder that would put a card on a reused position is refused")
    func revertReorderCollision() throws {
        let (s, project, cards) = try board()   // A=0, B=1, C=2
        try s.setArchived([cards[0]], true)
        try s.arrange([cards[2], cards[1]])       // C=0, B=1
        let arrange = try #require(project.activities.max { $0.seq < $1.seq })
        let d = try s.createTask(in: project, title: "D")   // D=2
        #expect(throws: KanbanServiceError.self, "C back to 2 would share D's position") { try s.revert(arrange) }
        #expect(cards[2].sortIndex == 0 && d.sortIndex == 2)
    }

    @Test("Show Archived adds archived cards but not archived memberships' rows")
    func snapshotRowsStayActive() throws {
        let (s, project, cards) = try board()
        let mia = try s.addMembership(try s.createPerson(name: "Mia", initials: "MI"), to: project)
        try s.move(.cards([cards[0].id], to: .rowHeader(.resource(mia.id))), in: project)
        try s.setArchived([cards[0]], true)
        try s.archiveMembership(mia)
        let snapshot = BoardSnapshot.make(project: project, includeArchived: true, includeArchivedRows: false)
        #expect(snapshot.rows.map(\.key) == [.unassigned])
        #expect(snapshot.cards.contains { $0.id == cards[0].id && $0.archived && $0.row == .unassigned })
        #expect(BoardSnapshot.make(project: project, includeArchived: true).rows.count == 2, "the default still includes them")
    }
}
