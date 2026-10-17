import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Card edits behind the editor (design 01 §5): every value checked before anything
/// changes, step renames recorded and undoable.
@MainActor
@Suite("Kanban editor", .serialized)
struct KanbanEditorTests {
    private func board() throws -> (KanbanService, KanbanHistory, KanbanProject, KanbanTask) {
        let history = KanbanHistory()
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()), history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let card = try service.createTask(in: project, title: "Card")
        history.clear()
        return (service, history, project, card)
    }

    @Test("Invalid card values are refused before anything changes")
    func editValidation() throws {
        let (s, history, project, card) = try board()
        let entries = project.activities.count
        for values: [KanbanService.TaskField: KanbanValue?] in [
            [.title: .string("  ")], [.priority: .int(3)], [.estimateHours: .double(-1)], [.estimateHours: .double(.nan)],
            [.jiraURL: .string("PLAT-1")], [.jiraURL: .string("https://")], [.isBlocked: .string("yes")], [.notes: nil],
            [.title: .string("Renamed"), .estimateHours: .double(-2)],
        ] {
            #expect(throws: KanbanServiceError.self, "\(values)") { try s.edit(card, values) }
        }
        #expect(card.title == "Card" && card.estimateHours == nil && project.activities.count == entries && !history.canUndo(project.id))
        try s.edit(card, [.jiraURL: .string("https://jira.example.com/browse/PLAT-7"), .estimateHours: .double(0), .priority: .int(2)])
        #expect(card.jiraKey == "PLAT-7" && card.estimateHours == 0 && card.priority == 2)
    }

    @Test("A step rename is recorded and undoable; a blank one is refused")
    func renameStep() throws {
        let (s, _, project, card) = try board()
        let step = try s.addSubtask(to: card, title: "Draft")
        try s.renameSubtask(step, "  Final  ")
        #expect(step.title == "Final")
        #expect(throws: KanbanServiceError.self) { try s.renameSubtask(step, " ") }
        try s.undo(in: project)
        #expect(step.title == "Draft")
        try s.redo(in: project)
        #expect(step.title == "Final")
    }

    @Test("The editor's pre-save checks refuse what the operations would, without changing anything")
    func preSaveChecks() throws {
        let (s, _, project, card) = try board()
        let doing = project.orderedColumns[1]
        project.wipPolicy = .block
        try s.editColumn(doing, wipLimit: .some(1))
        _ = try s.createTask(in: project, title: "Busy", column: doing)
        let entries = project.activities.count
        #expect(throws: KanbanServiceError.wipBlocked([doing.id])) {
            try s.checkMove(.cards([card.id], to: .columnHeader(doing.id)), in: project)
        }
        let other = try s.createTask(in: project, title: "Other")
        try s.setDependencies(other, [card])
        let afterSetup = project.activities.count
        #expect(throws: KanbanServiceError.self, "a cycle") { try s.checkDependencies(card, [other]) }
        #expect(throws: KanbanServiceError.self) { try KanbanService.checkEdit([.estimateHours: .double(-1)]) }
        try KanbanService.checkEdit([.title: .string("Fine"), .jiraURL: nil])
        #expect(card.column?.id == project.orderedColumns[0].id && card.dependsOn.isEmpty)
        #expect(project.activities.count == afterSetup && afterSetup > entries)
    }
}
