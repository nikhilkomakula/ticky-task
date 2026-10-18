import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Where the Kanban module opens: Settings › Kanban › Default board, with fallbacks.
@MainActor
@Suite("Kanban default board")
struct KanbanDefaultBoardTests {
    @Test("The chosen board, else the last opened, else the first in the sidebar (pinned first); All projects when chosen or when there are no boards")
    func opens() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context)
        #expect(KanbanDefaultBoard.item([], choice: nil, lastOpened: nil) == .allProjects, "no boards")
        let first = try s.createProject(name: "First", key: "ONE")
        let second = try s.createProject(name: "Second", key: "TWO")
        let third = try s.createProject(name: "Third", key: "THREE")
        let projects = [third, first, second]   // any order: the sidebar's is by position
        #expect(KanbanDefaultBoard.item(projects, choice: nil, lastOpened: nil) == .project(first.id))
        #expect(KanbanDefaultBoard.item(projects, choice: "", lastOpened: second.id.uuidString) == .project(second.id), "the last opened")
        #expect(KanbanDefaultBoard.item(projects, choice: third.id.uuidString, lastOpened: second.id.uuidString) == .project(third.id), "the chosen wins")
        #expect(KanbanDefaultBoard.item(projects, choice: KanbanDefaultBoard.allProjects, lastOpened: second.id.uuidString) == .allProjects)
        #expect(KanbanDefaultBoard.item(projects, choice: UUID().uuidString, lastOpened: "junk") == .project(first.id), "a deleted choice falls back")
        try s.editProject(third, [.isPinned: .bool(true)])
        #expect(KanbanDefaultBoard.item(projects, choice: nil, lastOpened: nil) == .project(third.id), "pinned boards come first")
        try s.setProjectArchived(second, true)
        #expect(KanbanDefaultBoard.item(projects, choice: second.id.uuidString, lastOpened: second.id.uuidString) == .project(third.id),
                "an archived board isn't opened")
    }
}
