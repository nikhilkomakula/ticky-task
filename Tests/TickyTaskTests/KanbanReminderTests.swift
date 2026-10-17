import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Kanban reminder planner tests cover: eligibility filtering (open, non-archived,
/// future due date), identifier format, fire-date calculation, and reminder sync
/// with fake notification client.
@MainActor
@Suite("Kanban reminder planner")
struct KanbanReminderTests {
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

    // MARK: - Eligibility

    @Test("KanbanReminderPlanner disabled returns no reminders")
    func disabledReturnsNone() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Card", projectName: "Project",
            dueDate: date(2026, 1, 20, c), isDone: false,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: false, minutes: 540, now: now, calendar: c
        )
        #expect(reminders.isEmpty)
    }

    @Test("KanbanReminderPlanner excludes done cards")
    func excludesDoneCards() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Done card", projectName: "Project",
            dueDate: date(2026, 1, 20, c), isDone: true,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders.isEmpty)
    }

    @Test("KanbanReminderPlanner excludes archived cards")
    func excludesArchivedCards() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Archived card", projectName: "Project",
            dueDate: date(2026, 1, 20, c), isDone: false,
            isArchivedCard: true, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders.isEmpty)
    }

    @Test("KanbanReminderPlanner excludes cards in archived projects")
    func excludesCardsInArchivedProjects() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Card", projectName: "Archived project",
            dueDate: date(2026, 1, 20, c), isDone: false,
            isArchivedCard: false, isArchivedProject: true
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders.isEmpty)
    }

    @Test("KanbanReminderPlanner excludes cards without due date")
    func excludesUndatedCards() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Undated card", projectName: "Project",
            dueDate: nil, isDone: false,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders.isEmpty)
    }

    @Test("KanbanReminderPlanner excludes cards with past due date")
    func excludesPastDueCards() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Past due card", projectName: "Project",
            dueDate: date(2026, 1, 10, c), isDone: false,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders.isEmpty)
    }

    @Test("KanbanReminderPlanner includes eligible cards: open, non-archived, future due")
    func includesEligibleCards() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Eligible card", projectName: "Project",
            dueDate: date(2026, 1, 20, c), isDone: false,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders.count == 1)
    }

    // MARK: - Identifier and title

    @Test("Kanban reminder identifier is kanban.UUID")
    func reminderIdentifierFormat() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)
        let cardId = UUID()

        let card = KanbanReminderPlanner.CardSnapshot(
            id: cardId, title: "Card", projectName: "Project",
            dueDate: date(2026, 1, 20, c), isDone: false,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders.count == 1)
        #expect(reminders[0].identifier == "kanban.\(cardId.uuidString)")
    }

    @Test("Kanban reminder uses 'Task reminder' for empty title")
    func reminderEmptyTitleFallback() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "", projectName: "Project",
            dueDate: date(2026, 1, 20, c), isDone: false,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders[0].title == "Task reminder")
    }

    @Test("Kanban reminder uses card title when non-empty")
    func reminderUsesCardTitle() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Fix production bug", projectName: "Platform",
            dueDate: date(2026, 1, 20, c), isDone: false,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders[0].title == "Fix production bug")
    }

    @Test("Kanban reminder body shows project name")
    func reminderBodyShowsProjectName() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Card", projectName: "Mobile App",
            dueDate: date(2026, 1, 20, c), isDone: false,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 540, now: now, calendar: c
        )
        #expect(reminders[0].body == "Due Mobile App")
    }

    // MARK: - Fire components

    @Test("Kanban reminder fire components are correct for due date at minutes")
    func reminderFireComponents() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let card = KanbanReminderPlanner.CardSnapshot(
            id: UUID(), title: "Card", projectName: "Project",
            dueDate: date(2026, 1, 20, c), isDone: false,
            isArchivedCard: false, isArchivedProject: false
        )

        let reminders = KanbanReminderPlanner.reminders(
            for: [card], enabled: true, minutes: 605, now: now, calendar: c
        )
        let components = reminders[0].fireDate

        #expect(components.year == 2026)
        #expect(components.month == 1)
        #expect(components.day == 20)
        #expect(components.hour == 10)
        #expect(components.minute == 5)
    }

    // MARK: - Ordering

    @Test("Kanban reminders are ordered by identifier (UUID)")
    func remindersOrdered() {
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let cards = [
            KanbanReminderPlanner.CardSnapshot(
                id: id2, title: "B", projectName: "Project",
                dueDate: date(2026, 1, 20, c), isDone: false,
                isArchivedCard: false, isArchivedProject: false
            ),
            KanbanReminderPlanner.CardSnapshot(
                id: id3, title: "C", projectName: "Project",
                dueDate: date(2026, 1, 20, c), isDone: false,
                isArchivedCard: false, isArchivedProject: false
            ),
            KanbanReminderPlanner.CardSnapshot(
                id: id1, title: "A", projectName: "Project",
                dueDate: date(2026, 1, 20, c), isDone: false,
                isArchivedCard: false, isArchivedProject: false
            ),
        ]

        let reminders = KanbanReminderPlanner.reminders(
            for: cards, enabled: true, minutes: 540, now: now, calendar: c
        )

        #expect(reminders.count == 3)
        let ids = reminders.map { $0.identifier.dropFirst(7).description }
        #expect(ids == ids.sorted())
    }

    // MARK: - Sync behavior

    @Test("Sync with unauthorized client changes nothing")
    func syncUnauthorizedDoesNothing() async throws {
        let context = makeContext()
        let c = cal()
        let fakeClient = FakeKanbanNotificationClient()
        fakeClient.authorized = false

        let project = KanbanProject(name: "Project")
        context.insert(project)

        let column = KanbanColumn(name: "To Do", kind: .active)
        column.project = project
        context.insert(column)

        let card = KanbanTask(title: "Card")
        card.column = column
        card.project = project
        card.dueDate = date(2026, 1, 20, c)
        context.insert(card)

        await NotificationService.syncKanbanReminders(
            context: context, client: fakeClient, now: date(2026, 1, 15, c)
        )

        #expect(fakeClient.addedReminders.isEmpty)
        #expect(fakeClient.removedIdentifiers.isEmpty)
    }

    @Test("Sync removes only stale Kanban reminders, not other identifiers")
    func syncRemovesOnlyKanbanReminders() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let fakeClient = FakeKanbanNotificationClient()
        fakeClient.authorized = true
        fakeClient.pendingIds = ["kanban.old-uuid-1", "kanban.old-uuid-2", "task.some-uuid", "tickytask.endOfDay"]

        let project = KanbanProject(name: "Project")
        context.insert(project)

        let column = KanbanColumn(name: "To Do", kind: .active)
        column.project = project
        context.insert(column)

        let card = KanbanTask(title: "Current card")
        card.column = column
        card.project = project
        card.dueDate = date(2026, 1, 20, c)
        context.insert(card)

        await NotificationService.syncKanbanReminders(
            context: context, client: fakeClient, now: now
        )

        let removed = Set(fakeClient.removedIdentifiers)
        #expect(removed.contains("kanban.old-uuid-1"))
        #expect(removed.contains("kanban.old-uuid-2"))
        #expect(!removed.contains("task.some-uuid"))
        #expect(!removed.contains("tickytask.endOfDay"))
    }

    @Test("Sync adds desired reminders and removes stale ones")
    func syncAddsAndRemovesCorrectly() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let fakeClient = FakeKanbanNotificationClient()
        fakeClient.authorized = true
        fakeClient.pendingIds = ["kanban.old-id"]

        let project = KanbanProject(name: "Project")
        context.insert(project)

        let column = KanbanColumn(name: "To Do", kind: .active)
        column.project = project
        context.insert(column)

        let card1 = KanbanTask(title: "Card 1")
        card1.column = column
        card1.project = project
        card1.dueDate = date(2026, 1, 20, c)
        context.insert(card1)

        let card2 = KanbanTask(title: "Card 2")
        card2.column = column
        card2.project = project
        card2.dueDate = date(2026, 1, 21, c)
        context.insert(card2)

        // Enable Kanban notifications
        UserDefaults.standard.set(true, forKey: "kanban.notifyDueDates")
        UserDefaults.standard.set(540, forKey: "kanban.notifyDueMinutes")

        await NotificationService.syncKanbanReminders(
            context: context, client: fakeClient, now: now
        )

        // Old card removed
        #expect(fakeClient.removedIdentifiers.contains("kanban.old-id"))

        // New cards added
        let addedIds = Set(fakeClient.addedReminders.map { $0.identifier })
        #expect(addedIds.contains("kanban.\(card1.id.uuidString)"))
        #expect(addedIds.contains("kanban.\(card2.id.uuidString)"))

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "kanban.notifyDueDates")
        UserDefaults.standard.removeObject(forKey: "kanban.notifyDueMinutes")
    }

    @Test("Sync handles scheduling failure gracefully")
    func syncSchedulingFailureGraceful() async throws {
        let context = makeContext()
        let c = cal()
        let now = date(2026, 1, 15, 10, 0, c)

        let fakeClient = FakeKanbanNotificationClient()
        fakeClient.authorized = true

        let project = KanbanProject(name: "Project")
        context.insert(project)

        let column = KanbanColumn(name: "To Do", kind: .active)
        column.project = project
        context.insert(column)

        let card1 = KanbanTask(title: "Card 1")
        card1.column = column
        card1.project = project
        card1.dueDate = date(2026, 1, 20, c)
        context.insert(card1)

        let card2 = KanbanTask(title: "Card 2")
        card2.column = column
        card2.project = project
        card2.dueDate = date(2026, 1, 21, c)
        context.insert(card2)

        fakeClient.failingIdentifier = "kanban.\(card1.id.uuidString)"

        // Enable Kanban notifications
        UserDefaults.standard.set(true, forKey: "kanban.notifyDueDates")
        UserDefaults.standard.set(540, forKey: "kanban.notifyDueMinutes")

        // One failing request must not stop the others
        await NotificationService.syncKanbanReminders(
            context: context, client: fakeClient, now: now
        )

        let addedIds = fakeClient.addedReminders.map { $0.identifier }
        #expect(addedIds == ["kanban.\(card2.id.uuidString)"])

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "kanban.notifyDueDates")
        UserDefaults.standard.removeObject(forKey: "kanban.notifyDueMinutes")
    }
}

// MARK: - Fake notification client for testing

@MainActor
final class FakeKanbanNotificationClient: NotificationScheduling {
    var authorized = true
    var pendingIds: [String] = []
    var addedReminders: [TaskReminder] = []
    var removedIdentifiers: [String] = []
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
