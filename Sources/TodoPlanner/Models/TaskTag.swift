import Foundation
import SwiftData

/// A label that can be applied to many tasks (many-to-many).
///
/// Named `TaskTag` (not `Tag`) to avoid colliding with Swift Testing's `Tag`
/// type in test files.
@Model
final class TaskTag {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String?
    /// Tagged tasks. The relationship (and its inverse) is declared on
    /// `TaskItem.tags`.
    var tasks: [TaskItem] = []

    init(id: UUID = UUID(), name: String = "", colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}
