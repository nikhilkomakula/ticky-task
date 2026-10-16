import Foundation
import SwiftData

/// Optionally deletes tasks that were completed more than a chosen number of days
/// ago (Settings › Behavior). Opt-in and **off by default** — when disabled,
/// completed tasks stay untouched. Based on `TaskItem.completedAt`, so tasks
/// completed before this feature existed (a `nil` timestamp) are never removed
/// until they're completed again. A recurring occurrence's slot is skipped before
/// it is purged so it never regenerates; series definitions are never purged, and
/// legacy occurrences whose slot is unknown are kept.
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
        do {
            try RecurrenceMaterializer.checkpoint(context)
            for task in completed where task.recurrence == nil {
                guard let completedAt = task.completedAt, completedAt < cutoff else { continue }
                if task.templateID != nil {
                    guard task.occurrenceKey != nil else { continue }
                    try RecurrenceMaterializer.skipSlot(of: task, context: context)
                }
                context.delete(task)
                deletedAny = true
            }
            // Roll back on failure so the deletions don't linger uncommitted in the
            // context (where an unrelated later save could commit them silently).
            if deletedAny { try context.save() }
        } catch {
            context.rollbackAndRefresh()
        }
    }
}
