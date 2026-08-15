import Testing
import Foundation
import SwiftData
@testable import TickyTask

@MainActor
@Suite("Auto-delete completed tasks")
struct AutoDeleteServiceTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    @Test("Enabled: removes only completed tasks older than the cutoff")
    func removesOldCompletedOnly() throws {
        let context = makeContext()
        let now = Date()

        let oldDone = TaskItem(title: "old done")
        oldDone.isDone = true; oldDone.completedAt = now.addingTimeInterval(-8 * 86_400)
        let recentDone = TaskItem(title: "recent done")
        recentDone.isDone = true; recentDone.completedAt = now.addingTimeInterval(-2 * 86_400)
        let open = TaskItem(title: "open")               // not done → kept
        let legacyDone = TaskItem(title: "legacy done")  // done but never stamped → kept
        legacyDone.isDone = true; legacyDone.completedAt = nil
        for t in [oldDone, recentDone, open, legacyDone] { context.insert(t) }
        try context.save()

        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 7, now: now)

        let remaining = try context.fetch(FetchDescriptor<TaskItem>()).map(\.title).sorted()
        #expect(remaining == ["legacy done", "open", "recent done"])
    }

    @Test("Disabled: keeps every completed task, however old")
    func disabledKeepsAll() throws {
        let context = makeContext()
        let old = TaskItem(title: "old")
        old.isDone = true; old.completedAt = Date().addingTimeInterval(-90 * 86_400)
        context.insert(old); try context.save()

        AutoDeleteService.purgeCompleted(context: context, enabled: false, olderThanDays: 7)

        #expect(try context.fetch(FetchDescriptor<TaskItem>()).count == 1)
    }

    @Test("Recurring templates are never auto-deleted")
    func keepsRecurringTemplates() throws {
        let context = makeContext()
        let now = Date()
        let template = TaskItem(title: "standup",
                                recurrence: RecurrenceRule(frequency: .daily, interval: 1, weekdays: [],
                                                           monthDays: [], end: .never, startDate: now))
        template.isDone = true; template.completedAt = now.addingTimeInterval(-30 * 86_400)
        context.insert(template); try context.save()

        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 7, now: now)

        #expect(try context.fetch(FetchDescriptor<TaskItem>()).count == 1)
    }
}
