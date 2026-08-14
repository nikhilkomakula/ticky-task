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
    private static let endOfDayIdentifier = "todoplanner.endOfDay"
    private static let taskPrefix = "task."

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func isAuthorized() async -> Bool {
        await center.notificationSettings().authorizationStatus == .authorized
    }

    private static func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Rebuild all per-task reminders for future, alarm-enabled, unfinished tasks.
    @MainActor
    static func syncTaskReminders(context: ModelContext) async {
        guard await isAuthorized() else { return }

        let pending = await center.pendingNotificationRequests()
        let staleTaskIDs = pending.map(\.identifier).filter { $0.hasPrefix(taskPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: staleTaskIDs)

        let all = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        let now = Date()
        for task in all {
            guard task.alarmEnabled, !task.isDone,
                  let key = task.dayKey, let minutes = task.timeMinutes,
                  let day = WeekMath.date(fromDayKey: key),
                  let fire = Calendar.current.date(bySettingHour: minutes / 60,
                                                   minute: minutes % 60, second: 0, of: day),
                  fire > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = task.title.isEmpty ? "Task reminder" : task.title
            content.body = "Scheduled for \(timeLabel(minutes))"
            content.sound = .default

            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let request = UNNotificationRequest(
                identifier: "\(taskPrefix)\(task.id.uuidString)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )
            try? await center.add(request)
        }
    }

    /// Schedule (or clear) the daily end-of-day unfinished-tasks reminder.
    static func scheduleEndOfDayReminder(enabled: Bool, minutes: Int) async {
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
