import Foundation
import SwiftData

/// A public holiday (design 04): one day for everyone on every board, not a working day.
/// `workedBy` lists the people (ids) who work it anyway.
@Model
final class KanbanHoliday {
    var id: UUID = UUID()
    var day: String = ""
    var name: String = ""
    var portionRaw: String = KanbanTimeOffPortion.full.rawValue
    var workedBy: [UUID]?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: UUID = UUID(), day: String, name: String, portion: KanbanTimeOffPortion = .full, workedBy: [UUID]? = nil) {
        self.id = id
        self.day = day
        self.name = name
        self.portionRaw = portion.rawValue
        self.workedBy = workedBy
    }

    var portion: KanbanTimeOffPortion { KanbanTimeOffPortion(rawValue: portionRaw) ?? .full }

    /// Sorted and unique, nil when nobody works it.
    static func normalized(_ people: [UUID]?) -> [UUID]? {
        let set = Set(people ?? [])
        return set.isEmpty ? nil : set.sorted { $0.uuidString < $1.uuidString }
    }
}
