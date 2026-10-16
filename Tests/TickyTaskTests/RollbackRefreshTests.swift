import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// `ModelContext.rollback()` leaves loaded objects holding discarded values until
/// they are fetched again; `undoFailedTransaction()` must restore the saved state —
/// and must never call `rollback()` on a deletion, which crashes SwiftData.
@MainActor
@Suite("Rollback refresh")
struct RollbackRefreshTests {
    @Test("Loaded objects show their saved values after a rollback")
    func restoresLoadedObjects() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let task = TaskItem(title: "saved", dayKey: "20260101")
        task.subtasks = [Subtask(title: "sub")]
        context.insert(task)
        try context.save()
        let fetched = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)

        task.title = "pending"
        let titleKeyPath: ReferenceWritableKeyPath<TaskItem, String> = \.notes
        fetched[keyPath: titleKeyPath] = "pending notes"
        task.subtasks.first?.title = "pending sub"
        context.insert(TaskItem(title: "inserted", dayKey: "20260102"))

        context.undoFailedTransaction()

        #expect(task.title == "saved")
        #expect(task.notes.isEmpty)
        #expect(task.subtasks.map(\.title) == ["sub"])
        #expect(!context.hasChanges)
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).map(\.title) == ["saved"])
    }

    @Test("A failed save with a deletion pending restarts the app instead of crashing or saving it later")
    func deletionIsDiscardedByRestarting() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        DiscardedContexts.keep(context)
        let task = TaskItem(title: "has subtasks", dayKey: "20260101")
        task.subtasks = [Subtask(title: "sub")]
        context.insert(task)
        try context.save()

        var restarted = false
        PersistenceRecovery.testHook = { restarted = true }
        defer { PersistenceRecovery.testHook = nil }
        context.delete(task)               // rollback() would crash SwiftData here
        context.undoFailedTransaction()
        #expect(restarted, "the app restarts to discard the change instead of saving it later")
        #expect(!context.autosaveEnabled, "autosave can't commit it meanwhile")
    }

    @Test("After a restart for a failed save, auto-delete waits, so a store that keeps failing can't restart the app again and again")
    func recoverySessionSkipsAutoDelete() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let task = TaskItem(title: "done long ago", dayKey: "20260101")
        task.setDone(true, at: Date(timeIntervalSinceNow: -30 * 86_400))
        context.insert(task)
        try context.save()

        PersistenceRecovery.didRelaunch = true
        defer { PersistenceRecovery.didRelaunch = false }
        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 1)
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 1, "skipped in the recovery session")

        PersistenceRecovery.didRelaunch = false
        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 1)
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 0, "runs normally otherwise")
    }
}