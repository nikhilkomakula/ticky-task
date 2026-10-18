import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// A card's optional complexity (Low, Medium, High): edited and undone like any field, and
/// carried by new cards, Duplicate, delete-undo, backups, board files and CSV.
@MainActor
@Suite("Kanban card complexity", .serialized)
struct KanbanComplexityTests {
    private func board() throws -> (KanbanService, KanbanProject, ModelContext) {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: KanbanHistory())
        return (service, try service.createProject(name: "Platform", key: "PLAT"), context)
    }

    @Test("Set, change and clear it, each undoable; anything but a level is refused")
    func edits() throws {
        let (s, project, _) = try board()
        let task = try s.createTask(in: project, title: "Build API")
        #expect(task.complexity == nil, "not set by default")
        try s.edit(task, [.complexity: .int(KanbanComplexity.high.rawValue)])
        #expect(task.complexity == 3)
        try s.edit(task, [.complexity: nil])
        #expect(task.complexity == nil)
        try s.undo(in: project)
        #expect(task.complexity == 3, "undo brings the level back")
        #expect(throws: KanbanServiceError.self) { try s.edit(task, [.complexity: .int(4)]) }
        #expect(throws: KanbanServiceError.self) { try s.edit(task, [.complexity: .string("High")]) }
        #expect(task.complexity == 3)
        try s.editMany([task, try s.createTask(in: project, title: "Docs")], [.complexity: .int(1)])
        #expect(project.tasks.allSatisfy { $0.complexity == 1 })
    }

    @Test("New cards, copies and a deleted card brought back keep it")
    func carried() throws {
        let (s, project, _) = try board()
        var draft = KanbanCardDraft()
        draft.title = "Build API"
        draft.complexity = KanbanComplexity.medium.rawValue
        let task = try s.createCard(draft, in: project)
        #expect(task.complexity == 2)
        #expect(try s.duplicateCard(task).complexity == 2)
        var bad = KanbanCardDraft()
        bad.title = "Bad"
        bad.complexity = 9
        #expect(throws: KanbanServiceError.self) { try s.createCard(bad, in: project) }
        let id = task.id
        try s.deleteTask(task)
        try s.undo(in: project)
        #expect(project.tasks.first { $0.id == id }?.complexity == 2)
    }

    @Test("Backups and board files carry it; an older file without it reads as not set; CSV shows it")
    func files() throws {
        let (s, project, context) = try board()
        let task = try s.createTask(in: project, title: "Build API")
        try s.edit(task, [.complexity: .int(3)])
        let dto = KanbanTaskDTO(task)
        let data = try JSONEncoder().encode(dto)
        #expect(try JSONDecoder().decode(KanbanTaskDTO.self, from: data).complexity == 3)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "complexity")
        let older = try JSONDecoder().decode(KanbanTaskDTO.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(older.complexity == nil)

        let file = try KanbanBoardTransfer.export([project], context: context)
        let other = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let imported = try KanbanBoardTransfer.apply(try KanbanBoardTransfer.plan(file, context: other), fileName: "f", context: other)
        #expect(imported.first?.tasks.first?.complexity == 3)

        let lines = KanbanBoardTransfer.csv(project).components(separatedBy: "\r\n")
        #expect(lines.first?.hasSuffix(",Complexity") == true && lines[1].hasSuffix(",High"))
    }
}
