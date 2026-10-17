import Foundation

/// What a change-log entry did (design 01 §2.3). Stored as `KanbanActivity.kindRaw`.
enum KanbanActivityKind: String, Codable, Sendable {
    case created, moved, edited, archived, restored, deleted, restoredGraph, structure, memberArchived, scheduled
}

/// A scalar value of an edited field, so edits can be replayed, reverted and conflict-checked.
enum KanbanValue: Codable, Equatable, Sendable {
    case string(String), int(Int), double(Double), bool(Bool), date(Date), uuid(UUID), data(Data), uuids([UUID])
}

/// The kind of row an edit touched.
enum KanbanEntity: String, Codable, Sendable {
    case project, column, resource, task, subtask, label
}

/// One field's change. `old` and `new` are `nil` for an absent optional.
struct KanbanFieldChange: Codable, Equatable, Sendable {
    var entity: KanbanEntity
    var id: UUID
    var field: String
    var old: KanbanValue?
    var new: KanbanValue?
}

/// Where a card was, with a snapshot of its column so replay survives deleted columns.
struct KanbanPlacementRecord: Codable, Equatable, Sendable {
    var columnID: UUID
    var columnName: String
    var columnKind: String
    var resourceID: UUID?
    var sortIndex: Double
    var completedAt: Date?
}

/// A card's move, from and to. Revert checks that the card is still at `to`.
struct KanbanTransition: Codable, Equatable, Sendable {
    var taskID: UUID
    var from: KanbanPlacementRecord
    var to: KanbanPlacementRecord
}

/// Rows removed by a destructive action, enough to put them back.
struct KanbanRemovedGraph: Codable, Equatable, Sendable {
    var columns: [KanbanColumnDTO] = []
    var resources: [KanbanResourceDTO] = []
    var labels: [KanbanLabelDTO] = []
    var tasks: [KanbanTaskDTO] = []
    var subtasks: [KanbanSubtaskDTO] = []
    /// Dependency edges `[dependent, prerequisite]` that pointed at a removed task from a kept one.
    var incomingDependencies: [[UUID]] = []
}

/// The versioned payload of one change-log entry: per-row transitions with their
/// expected values, so it can be replayed (dashboards) and reverted with conflict checks.
struct KanbanActivityPayload: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    /// Moves, including those caused by deleting a column or archiving a membership.
    var transitions: [KanbanTransition] = []
    /// Field edits (tasks, columns, memberships, labels, subtasks, the project).
    var changes: [KanbanFieldChange] = []
    /// Rows removed (delete) or inserted (create, restoredGraph).
    var graph: KanbanRemovedGraph?
    /// Groups the per-board entries of one cross-board action (a person archive).
    var groupID: UUID?
    /// `scheduled`: the planner task and day.
    var plannerTaskID: UUID?
    var dayKey: String?

    func encoded() throws -> Data { try JSONEncoder.kanbanPayload.encode(self) }
    static func decode(_ data: Data) throws -> KanbanActivityPayload { try JSONDecoder.kanbanPayload.decode(Self.self, from: data) }
}

// Payload dates use the default (seconds as a Double), which round-trips exactly:
// conflict checks compare them with live values, so millisecond ISO dates won't do.
extension JSONEncoder {
    static var kanbanPayload: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var kanbanPayload: JSONDecoder { JSONDecoder() }
}
