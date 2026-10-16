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
