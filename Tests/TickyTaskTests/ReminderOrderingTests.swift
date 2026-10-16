import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Reminder reconciliation always ends at the newest store state, and every series
/// lifecycle step leaves exactly the requests the planner calls for.
@MainActor
@Suite("Reminder ordering", .serialized)
struct ReminderOrderingTests {
    /// A notification center stand-in that keeps the final pending contents and can
    /// hold one sync inside `pendingIdentifiers()` until the test releases it.
    final class GatedClient: NotificationScheduling {
        var pending: [String: TaskReminder] = [:]
        var addOrder: [String] = []
        var holdNext = false
        private(set) var isHeld = false
        private var gate: CheckedContinuation<Void, Never>?

        func isAuthorized() async -> Bool { true }

        func pendingIdentifiers() async -> [String] {
            if holdNext {
                holdNext = false
                isHeld = true
                await withCheckedContinuation { gate = $0 }
                isHeld = false
            }
            return Array(pending.keys)
        }

        func release() { gate?.resume(); gate = nil }

        func remove(_ identifiers: [String]) {
            for id in identifiers { pending.removeValue(forKey: id) }
        }

        func add(_ reminder: TaskReminder) async throws {
            pending[reminder.identifier] = reminder
            addOrder.append(reminder.title)
        }
    }

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ c: Calendar) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// The requests the planner calls for, for comparison with what was scheduled.
    private func expected(_ context: ModelContext, now: Date) throws -> [String: String] {
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        return Dictionary(uniqueKeysWithValues: ReminderPlanner.reminders(for: tasks, now: now)
            .map { ($0.identifier, "\($0.title)@\($0.fireDate.day ?? 0)/\($0.fireDate.hour ?? 0):\($0.fireDate.minute ?? 0)") })
    }

    private func scheduled(_ client: GatedClient) -> [String: String] {
        client.pending.mapValues { "\($0.title)@\($0.fireDate.day ?? 0)/\($0.fireDate.hour ?? 0):\($0.fireDate.minute ?? 0)" }
    }

    @Test("A sync held mid-way never leaves its stale snapshot as the final state")
    func newestStateWins() async throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let now = Date()
        let task = TaskItem(title: "Original", dayKey: WeekMath.dayKey(for: now.addingTimeInterval(3 * 86_400)),
                            timeMinutes: 600, alarmEnabled: true)
        context.insert(task)
        try context.save()

        let client = GatedClient()
        client.holdNext = true
        let syncA = Task { await NotificationService.syncTaskReminders(context: context, client: client, now: now) }
        for _ in 0..<1_000 where !client.isHeld { await Task.yield() }
        #expect(client.isHeld, "sync A read the store and is waiting")

        task.title = "Updated"
        task.timeMinutes = 630
        try context.save()
        let syncB = Task { await NotificationService.syncTaskReminders(context: context, client: client, now: now) }
        await Task.yield()
        client.release()
        await syncA.value
        await syncB.value

        let id = ReminderPlanner.identifierPrefix + task.id.uuidString
        #expect(client.pending[id]?.title == "Updated")
        #expect(client.pending[id]?.fireDate.hour == 10 && client.pending[id]?.fireDate.minute == 30)
        #expect(client.addOrder == ["Original", "Updated"], "B ran after A, so B's newer snapshot is last")
    }

    @Test("Each series lifecycle step leaves exactly the planned requests")
    func lifecycleRequestSets() async throws {
        let c = cal()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let now = date(2026, 1, 5, c)
        let client = GatedClient()
        func sync() async throws -> Bool {
            await NotificationService.syncTaskReminders(context: context, client: client, now: now)
            return scheduled(client) == (try expected(context, now: now))
        }

        let seed = TaskItem(title: "Standup", dayKey: "20260106", timeMinutes: 540, alarmEnabled: true)
        context.insert(seed)
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 6, c)),
            through: date(2026, 1, 12, c), context: context, calendar: c)
        let other = TaskItem(title: "Weekly", dayKey: "20260107", timeMinutes: 600, alarmEnabled: true)
        context.insert(other)
        let otherDefinition = try RecurrenceMaterializer.startSeries(
            from: other, rule: RecurrenceRule(frequency: .weekly, weekdays: [4], startDate: date(2026, 1, 7, c)),
            through: date(2026, 1, 31, c), context: context, calendar: c)
        try context.save()
        #expect(try await sync(), "initial generation")
        #expect(client.pending.count == 7 + 4)

        // Generating further ahead gives the new occurrences reminders.
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 20, c), calendar: c)
        #expect(try await sync(), "later generation")
        #expect(client.pending.count == 15 + 4)

        // Stop Repeating removes the untouched future occurrences and their reminders.
        var stopped = try #require(definition.recurrence)
        stopped.end = .until(date(2026, 1, 8, c))
        try RecurrenceMaterializer.changeRule(of: definition, to: stopped, today: date(2026, 1, 8, c),
                                              through: date(2026, 1, 20, c), context: context, calendar: c)
        try context.save()
        #expect(try await sync(), "after Stop")
        #expect(client.pending.values.filter { $0.title == "Standup" }.count == 3)

        // Deleting a list holding an occurrence cancels its reminder.
        let list = try DataService(context).addCustomList(name: "Inbox")
        let moved = try #require(try RecurrenceMaterializer.children(of: otherDefinition, context: context)
            .first { $0.occurrenceKey == "20260114" })
        try DataService(context).dropTask(moved.id, into: .customList(list), before: nil, siblings: [])
        #expect(try await sync(), "after a move into a list")
        try DataService(context).delete(list)
        #expect(try await sync(), "after deleting the list")

        // Deleting a whole series cancels all of its reminders.
        try RecurrenceMaterializer.deleteSeries(otherDefinition, context: context)
        #expect(try await sync(), "after deleting a series")
        #expect(!client.pending.values.contains { $0.title == "Weekly" })

        // Restoring a backup reschedules exactly what the restored store calls for.
        let snapshot = try BackupStore.makeSnapshot(context: context)
        let restored = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        try BackupStore.restore(snapshot, context: restored)
        await NotificationService.syncTaskReminders(context: restored, client: client, now: now)
        #expect(scheduled(client) == (try expected(restored, now: now)), "after restore")
    }
}
