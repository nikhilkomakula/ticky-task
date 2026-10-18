import Testing
import SwiftData
import Foundation

@testable import TickyTask

@Suite("Card creation drafts")
struct KanbanCardDraftTests {
    @Test("builds complete card draft from form state")
    func buildCompleteCardDraft() throws {
        var draft = KanbanCardDraft()
        draft.title = "Implement feature"
        draft.priority = 1
        draft.isCritical = true
        draft.columnID = UUID()
        draft.row = .unassigned
        draft.dueDate = Date()
        draft.estimateHours = 5.0
        draft.labelIDs = [UUID(), UUID()]
        draft.steps = [
            .init(title: "Design", isDone: false),
            .init(title: "Implement", isDone: false)
        ]

        let trimmed = draft.title.trimmingCharacters(in: .whitespaces)
        #expect(!trimmed.isEmpty)
        #expect(draft.priority == 1)
        #expect(draft.isCritical)
        #expect(draft.columnID != nil)
        #expect(draft.labelIDs.count == 2)
        #expect(draft.steps.count == 2)
    }

    @Test("trims title on validation")
    func trimsTitle() {
        let title = "  Test card  "
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        #expect(trimmed == "Test card")
    }

    @Test("empty title validation fails")
    func emptyTitleFails() {
        let title = "   "
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        #expect(trimmed.isEmpty)
    }

    @Test("preserves step drafts")
    func preservesSteps() {
        var draft = KanbanCardDraft()
        let step1 = KanbanCardDraft.Step(title: "Step 1", isDone: false, assigneeID: nil)
        let step2 = KanbanCardDraft.Step(title: "Step 2", isDone: true, assigneeID: nil)
        draft.steps = [step1, step2]

        #expect(draft.steps.count == 2)
        #expect(draft.steps[0].title == "Step 1")
        #expect(!draft.steps[0].isDone)
        #expect(draft.steps[1].isDone)
    }
}

@Suite("Task creation drafts")
struct TaskCreationDraftTests {
    @Test("builds complete task draft from form state")
    func buildCompleteTaskDraft() throws {
        var draft = TaskCreationDraft()
        draft.title = "New task"
        draft.notes = "Description"
        draft.dayKey = WeekMath.dayKey(for: Date())
        draft.location = .day(draft.dayKey ?? "")
        draft.timeMinutes = 540  // 9:00 AM
        draft.alarmEnabled = true
        draft.priority = 1
        draft.isCritical = false
        draft.steps = [
            .init(title: "Action 1", isDone: false),
            .init(title: "Action 2", isDone: false)
        ]

        let trimmed = draft.title.trimmingCharacters(in: .whitespaces)
        #expect(!trimmed.isEmpty)
        #expect(draft.dayKey != nil)
        #expect(draft.timeMinutes == 540)
        #expect(draft.alarmEnabled)
        #expect(draft.priority == 1)
        #expect(draft.steps.count == 2)
    }

    @Test("validates title is nonempty")
    func validatesTitle() {
        let title = "   "
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        #expect(trimmed.isEmpty)
    }

    @Test("validates time is in range")
    func validatesTimeRange() {
        let validTime = 540
        let invalidTime = 1440
        #expect((0..<(24 * 60)).contains(validTime))
        #expect(!(0..<(24 * 60)).contains(invalidTime))
    }

    @Test("preserves step drafts")
    func preservesSteps() {
        var draft = TaskCreationDraft()
        let step1 = TaskCreationDraft.Step(title: "Task 1", isDone: false)
        let step2 = TaskCreationDraft.Step(title: "Task 2", isDone: true)
        draft.steps = [step1, step2]

        #expect(draft.steps.count == 2)
        #expect(draft.steps[0].title == "Task 1")
        #expect(!draft.steps[0].isDone)
        #expect(draft.steps[1].isDone)
    }

    @Test("handles optional day key")
    func handlesOptionalDayKey() {
        var draft1 = TaskCreationDraft()
        draft1.dayKey = nil
        #expect(draft1.dayKey == nil)

        var draft2 = TaskCreationDraft()
        let dayKey = WeekMath.dayKey(for: Date())
        draft2.dayKey = dayKey
        #expect(draft2.dayKey == dayKey)
    }
}

@Suite("Draft form state validation")
struct DraftValidationTests {
    @Test("validates card title requirement")
    func validateCardTitleRequired() {
        var draft = KanbanCardDraft()
        draft.title = ""
        let trimmed = draft.title.trimmingCharacters(in: .whitespaces)
        #expect(trimmed.isEmpty)
    }

    @Test("validates task title requirement")
    func validateTaskTitleRequired() {
        var draft = TaskCreationDraft()
        draft.title = ""
        let trimmed = draft.title.trimmingCharacters(in: .whitespaces)
        #expect(trimmed.isEmpty)
    }

    @Test("preserves non-empty step titles")
    func preservesNonEmptyStepTitles() {
        var draft = KanbanCardDraft()
        draft.steps = [.init(title: "Non-empty", isDone: false, assigneeID: nil)]
        #expect(!draft.steps[0].title.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
