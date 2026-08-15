import Testing
import Foundation
import SwiftData
@testable import TickyTask

@MainActor
@Suite("Drag reorder & cross-container move")
struct DragReorderTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    @Test("Reorder within a day: dragged task lands before the target")
    func reorderWithinDay() throws {
        let context = makeContext()
        let service = DataService(context)
        let a = try service.addTask(title: "A", location: .day("20260101"))
        let b = try service.addTask(title: "B", location: .day("20260101"))
        let c = try service.addTask(title: "C", location: .day("20260101"))
        try service.save()

        try service.dropTask(c.id, into: .day("20260101"), before: a.id, siblings: [a, b, c])

        let ordered = BehaviorService.sorted(try context.fetch(FetchDescriptor<TaskItem>()),
                                             mode: .manual, completedToBottom: false)
        #expect(ordered.map(\.title) == ["C", "A", "B"])
    }

    @Test("Dropping a task on another day moves it there and positions it")
    func moveAcrossDays() throws {
        let context = makeContext()
        let service = DataService(context)
        let a = try service.addTask(title: "A", location: .day("20260101"))
        let t = try service.addTask(title: "T", location: .day("20260102"))
        try service.save()

        try service.dropTask(a.id, into: .day("20260102"), before: t.id, siblings: [t])

        #expect(a.dayKey == "20260102")
        #expect(a.customList == nil)
        let day2 = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == "20260102" }
        let ordered = BehaviorService.sorted(day2, mode: .manual, completedToBottom: false)
        #expect(ordered.map(\.title) == ["A", "T"])
    }

    @Test("Dropping a task on a custom list moves it into the list (day cleared)")
    func moveIntoList() throws {
        let context = makeContext()
        let service = DataService(context)
        let list = try service.addCustomList(name: "Inbox")
        let a = try service.addTask(title: "A", location: .day("20260101"))
        try service.save()

        try service.dropTask(a.id, into: .customList(list), before: nil, siblings: [])

        #expect(a.customList?.id == list.id)
        #expect(a.dayKey == nil)
    }

    @Test("Dropping onto itself is a no-op")
    func dropOnSelfNoop() throws {
        let context = makeContext()
        let service = DataService(context)
        let a = try service.addTask(title: "A", location: .day("20260101"))
        let b = try service.addTask(title: "B", location: .day("20260101"))
        try service.save()

        try service.dropTask(a.id, into: .day("20260101"), before: a.id, siblings: [a, b])

        let ordered = BehaviorService.sorted(try context.fetch(FetchDescriptor<TaskItem>()),
                                             mode: .manual, completedToBottom: false)
        #expect(ordered.map(\.title) == ["A", "B"])
    }

    @Test("reordered() moves before the target, appends on nil, no-ops on unknown")
    func reorderedPure() {
        struct Item: Identifiable { let id: Int }
        let items = [Item(id: 1), Item(id: 2), Item(id: 3)]
        #expect(BehaviorService.reordered(items, moving: 3, before: 1).map(\.id) == [3, 1, 2])
        #expect(BehaviorService.reordered(items, moving: 1, before: nil).map(\.id) == [2, 3, 1])
        #expect(BehaviorService.reordered(items, moving: 9, before: 1).map(\.id) == [1, 2, 3])
    }
}
