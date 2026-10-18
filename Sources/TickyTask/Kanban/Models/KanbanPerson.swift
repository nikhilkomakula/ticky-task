import Foundation
import SwiftData

/// Someone in the app-wide people directory. Who they are lives here; how much
/// they work on each board lives on their `KanbanResource` memberships.
@Model
final class KanbanPerson {
    var id: UUID = UUID()
    var name: String = ""
    var initials: String = ""
    var colorHex: String?
    var employmentRaw: String = KanbanEmployment.fte.rawValue
    var skills: [String] = []
    var createdAt: Date = Date()
    var archivedAt: Date?
    /// Board memberships. Nullify rather than `.deny` (unreliable at runtime);
    /// `KanbanService` refuses to delete a person while any membership exists.
    @Relationship(deleteRule: .nullify, inverse: \KanbanResource.person) var memberships: [KanbanResource] = []
    /// Time off, on every board. Deleted with the person.
    @Relationship(deleteRule: .cascade, inverse: \KanbanTimeOff.person) var timeOff: [KanbanTimeOff] = []
    /// Other names the availability assistant matched to this person (added only when the
    /// user chose to remember one).
    var aliases: [String]?

    init(id: UUID = UUID(), name: String = "", initials: String = "", employment: KanbanEmployment = .fte) {
        self.id = id
        self.name = name
        self.initials = initials
        self.employmentRaw = employment.rawValue
    }

    var employment: KanbanEmployment {
        get { KanbanEmployment(rawValue: employmentRaw) ?? .fte }
        set { employmentRaw = newValue.rawValue }
    }
}
