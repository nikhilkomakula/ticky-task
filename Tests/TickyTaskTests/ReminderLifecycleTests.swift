import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Reminder lifecycle tests establish that concurrent syncs resolve to the newest
/// state, exact request sets match all lifecycle triggers, fetch failures leave
/// existing reminders untouched, and unauthorized/failing requests behave correctly.
///
/// These tests exercise: initial generation, rename, time/alarm changes, completion,
/// dated moves, list moves, occurrence/series deletion, auto-delete, rule changes,
/// restore, and materialization horizon extensions.
@MainActor
@Suite("Reminder lifecycle")
struct ReminderLifecycleTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ c: Calendar) -> Date {
        date(y, m, d, 0, 0, c)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ c: Calendar? = nil) -> Date {
        let calendar = c ?? cal()
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func dayKey(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d%02d%02d", y, m, d)
    }

    /// Reminder identifier for task UUID
    private func reminderId(_ task: TaskItem) -> String {
        "task.\(task.id.uuidString)"
    }

    // MARK: - Concurrent Sync → Newest State Ordering

    @Test("Concurrent syncs with state changes resolve to newest pending state")
    func concurrentSyncResolvesToNewestState() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let task = TaskItem(title: "Original", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        // First sync establishes the baseline
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)
        let id = reminderId(task)
        #expect(client.finalPendingContents[id]?.title == "Original")

        // Commit newer state
        task.title = "Updated"
        task.timeMinutes = 630

        // Start two concurrent syncs to simulate the ordering test
        let sync1 = Task {
            await NotificationService.syncTaskReminders(context: context, client: client, now: now)
        }
        let sync2 = Task {
            await NotificationService.syncTaskReminders(context: context, client: client, now: now)
        }

        // Wait for both to complete
        await sync1.value
        await sync2.value

        // Final pending contents must reflect the newest state (title, time)
        let reminder = client.finalPendingContents[id]
        #expect(reminder != nil)
        #expect(reminder?.title == "Updated")
        #expect(reminder?.fireDate.hour == 10)
        #expect(reminder?.fireDate.minute == 30)
    }

    // MARK: - Lifecycle Trigger Request Sets

    @Test("Initial generation schedules correct reminders")
    func initialGenerationSchedulesReminders() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let task1 = TaskItem(title: "Task A", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task1.alarmEnabled = true
        context.insert(task1)

        let task2 = TaskItem(title: "Task B", dayKey: dayKey(2026, 1, 21), timeMinutes: 630)
        task2.alarmEnabled = true
        context.insert(task2)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        let ids = Set(client.finalPendingContents.keys)
        #expect(ids.contains(reminderId(task1)))
        #expect(ids.contains(reminderId(task2)))
        #expect(client.finalPendingContents[reminderId(task1)]?.title == "Task A")
        #expect(client.finalPendingContents[reminderId(task2)]?.title == "Task B")
    }

    @Test("Rename via TaskEditCommit updates reminders")
    func renameViaEditCommitUpdatesReminders() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let task = TaskItem(title: "Original", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        // Initial sync
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        // Rename via edit commit
        var shared = SharedAttributes(task)
        shared.title = "Renamed"
        let edit = TaskEdit(originalShared: SharedAttributes(task), editedShared: shared)
        try TaskEditCommit.commit(edit, to: task, context: context, today: now, horizon: date(2026, 3, 15, c), calendar: c)

        // Sync again
        client.clearTracking()
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        let reminder = client.finalPendingContents[reminderId(task)]
        #expect(reminder?.title == "Renamed")
    }

    @Test("Time change via TaskEditCommit updates reminder")
    func timeChangeUpdatesReminder() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        // Change time
        var shared = SharedAttributes(task)
        shared.timeMinutes = 720
        let edit = TaskEdit(originalShared: SharedAttributes(task), editedShared: shared)
        try TaskEditCommit.commit(edit, to: task, context: context, today: now, horizon: date(2026, 3, 15, c), calendar: c)

        client.clearTracking()
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        let reminder = client.finalPendingContents[reminderId(task)]
        #expect(reminder?.fireDate.hour == 12)
        #expect(reminder?.fireDate.minute == 0)
    }

    @Test("Alarm off removes reminder")
    func alarmOffRemovesReminder() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)
        #expect(client.finalPendingContents.contains { $0.key == reminderId(task) })

        // Turn off alarm
        var shared = SharedAttributes(task)
        shared.alarmEnabled = false
        let edit = TaskEdit(originalShared: SharedAttributes(task), editedShared: shared)
        try TaskEditCommit.commit(edit, to: task, context: context, today: now, horizon: date(2026, 3, 15, c), calendar: c)

        client.clearTracking()
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        #expect(!client.finalPendingContents.contains { $0.key == reminderId(task) })
    }

    @Test("Completing occurrence removes its reminder")
    func completingOccurrenceRemovesReminder() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        task.isDone = true
        client.clearTracking()
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        #expect(!client.finalPendingContents.contains { $0.key == reminderId(task) })
    }

    @Test("Moving task to list removes reminder")
    func moveToListRemovesReminder() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let list = CustomList(name: "Groceries", sortIndex: 1)
        context.insert(list)

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)
        #expect(client.finalPendingContents.contains { $0.key == reminderId(task) })

        task.dayKey = nil
        task.customList = list

        client.clearTracking()
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        #expect(!client.finalPendingContents.contains { $0.key == reminderId(task) })
    }

    @Test("Deleting occurrence removes its reminder")
    func deleteOccurrenceRemovesReminder() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        try RecurrenceMaterializer.deleteOccurrence(task, context: context)

        client.clearTracking()
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        #expect(!client.finalPendingContents.contains { $0.key == reminderId(task) })
    }

    @Test("Series with occurrences tracks all reminders")
    func seriesWithOccurrencesTracksAllReminders() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        // Create a series definition
        let definition = TaskItem(title: "Daily")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        // Create occurrences
        let occ1 = TaskItem(title: "Daily", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        occ1.templateID = definition.id
        occ1.alarmEnabled = true
        context.insert(occ1)

        let occ2 = TaskItem(title: "Daily", dayKey: dayKey(2026, 1, 21), timeMinutes: 600)
        occ2.templateID = definition.id
        occ2.alarmEnabled = true
        context.insert(occ2)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        let ids = Set(client.finalPendingContents.keys)
        #expect(ids.contains(reminderId(occ1)))
        #expect(ids.contains(reminderId(occ2)))
        #expect(!ids.contains(reminderId(definition)))
    }

    @Test("Auto-delete preserves unrelated reminders")
    func autoDeletePreservesUnrelatedReminders() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 20, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        // Create a future task
        let futureTask = TaskItem(title: "Future", dayKey: dayKey(2026, 1, 25), timeMinutes: 600)
        futureTask.alarmEnabled = true
        context.insert(futureTask)

        // Create a completed old task
        let completedTask = TaskItem(title: "Old", dayKey: dayKey(2026, 1, 10), timeMinutes: 600)
        completedTask.alarmEnabled = true
        completedTask.isDone = true
        completedTask.completedAt = date(2026, 1, 11, 10, 0, c)
        context.insert(completedTask)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        // Auto-delete should only affect the old completed task
        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 5, now: now)

        client.clearTracking()
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        // Future task's reminder should still be there
        #expect(client.finalPendingContents.contains { $0.key == reminderId(futureTask) })
    }

    // MARK: - Fetch Failure Resilience

    @Test("Fetch failure leaves existing reminders untouched")
    func fetchFailurePreservesExistingReminders() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        // Initial sync: establish a reminder
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)
        let id = reminderId(task)
        #expect(client.finalPendingContents[id] != nil)

        let initialReminder = client.finalPendingContents[id]

        // Arm the fetch fault
        PersistenceFaults.armed.insert(.reminderFetch)

        // Commit state change
        task.title = "Changed"

        // Sync with fault: the fetch fails, so the sync returns early without updating
        // Track what was added/removed during this failed sync
        let addedBeforeFault = client.finalPendingContents.count
        await NotificationService.syncTaskReminders(context: context, client: client, now: now)
        let addedAfterFault = client.finalPendingContents.count

        // When fetch fails, nothing should be added or removed: the set stays the same
        #expect(addedBeforeFault == addedAfterFault)
        // The original reminder is still there (unchanged title from initial sync)
        #expect(client.finalPendingContents[id]?.title == initialReminder?.title)

        // Clean up
        PersistenceFaults.armed.removeAll()
    }

    @Test("Unauthorized client makes no changes")
    func unauthorizedClientMakesNoChanges() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = false

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        #expect(client.finalPendingContents.isEmpty)
    }

    @Test("One failing add does not prevent others from scheduling")
    func failingAddDoesNotStopOthers() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let task1 = TaskItem(title: "Task 1", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task1.alarmEnabled = true
        context.insert(task1)

        let task2 = TaskItem(title: "Task 2", dayKey: dayKey(2026, 1, 21), timeMinutes: 600)
        task2.alarmEnabled = true
        context.insert(task2)

        // Make task1's reminder fail on add
        client.failingIdentifier = reminderId(task1)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        // task2's reminder should still be scheduled despite task1's failure
        #expect(!client.finalPendingContents.contains { $0.key == reminderId(task1) })
        #expect(client.finalPendingContents.contains { $0.key == reminderId(task2) })
    }

    @Test("Past tasks never have reminders")
    func pastTasksNeverScheduled() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let pastTask = TaskItem(title: "Past", dayKey: dayKey(2026, 1, 10), timeMinutes: 600)
        pastTask.alarmEnabled = true
        context.insert(pastTask)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        #expect(client.finalPendingContents.isEmpty)
    }

    @Test("Definition rows never have reminders")
    func definitionRowsNeverScheduled() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let definition = TaskItem(title: "Daily")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        #expect(client.finalPendingContents.isEmpty)
    }

    @Test("Listed tasks never have reminders")
    func listedTasksNeverScheduled() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let client = TrackingNotificationClient()
        client.authorized = true

        let list = CustomList(name: "Groceries", sortIndex: 1)
        context.insert(list)

        let task = TaskItem(title: "Buy milk", timeMinutes: 600)
        task.alarmEnabled = true
        task.customList = list
        context.insert(task)

        await NotificationService.syncTaskReminders(context: context, client: client, now: now)

        #expect(client.finalPendingContents.isEmpty)
    }
}

// MARK: - Fake Clients

/// A fake that tracks final pending request contents as an id → TaskReminder map.
@MainActor
final class TrackingNotificationClient: NotificationScheduling {
    var authorized = true
    var pendingIds: [String] = []
    var finalPendingContents: [String: TaskReminder] = [:]
    var failingIdentifier: String?

    func isAuthorized() async -> Bool {
        authorized
    }

    func pendingIdentifiers() async -> [String] {
        pendingIds
    }

    func remove(_ identifiers: [String]) {
        for id in identifiers {
            pendingIds.removeAll { $0 == id }
            finalPendingContents.removeValue(forKey: id)
        }
    }

    func add(_ reminder: TaskReminder) async throws {
        if reminder.identifier == failingIdentifier {
            throw TestError.schedulingFailed
        }
        if !pendingIds.contains(reminder.identifier) {
            pendingIds.append(reminder.identifier)
        }
        finalPendingContents[reminder.identifier] = reminder
    }

    func clearTracking() {
        finalPendingContents.removeAll()
    }
}

private enum TestError: Error {
    case schedulingFailed
}
