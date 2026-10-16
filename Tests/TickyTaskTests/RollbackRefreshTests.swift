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

    @Test("A failed save with a deletion pending keeps the complete change instead of crashing")
    func deletionIsKeptNotRolledBack() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let task = TaskItem(title: "has subtasks", dayKey: "20260101")
        task.subtasks = [Subtask(title: "sub")]
        context.insert(task)
        try context.save()

        context.delete(task)               // rollback() would crash SwiftData here
        context.undoFailedTransaction()
        #expect(context.hasChanges, "the deletion stays pending for the next save")
        try context.save()
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Subtask>()).isEmpty)
    }
}
