import Foundation
import SwiftData

extension ModelContext {
    /// Undo a failed transaction and make loaded objects show the saved state again
    /// (`rollback()` alone leaves them holding the discarded values until refetched).
    ///
    /// SwiftData crashes when `rollback()` has to undo a deletion — reproduced with any
    /// deleted task that has subtasks — so transactions do every step that can fail
    /// before deleting anything. If only the final save fails with deletions pending,
    /// the complete change is kept and committed by the next save instead of undone.
    func undoFailedTransaction() {
        guard deletedModelsArray.isEmpty else {
            NSLog("TickyTask: a save failed; keeping the complete change for the next save (it can't be safely undone)")
            return
        }
        rollback()
        _ = try? fetch(FetchDescriptor<TaskItem>())
        _ = try? fetch(FetchDescriptor<Subtask>())
        _ = try? fetch(FetchDescriptor<TaskOccurrence>())
        _ = try? fetch(FetchDescriptor<TaskTag>())
        _ = try? fetch(FetchDescriptor<CustomList>())
    }
}

extension ModelContext {
    /// Save the end of a transaction (the step `undoFailedTransaction()` undoes on
    /// failure). Tests can make it fail through `PersistenceFaults`.
    @MainActor
    func saveTransaction() throws {
        try PersistenceFaults.check(.transaction)
        try save()
    }
}

/// Test-only failure injection for transactional saves and the checkpoint that
/// precedes them; compiled out of Release builds.
@MainActor
enum PersistenceFaults {
    enum Point { case checkpoint, transaction, reminderFetch, seriesFetch }
    struct InjectedFailure: Error {}

    #if DEBUG
    /// The points that fail on their next use (each fires once).
    static var armed: Set<Point> = []
    #endif

    static func check(_ point: Point) throws {
        #if DEBUG
        if armed.remove(point) != nil { throw InjectedFailure() }
        #endif
    }
}
