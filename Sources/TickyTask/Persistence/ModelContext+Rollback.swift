import Foundation
import SwiftData

extension ModelContext {
    /// Discard pending changes and make the objects already in memory show the saved
    /// state again. `rollback()` alone drops the changes but leaves loaded objects
    /// holding the discarded values until they are fetched again — so a failed save
    /// would keep showing (and later re-save) edits that never committed.
    func rollbackAndRefresh() {
        rollback()
        _ = try? fetch(FetchDescriptor<TaskItem>())
        _ = try? fetch(FetchDescriptor<Subtask>())
        _ = try? fetch(FetchDescriptor<TaskOccurrence>())
        _ = try? fetch(FetchDescriptor<TaskTag>())
        _ = try? fetch(FetchDescriptor<CustomList>())
    }
}

extension ModelContext {
    /// Save the end of a transaction (the step `rollbackAndRefresh()` undoes on
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
    enum Point { case checkpoint, transaction }
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
