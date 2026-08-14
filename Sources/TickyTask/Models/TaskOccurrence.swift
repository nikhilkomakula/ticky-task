import Foundation
import SwiftData

/// A per-occurrence override for a recurring task template.
///
/// The week view computes virtual occurrences from `TaskItem.recurrence`; only
/// when the user completes or edits a *specific* instance do we persist one of
/// these (keyed by `dayKey`). This avoids the legacy app's per-date
/// materialization (`repeating_events_by_date`) and keeps the store lean.
@Model
final class TaskOccurrence {
    var id: UUID = UUID()
    /// `"yyyyMMdd"` of the occurrence being overridden.
    var dayKey: String = ""
    var isDone: Bool = false
    /// The user removed this single occurrence from the series.
    var skipped: Bool = false
    var titleOverride: String?
    var timeOverride: Int?
    /// Owning template task. The inverse is declared on `TaskItem.occurrences`.
    var template: TaskItem?

    init(id: UUID = UUID(),
         dayKey: String,
         isDone: Bool = false,
         skipped: Bool = false,
         titleOverride: String? = nil,
         timeOverride: Int? = nil) {
        self.id = id
        self.dayKey = dayKey
        self.isDone = isDone
        self.skipped = skipped
        self.titleOverride = titleOverride
        self.timeOverride = timeOverride
    }
}
