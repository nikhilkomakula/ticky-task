import Foundation
import SwiftData

/// Optionally deletes tasks that were completed more than a chosen number of days
/// ago (Settings › Behavior). Opt-in and **off by default** — when disabled,
/// completed tasks stay untouched. Based on `TaskItem.completedAt`, so tasks
/// completed before this feature existed (a `nil` timestamp) are never removed
/// until they're completed again, and recurring templates are always kept.
enum AutoDeleteService {
    @MainActor
    static func purgeCompleted(context: ModelContext,
                               enabled: Bool,
                               olderThanDays days: Int,
                               now: Date = Date()) {
        guard enabled, days >= 1 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }

        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isDone })
        guard let completed = try? context.fetch(descriptor) else { return }

        var deletedAny = false
        for task in completed where task.recurrence == nil {
            if let completedAt = task.completedAt, completedAt < cutoff {
                context.delete(task)
                deletedAny = true
            }
        }
        if deletedAny {
            // Roll back on save failure so the deletions don't linger uncommitted in
            // the context (where an unrelated later save could commit them silently).
            do { try context.save() } catch { context.rollback() }
        }
    }
}
