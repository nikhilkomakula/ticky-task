import Foundation
import SwiftData

/// One membership's available days for one week (Monday `weekStart`), replacing what time
/// off works out. Stored in half days. At most one per membership and week, enforced by
/// `KanbanService`.
@Model
final class KanbanAvailabilityOverride {
    var id: UUID = UUID()
    var resource: KanbanResource?
    var weekStart: String = ""
    var halfDays: Int = 0
    var note: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: UUID = UUID(), weekStart: String, halfDays: Int) {
        self.id = id
        self.weekStart = weekStart
        self.halfDays = halfDays
    }
}
