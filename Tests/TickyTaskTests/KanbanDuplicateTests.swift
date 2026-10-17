import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Duplicate (a card's menu, ⌘D): a copy right after the card, as one undoable new card.
@MainActor
@Suite("Kanban duplicate card", .serialized)
struct KanbanDuplicateTests {
    private func board() throws -> (KanbanService, KanbanHistory, KanbanProject, ModelContext) {
        let history = KanbanHistory()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        history.clear()
        return (service, history, project, context)
    }

    private func cell(_ task: KanbanTask, in project: KanbanProject) -> [String] {
        project.tasks.filter { $0.archivedAt == nil && $0.column?.id == task.column?.id && $0.resource?.id == task.resource?.id }
            .sorted { $0.sortIndex < $1.sortIndex }.map(\.title)
    }

    @Test("The copy keeps the card's fields, labels, dependencies and steps (not done), right after it")
    func copiesTheCard() throws {
        let (s, _, project, _) = try board()
        let ravi = try s.addMembership(try s.createPerson(name: "Ravi", initials: "RV"), to: project)
        let column = project.orderedColumns[1]
        let prerequisite = try s.createTask(in: project, title: "Design")
        let original = try s.createTask(in: project, title: "Build API", column: column, row: .resource(ravi.id))
        _ = try s.createTask(in: project, title: "Ship", column: column, row: .resource(ravi.id))
        let due = Calendar.current.startOfDay(for: Date())
        try s.edit(original, [.priority: .int(2), .isCritical: .bool(true), .dueDate: .date(due), .estimateHours: .double(6),
                              .jiraURL: .string("https://jira.example.com/browse/PLAT-9"), .isBlocked: .bool(true),
                              .blockedReason: .string("Keys"), .notes: .string("Use the gateway")])
        let label = try #require(project.labels.min { $0.sortIndex < $1.sortIndex })
        try s.setLabels(original, [label])
        original.dependsOn = [prerequisite]
        let step = try s.addSubtask(to: original, title: "Endpoints")
        _ = try s.setSubtaskDone(step, true)
        try s.context.save()

        let copy = try s.duplicateCard(original)
        #expect(copy.id != original.id && copy.title == "Build API copy")
        #expect(copy.priority == 2 && copy.isCritical && copy.dueDate == due && copy.estimateHours == 6 && copy.jiraKey == "PLAT-9")
        #expect(copy.isBlocked && copy.blockedReason == "Keys" && copy.notes == "Use the gateway")
        #expect(copy.column?.id == column.id && copy.resource?.id == ravi.id)
        #expect(copy.labels.map(\.id) == [label.id] && copy.dependsOn.map(\.id) == [prerequisite.id])
        let steps = copy.subtasks
        #expect(steps.map(\.title) == ["Endpoints"] && steps.allSatisfy { !$0.isDone }, "steps start again")
        #expect(cell(original, in: project) == ["Build API", "Build API copy", "Ship"], "right after the original")
        #expect(original.subtasks.first?.isDone == true, "the original is untouched")
    }

    @Test("One Change Log entry; undo removes the copy and puts the cell back")
    func undo() throws {
        let (s, history, project, context) = try board()
        let original = try s.createTask(in: project, title: "Triage")
        _ = try s.createTask(in: project, title: "Next")
        history.clear()
        let id = project.id
        let entries = { try context.fetchCount(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id })) }
        let before = try entries()
        let copy = try s.duplicateCard(original)
        let after = try entries()
        #expect(after == before + 1)
        let copyID = copy.id
        try s.undo(in: project)
        #expect(try context.fetch(FetchDescriptor<KanbanTask>(predicate: #Predicate { $0.id == copyID })).isEmpty)
        #expect(cell(original, in: project) == ["Triage", "Next"])
    }

    @Test("An archived card, or a full column with a blocking WIP limit, is refused and nothing changes")
    func refusals() throws {
        let (s, _, project, context) = try board()
        let archived = try s.createTask(in: project, title: "Old")
        try s.setArchived([archived], true)
        let column = project.orderedColumns[1]
        let full = try s.createTask(in: project, title: "Busy", column: column)
        try s.editColumn(column, wipLimit: .some(1))
        project.wipPolicyRaw = KanbanWIPPolicy.block.rawValue
        try context.save()
        let count = try context.fetchCount(FetchDescriptor<KanbanTask>())
        #expect(throws: (any Error).self) { try s.duplicateCard(archived) }
        #expect(throws: (any Error).self) { try s.duplicateCard(full) }
        #expect(try context.fetchCount(FetchDescriptor<KanbanTask>()) == count)
    }
}
