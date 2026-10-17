import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Creating a planner task from the full editor (UI polish A1): one save, nothing on a refusal.
@MainActor
@Suite("Planner task create", .serialized)
struct TaskCreateCommitTests {
    private let horizon = Date().addingTimeInterval(86_400 * 60)

    @Test("A new task keeps every field and its steps")
    func fullCreate() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        var draft = TaskCreationDraft()
        draft.title = "  Call the vendor  "
        draft.notes = "Ask about the renewal"
        draft.location = .day("20261020")
        draft.timeMinutes = 9 * 60 + 30
        draft.priority = 2
        draft.isCritical = true
        draft.steps = [.init(title: "Find the contract"), .init(title: "Book a slot", isDone: true)]
        let task = try TaskCreateCommit.commit(draft, context: context, horizon: horizon)
        #expect(task.title == "Call the vendor" && task.dayKey == "20261020" && task.timeMinutes == 570)
        #expect(task.priority == 2 && task.isCritical && task.notes == "Ask about the renewal")
        #expect(task.subtasks.sorted { $0.sortIndex < $1.sortIndex }.map(\.title) == ["Find the contract", "Book a slot"])
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 1 && !context.hasChanges, "saved")
    }

    @Test("A refused draft inserts nothing")
    func refused() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        var blank = TaskCreationDraft(); blank.title = "  "; blank.location = .day("20261020")
        var badStep = TaskCreationDraft(); badStep.title = "Task"; badStep.steps = [.init(title: " ")]
        var badTime = TaskCreationDraft(); badTime.title = "Task"; badTime.timeMinutes = 24 * 60
        for draft in [blank, badStep, badTime] {
            #expect(throws: (any Error).self) { try TaskCreateCommit.commit(draft, context: context, horizon: horizon) }
        }
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 0 && context.fetchCount(FetchDescriptor<Subtask>()) == 0)
    }
}
