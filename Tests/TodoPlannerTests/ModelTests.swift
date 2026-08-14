import Testing
import Foundation
import SwiftData
@testable import TodoPlanner

@MainActor
@Suite("Model & persistence")
struct ModelTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    @Test("Insert and fetch a task")
    func insertFetch() throws {
        let context = makeContext()
        let service = DataService(context)
        try service.addTask(title: "Buy milk", location: .day("20260814"))
        try service.save()

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1)
        #expect(all.first?.title == "Buy milk")
        #expect(all.first?.dayKey == "20260814")
        #expect(all.first?.isDone == false)
    }

    @Test("Subtasks cascade-delete with their task")
    func cascadeSubtasks() throws {
        let context = makeContext()
        let service = DataService(context)
        let task = try service.addTask(title: "Parent", location: .day("20260814"))
        service.addSubtask(to: task, title: "child 1")
        service.addSubtask(to: task, title: "child 2")
        try service.save()
        #expect(try context.fetch(FetchDescriptor<Subtask>()).count == 2)

        service.delete(task)
        try service.save()
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Subtask>()).isEmpty)
    }

    @Test("Deleting a custom list cascades to its tasks")
    func cascadeListTasks() throws {
        let context = makeContext()
        let service = DataService(context)
        let list = try service.addCustomList(name: "Groceries")
        try service.addTask(title: "Eggs", location: .customList(list))
        try service.addTask(title: "Bread", location: .customList(list))
        try service.save()
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).count == 2)

        service.delete(list)
        try service.save()
        #expect(try context.fetch(FetchDescriptor<CustomList>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    }

    @Test("Deleting a task cascades its occurrences")
    func cascadeOccurrences() throws {
        let context = makeContext()
        let service = DataService(context)
        let task = try service.addTask(title: "Standup", location: .day("20260814"))
        task.occurrences.append(TaskOccurrence(dayKey: "20260814", isDone: true))
        try service.save()
        #expect(try context.fetch(FetchDescriptor<TaskOccurrence>()).count == 1)

        service.delete(task)
        try service.save()
        #expect(try context.fetch(FetchDescriptor<TaskOccurrence>()).isEmpty)
    }

    @Test("Deleting a task preserves its tags (only the association is removed)")
    func taskDeletePreservesTags() throws {
        let context = makeContext()
        let service = DataService(context)
        let task = try service.addTask(title: "Email", location: .day("20260814"))
        task.tags.append(TaskTag(name: "work"))
        try service.save()
        #expect(try context.fetch(FetchDescriptor<TaskTag>()).count == 1)

        service.delete(task)
        try service.save()
        let tags = try context.fetch(FetchDescriptor<TaskTag>())
        #expect(tags.count == 1)
        #expect(tags.first?.tasks.isEmpty == true)
    }

    @Test("Deleting a tag preserves tasks and clears the association")
    func tagDeletePreservesTasks() throws {
        let context = makeContext()
        let service = DataService(context)
        let task = try service.addTask(title: "Email", location: .day("20260814"))
        task.tags.append(TaskTag(name: "work"))
        try service.save()

        if let tag = try context.fetch(FetchDescriptor<TaskTag>()).first {
            context.delete(tag)
        }
        try service.save()
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.tags.isEmpty == true)
    }

    @Test("Recurrence rule round-trips as a codable attribute")
    func recurrencePersists() throws {
        let context = makeContext()
        let service = DataService(context)
        let task = try service.addTask(title: "Standup", location: .day("20260814"))
        task.recurrence = RecurrenceRule(frequency: .weekdays, interval: 1, startDate: Date())
        try service.save()

        let fetched = try context.fetch(FetchDescriptor<TaskItem>()).first
        #expect(fetched?.recurrence?.frequency == .weekdays)
        #expect(fetched?.isRecurringTemplate == true)
    }
}
