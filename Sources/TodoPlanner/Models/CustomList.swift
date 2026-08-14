import Foundation
import SwiftData

/// A user-created, date-independent list (e.g. "Groceries", "Someday").
@Model
final class CustomList {
    var id: UUID = UUID()
    var name: String = ""
    var sortIndex: Double = 0

    /// Tasks in this list. Deleting the list cascades to its tasks.
    @Relationship(deleteRule: .cascade, inverse: \TaskItem.customList)
    var tasks: [TaskItem] = []

    init(id: UUID = UUID(), name: String = "", sortIndex: Double = 0) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
    }
}
