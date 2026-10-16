import Foundation
import SwiftData

/// A record about one scheduled slot of a recurring series, owned by its
/// definition. `skipped` marks a slot whose occurrence the user deleted, so it is
/// never regenerated. Releases before 0.1.13 computed occurrences virtually and
/// stored completion/title/time overrides here; `RecurrenceNormalizer` turns those
/// into real occurrences, and the fields are kept so old data round-trips.
@Model
final class TaskOccurrence {
    var id: UUID = UUID()
    /// `"yyyyMMdd"` of the scheduled slot (not where a moved occurrence now sits).
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
