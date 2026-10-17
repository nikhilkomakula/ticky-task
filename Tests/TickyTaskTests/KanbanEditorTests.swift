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

    @Test("A blocking WIP limit refuses a new card in a full column")
    func createRespectsBlockingLimit() throws {
        let (s, _, project, _) = try board()
        let doing = project.orderedColumns[1]
        try s.editColumn(doing, wipLimit: .some(1))
        _ = try s.createTask(in: project, title: "One", column: doing)
        _ = try s.createTask(in: project, title: "Two (warn policy)", column: doing)
        project.wipPolicy = .block
        let count = project.tasks.count
        #expect(throws: KanbanServiceError.wipBlocked([doing.id])) { try s.createTask(in: project, title: "Three", column: doing) }
        #expect(project.tasks.count == count)
        _ = try s.createTask(in: project, title: "Backlog is fine")
    }

    @Test("Schedule to day creates a linked planner task once, then only moves it")
    func scheduleToDay() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let project = try s.createProject(name: "Platform", key: "PLAT")
        let card = try s.createTask(in: project, title: "Ship it")
        try s.edit(card, [.priority: .int(2), .isCritical: .bool(true), .notes: .string("details")])
        let first = try s.schedule(card, on: "20261020")
        #expect(first.dayKey == "20261020" && first.title == "Ship it" && first.priority == 2 && first.isCritical && first.notes == "details")
        #expect(card.linkedPlannerTaskID == first.id)
        first.title = "Ship it (planner wording)"   // a planner edit
        let again = try s.schedule(card, on: "20261022")
        #expect(again.id == first.id && again.dayKey == "20261022" && again.title == "Ship it (planner wording)", "moved, never overwritten")
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 1)
        let entry = try #require(project.activities.max { $0.seq < $1.seq })
        #expect(entry.kindRaw == KanbanActivityKind.scheduled.rawValue && !KanbanService.offersRevert(entry))
        // A link to a task that's gone makes a new one.
        context.delete(first)
        try context.save()
        let fresh = try s.schedule(card, on: "20261023")
        #expect(fresh.id != first.id && card.linkedPlannerTaskID == fresh.id)
        #expect(throws: KanbanServiceError.self) { try s.schedule(card, on: "nonsense") }
    }
}
