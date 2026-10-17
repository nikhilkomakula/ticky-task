import Foundation
import SwiftData

/// A per-project card label (Feature, Bug, …).
@Model
final class KanbanLabel {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#8E8E93"
    var symbolName: String?
    var sortIndex: Double = 0
    /// Owning project; the inverse is declared on `KanbanProject.labels`.
    var project: KanbanProject?
    var tasks: [KanbanTask] = []

    init(id: UUID = UUID(), name: String = "", colorHex: String = "#8E8E93", sortIndex: Double = 0) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortIndex = sortIndex
    }
}
