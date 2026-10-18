import Foundation
import SwiftData

/// Time a person is away (design 03). It belongs to the person, so it counts on every
/// board they're on. Days are `yyyyMMdd` keys, inclusive; a morning or afternoon covers a
/// single day.
@Model
final class KanbanTimeOff {
    var id: UUID = UUID()
    var person: KanbanPerson?
    var startDay: String = ""
    var endDay: String = ""
    var portionRaw: String = KanbanTimeOffPortion.full.rawValue
    var kindRaw: String = KanbanTimeOffKind.pto.rawValue
    var note: String?
    var originRaw: String = KanbanTimeOffOrigin.manual.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: UUID = UUID(), startDay: String, endDay: String, portion: KanbanTimeOffPortion = .full,
         kind: KanbanTimeOffKind = .pto, origin: KanbanTimeOffOrigin = .manual) {
        self.id = id
        self.startDay = startDay
        self.endDay = endDay
        self.portionRaw = portion.rawValue
        self.kindRaw = kind.rawValue
        self.originRaw = origin.rawValue
    }

    var portion: KanbanTimeOffPortion { KanbanTimeOffPortion(rawValue: portionRaw) ?? .full }
    var kind: KanbanTimeOffKind { KanbanTimeOffKind(rawValue: kindRaw) ?? .other }
}

enum KanbanTimeOffPortion: String, Codable, CaseIterable, Sendable {
    case full, am, pm

    var label: String {
        switch self {
        case .full: "Full day"
        case .am: "Morning"
        case .pm: "Afternoon"
        }
    }
}

/// Why someone is away. The kind doesn't change the arithmetic.
enum KanbanTimeOffKind: String, Codable, CaseIterable, Sendable {
    case pto, sick, personal, training, other

    var label: String {
        switch self {
        case .pto: "PTO"
        case .sick: "Sick"
        case .personal: "Personal"
        case .training: "Training"
        case .other: "Other"
        }
    }
}

enum KanbanTimeOffOrigin: String, Codable, Sendable {
    case manual, assistant
}
