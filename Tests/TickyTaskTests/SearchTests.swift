import Testing
import Foundation
import SwiftData
@testable import TickyTask

@Suite("Task search matching")
struct TaskSearchMatchTests {
    @Test("normalize trims whitespace")
    func normalize() {
        #expect(TaskSearch.normalize("  Hello WORLD  ") == "Hello WORLD")
        #expect(TaskSearch.normalize("   ").isEmpty)
    }

    @Test("matches title or notes, case-insensitively")
    func matches() {
        #expect(TaskSearch.matches(title: "Buy Milk", notes: "", query: "milk"))
        #expect(TaskSearch.matches(title: "Buy Milk", notes: "", query: "MILK"))
        #expect(TaskSearch.matches(title: "Groceries", notes: "get MILK today", query: "milk"))
        #expect(!TaskSearch.matches(title: "Walk dog", notes: "park", query: "milk"))
        #expect(!TaskSearch.matches(title: "milk", notes: "", query: ""))
    }
}

@MainActor
@Suite("Task search ranking")
struct TaskSearchRankTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    @Test("Ranks title hits above notes-only hits and excludes non-matches")
    func ranking() throws {
        let context = makeContext()
        let day = WeekMath.dayKey(for: Date())

        let titleHit = TaskItem(title: "Buy milk", dayKey: day)
        titleHit.updatedAt = Date(timeIntervalSince1970: 100)   // older
        let notesHit = TaskItem(title: "Groceries", dayKey: day)
        notesHit.notes = "remember the milk"
        notesHit.updatedAt = Date(timeIntervalSince1970: 200)   // newer
        let noHit = TaskItem(title: "Walk dog", dayKey: day)
        for task in [titleHit, notesHit, noHit] { context.insert(task) }
        try context.save()

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let results = TaskSearch.rank(all, query: "MILK")

        #expect(results.count == 2)
        // Title hit ranks first even though the notes-only hit is newer.
        #expect(results.first?.title == "Buy milk")
        #expect(!results.contains { $0.title == "Walk dog" })
        #expect(TaskSearch.rank(all, query: "   ").isEmpty)
    }

    @Test("Equal-timestamp title hits order stably by id")
    func stableOrdering() throws {
        let context = makeContext()
        let day = WeekMath.dayKey(for: Date())
        let ts = Date(timeIntervalSince1970: 500)
        let a = TaskItem(title: "milk A", dayKey: day); a.updatedAt = ts
        let b = TaskItem(title: "milk B", dayKey: day); b.updatedAt = ts
        for task in [a, b] { context.insert(task) }
        try context.save()

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let forward = TaskSearch.rank(all, query: "milk").map(\.id)
        let reversed = TaskSearch.rank(all.reversed(), query: "milk").map(\.id)
        #expect(forward == reversed)   // independent of input order
        #expect(forward == [a.id, b.id].sorted { $0.uuidString < $1.uuidString })
    }
}
