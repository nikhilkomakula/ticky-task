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
}
