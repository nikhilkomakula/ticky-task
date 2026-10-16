import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Reminder planner tests cover: eligibility filtering (dated, timed, alarm-on,
/// open, future, non-definition), identifier format, fire component calculation,
/// and reminder sync with fake notification client handling authorization,
/// additions, removals, and concurrent reconciliations.
@MainActor
@Suite("Reminder planner")
struct ReminderPlannerTests {
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

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ c: Calendar? = nil) -> Date {
        let calendar = c ?? cal()
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func dayKey(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d%02d%02d", y, m, d)
    }

    // MARK: - Eligibility

    @Test("ReminderPlanner excludes past tasks")
    func excludesPastTasks() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let pastTask = TaskItem(title: "Past task", dayKey: dayKey(2026, 1, 10), timeMinutes: 600)
        pastTask.alarmEnabled = true
        pastTask.isDone = false

        let reminders = ReminderPlanner.reminders(for: [pastTask], now: now, calendar: c)
        #expect(reminders.isEmpty)
    }

    @Test("ReminderPlanner excludes done tasks")
    func excludesDoneTasks() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let doneTask = TaskItem(title: "Done task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        doneTask.alarmEnabled = true
        doneTask.isDone = true

        let reminders = ReminderPlanner.reminders(for: [doneTask], now: now, calendar: c)
        #expect(reminders.isEmpty)
    }

    @Test("ReminderPlanner excludes definitions (recurrence != nil)")
    func excludesDefinitions() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let definition = TaskItem(id: UUID(), title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        definition.alarmEnabled = true
        definition.isDone = false

        let reminders = ReminderPlanner.reminders(for: [definition], now: now, calendar: c)
        #expect(reminders.isEmpty)
    }

    @Test("ReminderPlanner excludes undated tasks (no dayKey)")
    func excludesUndatedTasks() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let undatedTask = TaskItem(title: "Undated task", timeMinutes: 600)
        undatedTask.alarmEnabled = true
        undatedTask.isDone = false

        let reminders = ReminderPlanner.reminders(for: [undatedTask], now: now, calendar: c)
        #expect(reminders.isEmpty)
    }

    @Test("ReminderPlanner excludes untimed tasks (no timeMinutes)")
    func excludesUntimedTasks() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let untimedTask = TaskItem(title: "Untimed task", dayKey: dayKey(2026, 1, 20))
        untimedTask.alarmEnabled = true
        untimedTask.isDone = false

        let reminders = ReminderPlanner.reminders(for: [untimedTask], now: now, calendar: c)
        #expect(reminders.isEmpty)
    }

    @Test("ReminderPlanner excludes tasks with alarm disabled")
    func excludesAlarmDisabled() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let noAlarmTask = TaskItem(title: "No alarm", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        noAlarmTask.alarmEnabled = false
        noAlarmTask.isDone = false

        let reminders = ReminderPlanner.reminders(for: [noAlarmTask], now: now, calendar: c)
        #expect(reminders.isEmpty)
    }

    @Test("ReminderPlanner includes eligible tasks: dated, timed, alarm-on, open, future, non-definition")
    func includesEligibleTasks() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let eligible = TaskItem(title: "Eligible task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        eligible.alarmEnabled = true
        eligible.isDone = false

        let reminders = ReminderPlanner.reminders(for: [eligible], now: now, calendar: c)
        #expect(reminders.count == 1)
    }

    // MARK: - Identifier and title

    @Test("Reminder identifier is task.UUID")
    func reminderIdentifierFormat() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)
        let taskId = UUID()

        let task = TaskItem(id: taskId, title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true

        let reminders = ReminderPlanner.reminders(for: [task], now: now, calendar: c)
        #expect(reminders.count == 1)
        #expect(reminders[0].identifier == "task.\(taskId.uuidString)")
    }

    @Test("Reminder uses 'Task reminder' for empty title")
    func reminderEmptyTitleFallback() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let task = TaskItem(title: "", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true

        let reminders = ReminderPlanner.reminders(for: [task], now: now, calendar: c)
        #expect(reminders[0].title == "Task reminder")
    }

    @Test("Reminder uses task title when non-empty")
    func reminderUsesTaskTitle() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let task = TaskItem(title: "Prepare presentation", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true

        let reminders = ReminderPlanner.reminders(for: [task], now: now, calendar: c)
        #expect(reminders[0].title == "Prepare presentation")
    }

    // MARK: - Fire components

    @Test("Reminder fire components are correct for scheduled time")
    func reminderFireComponents() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let task = TaskItem(title: "Morning meeting", dayKey: dayKey(2026, 1, 20), timeMinutes: 540)
        task.alarmEnabled = true

        let reminders = ReminderPlanner.reminders(for: [task], now: now, calendar: c)
        let components = reminders[0].fireDate

        #expect(components.year == 2026)
        #expect(components.month == 1)
        #expect(components.day == 20)
        #expect(components.hour == 9)
        #expect(components.minute == 0)
    }

    @Test("Reminder body shows formatted time")
    func reminderBodyShowsTime() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 605)
        task.alarmEnabled = true

        let reminders = ReminderPlanner.reminders(for: [task], now: now, calendar: c)
        #expect(reminders[0].body == "Scheduled for 10:05")
    }

    // MARK: - Sync behavior

    @Test("Sync with unauthorized client changes nothing")
    func syncUnauthorizedDoesNothing() async throws {
        let context = makeContext()
        let c = cal()
        let fakeClient = FakeNotificationClient()
        fakeClient.authorized = false

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: date(2026, 1, 15, c))

        #expect(fakeClient.addedReminders.isEmpty)
        #expect(fakeClient.removedIdentifiers.isEmpty)
    }

    @Test("Sync removes only stale task reminders, not other identifiers")
    func syncRemovesOnlyTaskReminders() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let fakeClient = FakeNotificationClient()
        fakeClient.authorized = true
        fakeClient.pendingIds = ["task.old-uuid-1", "task.old-uuid-2", "tickytask.endOfDay", "other.id"]

        let task = TaskItem(title: "Current task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)

        let removed = Set(fakeClient.removedIdentifiers)
        #expect(removed.contains("task.old-uuid-1"))
        #expect(removed.contains("task.old-uuid-2"))
        #expect(!removed.contains("tickytask.endOfDay"))
        #expect(!removed.contains("other.id"))
    }

    @Test("Sync adds desired reminders and removes stale ones")
    func syncAddsAndRemovesCorrectly() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let fakeClient = FakeNotificationClient()
        fakeClient.authorized = true
        fakeClient.pendingIds = ["task.old-id"]

        let task1 = TaskItem(title: "Task 1", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task1.alarmEnabled = true
        context.insert(task1)

        let task2 = TaskItem(title: "Task 2", dayKey: dayKey(2026, 1, 21), timeMinutes: 600)
        task2.alarmEnabled = true
        context.insert(task2)

        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)

        // Old task removed
        #expect(fakeClient.removedIdentifiers.contains("task.old-id"))

        // New tasks added
        let addedIds = Set(fakeClient.addedReminders.map { $0.identifier })
        #expect(addedIds.contains("task.\(task1.id.uuidString)"))
        #expect(addedIds.contains("task.\(task2.id.uuidString)"))
    }

    @Test("Sync renamed series changes notification titles for eligible occurrences")
    func syncRenameUpdatesNotifications() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let fakeClient = FakeNotificationClient()
        fakeClient.authorized = true

        // Create a series
        let definition = TaskItem(id: UUID(), title: "Old title")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        let occurrence = TaskItem(title: "Old title", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        occurrence.templateID = definition.id
        occurrence.alarmEnabled = true
        context.insert(occurrence)

        // First sync: old title
        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)
        let firstReminder = fakeClient.addedReminders.first { $0.identifier == "task.\(occurrence.id.uuidString)" }
        #expect(firstReminder?.title == "Old title")

        // Change the title on the definition
        definition.title = "New title"
        occurrence.title = "New title"
        fakeClient.addedReminders.removeAll()
        fakeClient.removedIdentifiers.removeAll()

        // Sync again: new title
        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)
        let updatedReminder = fakeClient.addedReminders.first { $0.identifier == "task.\(occurrence.id.uuidString)" }
        #expect(updatedReminder?.title == "New title")
    }

    @Test("Sync completes one occurrence cancels only its reminder")
    func syncCompleteOneOccurrenceAffectsOnlyThat() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let fakeClient = FakeNotificationClient()
        fakeClient.authorized = true

        // Create a series with two occurrences
        let definition = TaskItem(id: UUID(), title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        let occ1 = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        occ1.templateID = definition.id
        occ1.alarmEnabled = true
        context.insert(occ1)

        let occ2 = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 21), timeMinutes: 600)
        occ2.templateID = definition.id
        occ2.alarmEnabled = true
        context.insert(occ2)

        // Initial sync
        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)
        #expect(fakeClient.addedReminders.count == 2)

        // Complete first occurrence
        occ1.isDone = true
        fakeClient.addedReminders.removeAll()
        fakeClient.removedIdentifiers.removeAll()

        // Sync again
        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)

        // Only the completed one should be removed
        #expect(fakeClient.removedIdentifiers.contains("task.\(occ1.id.uuidString)"))
        #expect(!fakeClient.removedIdentifiers.contains("task.\(occ2.id.uuidString)"))
    }

    @Test("Sync moving task to list cancels its reminder")
    func syncMoveToListCancelsReminder() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let fakeClient = FakeNotificationClient()
        fakeClient.authorized = true

        let list = CustomList(name: "Groceries", sortIndex: 1)
        context.insert(list)

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        // Initial sync
        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)
        #expect(fakeClient.addedReminders.count == 1)

        // Move to list
        task.dayKey = nil
        task.customList = list
        fakeClient.removedIdentifiers.removeAll()

        // Sync again
        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)

        #expect(fakeClient.removedIdentifiers.contains("task.\(task.id.uuidString)"))
    }

    @Test("Sync handles scheduling failure gracefully")
    func syncSchedulingFailureGraceful() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let fakeClient = FakeNotificationClient()
        fakeClient.authorized = true

        let task1 = TaskItem(title: "Task 1", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task1.alarmEnabled = true
        context.insert(task1)

        let task2 = TaskItem(title: "Task 2", dayKey: dayKey(2026, 1, 21), timeMinutes: 600)
        task2.alarmEnabled = true
        context.insert(task2)
        fakeClient.failingIdentifier = "task.\(task1.id.uuidString)"

        // One failing request must not stop the others from being scheduled.
        await NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)

        #expect(fakeClient.addedReminders.map(\.identifier) == ["task.\(task2.id.uuidString)"])
    }

    @Test("Overlapping syncs eventually reflect newest state")
    func syncConcurrentResolvesToNewest() async throws {
        let context = makeContext()
        let c = cal()

        let fakeClient = FakeNotificationClient()
        fakeClient.authorized = true

        let task = TaskItem(title: "Task", dayKey: dayKey(2026, 1, 20), timeMinutes: 600)
        task.alarmEnabled = true
        context.insert(task)

        let now = date(2026, 1, 15, 10, 0, c)

        // Start multiple concurrent syncs
        async let sync1 = NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)
        async let sync2 = NotificationService.syncTaskReminders(context: context, client: fakeClient, now: now)

        await sync1
        await sync2

        // Should have handled the reminders correctly despite concurrency
        let identifiers = Set(fakeClient.addedReminders.map { $0.identifier })
        #expect(identifiers.contains("task.\(task.id.uuidString)"))
    }
}

// MARK: - Fake notification client for testing

@MainActor
/// Behaves like the notification center: an added request becomes pending (re-adding
/// an identifier replaces it) and a removed one stops being pending.
final class FakeNotificationClient: NotificationScheduling {
    var authorized = true
    var pendingIds: [String] = []
    var addedReminders: [TaskReminder] = []
    var removedIdentifiers: [String] = []
    /// When set, adding this identifier throws (every other add succeeds).
    var failingIdentifier: String?

    func isAuthorized() async -> Bool {
        authorized
    }

    func pendingIdentifiers() async -> [String] {
        pendingIds
    }

    func remove(_ identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        pendingIds.removeAll { identifiers.contains($0) }
    }

    func add(_ reminder: TaskReminder) async throws {
        if reminder.identifier == failingIdentifier {
            throw TestError.schedulingFailed
        }
        addedReminders.append(reminder)
        if !pendingIds.contains(reminder.identifier) { pendingIds.append(reminder.identifier) }
    }
}

private enum TestError: Error {
    case schedulingFailed
}
