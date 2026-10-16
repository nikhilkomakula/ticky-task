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
        guard enabled, days >= 1, !PersistenceRecovery.didRelaunch else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }

        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isDone })
        guard let completed = try? context.fetch(descriptor) else { return }

        do {
            try RecurrenceMaterializer.checkpoint(context)
        } catch {
            NSLog("TickyTask: auto-delete skipped, saving pending edits failed: \(error.localizedDescription)")
            return
        }
        var deletedAny = false
        do {
            let purge = completed.filter { task in
                guard task.recurrence == nil, let completedAt = task.completedAt, completedAt < cutoff else { return false }
                return task.templateID == nil || task.occurrenceKey != nil   // keyless legacy occurrences are kept
            }
            for task in purge where task.templateID != nil {
                try RecurrenceMaterializer.skipSlot(of: task, context: context)
            }
            for task in purge {
                context.delete(task)
                deletedAny = true
            }
            // Roll back on failure so the deletions don't linger uncommitted in the
            // context (where an unrelated later save could commit them silently).
            #if DEBUG
            if UITestSupport.failPurgeSaves { PersistenceFaults.armed.insert(.transaction) }
            #endif
            if deletedAny { try context.saveTransaction() }
        } catch {
            context.undoFailedTransaction()
        }
    }
}
