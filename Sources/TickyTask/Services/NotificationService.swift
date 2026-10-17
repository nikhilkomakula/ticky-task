import Foundation
import SwiftData
import UserNotifications

/// Local notifications: per-task time reminders and a daily "end of day"
/// unfinished-tasks reminder.
///
/// Note: macOS delivers local notifications only for apps it can identify by
/// code signature. An unsigned dev build may not receive authorization or
/// delivery; an ad-hoc or Developer-ID signed build does. The scheduling code
/// is correct either way.
enum NotificationService {
    private static var center: UNUserNotificationCenter { .current() }
    private static let endOfDayIdentifier = "tickytask.endOfDay"

    @discardableResult
    static func requestAuthorization() async -> Bool {
        // Tests share the real app's bundle id: never prompt or change its authorization.
        guard !UITestSupport.isRunning, !UITestSupport.isHostingUnitTests else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func isAuthorized() async -> Bool {
        await center.notificationSettings().authorizationStatus == .authorized
    }

    /// The latest reminder reconciliation; each sync waits for the previous one, so
    /// an older snapshot can never land after a newer one.
    @MainActor private static var latestSync: Task<Void, Never>?

    /// Reconcile per-task reminders with the store. Never runs under tests, where
    /// the app shares the real app's bundle id (and so its notification center).
    @MainActor
    static func syncTaskReminders(context: ModelContext) async {
        guard !UITestSupport.isRunning, !UITestSupport.isHostingUnitTests else { return }
        await syncTaskReminders(context: context, client: SystemNotificationClient())
    }

    @MainActor
    static func syncTaskReminders(context: ModelContext, client: some NotificationScheduling,
                                  now: Date? = nil) async {
        let previous = latestSync
        let sync = Task { @MainActor in
            await previous?.value
            await reconcile(context: context, client: client, now: now ?? Date())
        }
        latestSync = sync
        await sync.value
    }

    /// Build the desired set first, so a failed fetch leaves existing reminders in
    /// place; then drop only stale task reminders and (re)add the desired ones.
    @MainActor
    private static func reconcile(context: ModelContext, client: some NotificationScheduling, now: Date) async {
        guard await client.isAuthorized(),
              (try? PersistenceFaults.check(.reminderFetch)) != nil,
              let tasks = try? context.fetch(FetchDescriptor<TaskItem>()) else { return }
        let desired = ReminderPlanner.reminders(for: tasks, now: now)
        let desiredIDs = Set(desired.map(\.identifier))
        let stale = await client.pendingIdentifiers()
            .filter { $0.hasPrefix(ReminderPlanner.identifierPrefix) && !desiredIDs.contains($0) }
        client.remove(stale)
        for reminder in desired {
            do {
                try await client.add(reminder)
            } catch {
                NSLog("TickyTask: scheduling reminder \(reminder.identifier) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Reconcile Kanban due-date reminders with the store. Never runs under tests.
    @MainActor
    static func syncKanbanReminders(context: ModelContext) async {
        guard !UITestSupport.isRunning, !UITestSupport.isHostingUnitTests else { return }
        await syncKanbanReminders(context: context, client: SystemNotificationClient())
    }

    @MainActor
    static func syncKanbanReminders(context: ModelContext, client: some NotificationScheduling,
                                    now: Date? = nil) async {
        let previous = latestKanbanSync
        let sync = Task { @MainActor in
            await previous?.value
            await reconcileKanban(context: context, client: client, now: now ?? Date())
        }
        latestKanbanSync = sync
        await sync.value
    }

    /// The latest Kanban reminder reconciliation; each sync waits for the previous one.
    @MainActor private static var latestKanbanSync: Task<Void, Never>?

    @MainActor
    private static func reconcileKanban(context: ModelContext, client: some NotificationScheduling, now: Date) async {
        // A failed fetch returns before anything is removed, so pending reminders stay.
        guard await client.isAuthorized(),
              (try? PersistenceFaults.check(.reminderFetch)) != nil,
              let cards = fetchKanbanCards(context: context) else { return }

        let enabled = UserDefaults.standard.bool(forKey: "kanban.notifyDueDates", default: false)
        let minutes = UserDefaults.standard.integer(forKey: "kanban.notifyDueMinutes", default: 9 * 60)

        let desired = KanbanReminderPlanner.reminders(
            for: cards,
            enabled: enabled,
            minutes: minutes,
            now: now
        )

        let desiredIDs = Set(desired.map(\.identifier))
        let pending = await client.pendingIdentifiers()
        let staleKanban = pending
            .filter { $0.hasPrefix(KanbanReminderPlanner.identifierPrefix) && !desiredIDs.contains($0) }

        client.remove(staleKanban)

        for reminder in desired {
            do {
                try await client.add(reminder)
            } catch {
                NSLog("TickyTask: scheduling Kanban reminder \(reminder.identifier) failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private static func fetchKanbanCards(context: ModelContext) -> [KanbanReminderPlanner.CardSnapshot]? {
        do {
            let cards = try context.fetch(FetchDescriptor<KanbanTask>())
            return cards.compactMap { card in
                guard let column = card.column, let project = card.project else { return nil }
                let isDone = column.kind == .done
                let isArchivedCard = card.archivedAt != nil
                let isArchivedProject = project.archivedAt != nil

                return KanbanReminderPlanner.CardSnapshot(
                    id: card.id,
                    title: card.title,
                    projectName: project.name,
                    dueDate: card.dueDate,
                    isDone: isDone,
                    isArchivedCard: isArchivedCard,
                    isArchivedProject: isArchivedProject
                )
            }
        } catch {
            return nil
        }
    }

    /// Schedule (or clear) the daily end-of-day unfinished-tasks reminder.
    static func scheduleEndOfDayReminder(enabled: Bool, minutes: Int) async {
        guard !UITestSupport.isRunning, !UITestSupport.isHostingUnitTests else { return }
        center.removePendingNotificationRequests(withIdentifiers: [endOfDayIdentifier])
        guard enabled, await isAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Wrap up your day"
        content.body = "Check any unfinished tasks before the day ends."
        content.sound = .default

        var comps = DateComponents()
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        let request = UNNotificationRequest(
            identifier: endOfDayIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        )
        try? await center.add(request)
    }
}

/// One per-task reminder the store calls for. The identifier is the task UUID, so
/// re-adding a reminder replaces that task's pending request.
struct TaskReminder: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: DateComponents
}

/// Which tasks get a reminder: dated, timed, alarm-on, open, and in the future.
/// Pure, so the rules are unit-tested; a listed occurrence or a recurring series'
/// hidden definition has no date and therefore no reminder.
enum ReminderPlanner {
    static let identifierPrefix = "task."

    @MainActor
    static func reminders(for tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [TaskReminder] {
        tasks.compactMap { task in
            guard task.alarmEnabled, !task.isDone, task.recurrence == nil,
                  let key = task.dayKey, let minutes = task.timeMinutes,
                  let day = WeekMath.date(fromDayKey: key, calendar: calendar),
                  let fire = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day),
                  fire > now else { return nil }
            return TaskReminder(
                identifier: identifierPrefix + task.id.uuidString,
                title: task.title.isEmpty ? "Task reminder" : task.title,
                body: "Scheduled for \(String(format: "%02d:%02d", minutes / 60, minutes % 60))",
                fireDate: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire))
        }
    }
}

/// The notification-center surface reminder sync uses; tests substitute a fake.
@MainActor
protocol NotificationScheduling {
    func isAuthorized() async -> Bool
    func pendingIdentifiers() async -> [String]
    func remove(_ identifiers: [String])
    func add(_ reminder: TaskReminder) async throws
}

@MainActor
struct SystemNotificationClient: NotificationScheduling {
    private var center: UNUserNotificationCenter { .current() }

    func isAuthorized() async -> Bool {
        await center.notificationSettings().authorizationStatus == .authorized
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func remove(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(_ reminder: TaskReminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        try await center.add(UNNotificationRequest(
            identifier: reminder.identifier, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: reminder.fireDate, repeats: false)))
    }
}
