import Foundation
import SwiftData

/// Kanban due-date reminders: a pure planner mirroring ReminderPlanner.
///
/// Given card snapshots and settings, computes the desired reminders. Reminders fire
/// on the card's due date at the specified minutes, for live open cards on non-archived
/// projects. Identifiers are prefixed `kanban.` to coexist with task reminders.
enum KanbanReminderPlanner {
    static let identifierPrefix = "kanban."

    /// Compute desired Kanban reminders from card snapshots.
    ///
    /// - Parameters:
    ///   - cards: Card snapshots with id, title, project name, due date, open/live flags.
    ///   - enabled: Whether Kanban due-date notifications are enabled.
    ///   - minutes: Minutes after midnight to fire (e.g., 9*60 = 9:00 AM).
    ///   - now: Current moment (for filtering future due dates).
    ///   - calendar: Calendar for date arithmetic.
    /// - Returns: Desired reminders as TaskReminder objects, deterministically ordered by card UUID.
    ///
    /// Filters for:
    /// - `enabled` is true.
    /// - Card is not done (`column.kind != .done`).
    /// - Card is not archived (`archivedAt == nil`).
    /// - Project is not archived (`project.archivedAt == nil`).
    /// - Card has a due date.
    /// - Fire date (due date at specified minutes) is in the future.
    @MainActor
    static func reminders(
        for cards: [CardSnapshot],
        enabled: Bool,
        minutes: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [TaskReminder] {
        guard enabled else { return [] }

        let reminders = cards.compactMap { card -> TaskReminder? in
            guard !card.isDone,
                  !card.isArchivedCard,
                  !card.isArchivedProject,
                  let due = card.dueDate else { return nil }

            let fireDate = calendar.date(
                bySettingHour: minutes / 60,
                minute: minutes % 60,
                second: 0,
                of: due
            ) ?? due

            guard fireDate > now else { return nil }

            let dateComponents = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )

            return TaskReminder(
                identifier: identifierPrefix + card.id.uuidString,
                title: card.title.isEmpty ? "Task reminder" : card.title,
                body: "Due \(card.projectName)",
                fireDate: dateComponents
            )
        }

        // Deterministic ordering by identifier string for stable diffs.
        return reminders.sorted { $0.identifier < $1.identifier }
    }

    /// Snapshot of a card's essential fields for reminder computation.
    struct CardSnapshot {
        let id: UUID
        let title: String
        let projectName: String
        let dueDate: Date?
        let isDone: Bool
        let isArchivedCard: Bool
        let isArchivedProject: Bool

        init(
            id: UUID,
            title: String,
            projectName: String,
            dueDate: Date?,
            isDone: Bool,
            isArchivedCard: Bool,
            isArchivedProject: Bool
        ) {
            self.id = id
            self.title = title
            self.projectName = projectName
            self.dueDate = dueDate
            self.isDone = isDone
            self.isArchivedCard = isArchivedCard
            self.isArchivedProject = isArchivedProject
        }
    }
}
