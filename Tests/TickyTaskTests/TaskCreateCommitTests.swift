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

    @Test("A recurring create is transactional: task, steps and series definition save as one unit")
    func recurringCreate() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let today = Date()
        let rule = RecurrenceRule(frequency: .weekly, interval: 1, weekdays: [2], monthDays: [],
                                  end: .afterCount(3), startDate: today)
        var draft = TaskCreationDraft()
        draft.title = "Team meeting"
        draft.location = .day("20261017")
        draft.dayKey = "20261017"
        draft.repeatRule = rule
        draft.steps = [.init(title: "Prepare agenda"), .init(title: "Send notes")]

        let task = try TaskCreateCommit.commit(draft, context: context, today: today, horizon: horizon)
        #expect(task.title == "Team meeting" && task.subtasks.count == 2)
        let allTasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(allTasks.count >= 1, "template and occurrences saved as one transaction")
        #expect(try context.fetchCount(FetchDescriptor<Subtask>()) == 2)
        #expect(!context.hasChanges, "saved")
    }

    @Test("Failure after first insert is rolled back completely")
    func failureAfterInsertRollsBack() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        var draft = TaskCreationDraft()
        draft.title = "Task with rule"
        draft.location = .day("20261020")
        draft.dayKey = "20261020"
        draft.repeatRule = RecurrenceRule(frequency: .daily, interval: 1, weekdays: [], monthDays: [],
                                          end: .never, startDate: Date())
        draft.steps = [.init(title: "Step 1")]

        #expect(throws: PersistenceFaults.InjectedFailure.self) {
            try TaskCreateCommit.commit(draft, context: context, horizon: horizon) { _ in
                throw PersistenceFaults.InjectedFailure()
            }
        }
        #expect(context.hasChanges == false, "all changes rolled back")
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Subtask>()) == 0)

        // Retry creates exactly one template
        let task = try TaskCreateCommit.commit(draft, context: context, horizon: horizon)
        #expect(task.title == "Task with rule" && task.subtasks.count == 1)
        let allTasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(allTasks.count >= 1, "template and possibly occurrences")
        #expect(try context.fetchCount(FetchDescriptor<Subtask>()) == 1)
    }

    @Test("Position appends at max sortIndex + 1, not sibling count")
    func positionIsMaxIndexPlus1() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        // Create a few tasks at indices that aren't consecutive
        var t1 = TaskCreationDraft(); t1.title = "First"; t1.location = .unassigned
        var t2 = TaskCreationDraft(); t2.title = "Second"; t2.location = .unassigned
        var t3 = TaskCreationDraft(); t3.title = "Third"; t3.location = .unassigned
        let task1 = try TaskCreateCommit.commit(t1, context: context, horizon: horizon)
        let task2 = try TaskCreateCommit.commit(t2, context: context, horizon: horizon)
        let task3 = try TaskCreateCommit.commit(t3, context: context, horizon: horizon)

        // Manually set gaps: [1, 2] instead of [0, 1]
        task1.sortIndex = 4
        task2.sortIndex = 5
        try context.save()

        // New task should get 6, not 2
        var draft = TaskCreationDraft(); draft.title = "New"; draft.location = .unassigned
        let newTask = try TaskCreateCommit.commit(draft, context: context, horizon: horizon)
        #expect(newTask.sortIndex == 6, "max(4, 5) + 1 = 6")
    }
}
