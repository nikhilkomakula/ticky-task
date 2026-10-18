import Foundation
import SwiftData

// MARK: - Snapshot Types

/// The row key: either unassigned or a resource ID.
enum KanbanRowKey: Equatable, Hashable, Sendable {
    case unassigned
    case resource(UUID)

    /// Storage key used in `collapsedRowKeys`.
    var storageKey: String {
        switch self {
        case .unassigned:
            return "unassigned"
        case .resource(let id):
            return id.uuidString
        }
    }

    static func from(storageKey: String) -> KanbanRowKey? {
        if storageKey == "unassigned" {
            return .unassigned
        }
        guard let uuid = UUID(uuidString: storageKey) else { return nil }
        return .resource(uuid)
    }
}

/// A snapshot of a board column for move planning.
struct ColumnSnapshot: Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: KanbanColumnKind
    let sortIndex: Double
    let wipLimit: Int?
}

/// A snapshot of a board row (resource or unassigned).
struct KanbanRowSnapshot: Equatable, Sendable {
    let key: KanbanRowKey
    let resourceID: UUID?
    let personID: UUID?
    let name: String
    let sortIndex: Double
    let archived: Bool
}

/// A snapshot of a board card for move planning.
struct CardSnapshot: Equatable, Sendable {
    let id: UUID
    let columnID: UUID
    let row: KanbanRowKey
    let sortIndex: Double
    let completedAt: Date?
    let archived: Bool
    let priority: Int
    let isCritical: Bool
    let dueDate: Date?
    let startDate: Date?
    let estimateHours: Double?
    let isBlocked: Bool
}

/// A point-in-time read of a board's structure and cards for move planning.
/// All card changes and re-derivations stay within this snapshot's logical frame.
struct BoardSnapshot: Equatable, Sendable {
    let projectID: UUID
    let wipPolicy: KanbanWIPPolicy
    let columns: [ColumnSnapshot]
    let rows: [KanbanRowSnapshot]
    let cards: [CardSnapshot]
    /// Pre-indexed cards by (columnID, row) for O(1) lookup performance.
    private let cardsByLocation: [String: [CardSnapshot]]

    init(projectID: UUID, wipPolicy: KanbanWIPPolicy, columns: [ColumnSnapshot], rows: [KanbanRowSnapshot], cards: [CardSnapshot]) {
        self.projectID = projectID
        self.wipPolicy = wipPolicy
        self.columns = columns
        self.rows = rows
        self.cards = cards

        // Pre-build the location index for O(1) lookups
        var index: [String: [CardSnapshot]] = [:]
        for card in cards {
            let key = "\(card.columnID.uuidString):\(card.row.storageKey)"
            if index[key] == nil {
                index[key] = []
            }
            index[key]?.append(card)
        }
        // Sort each cell's cards by sortIndex
        for key in index.keys {
            index[key]?.sort { $0.sortIndex < $1.sortIndex }
        }
        self.cardsByLocation = index
    }

    /// Fetches cards in a given column and row, sorted by sortIndex.
    func cards(in columnID: UUID, row: KanbanRowKey) -> [CardSnapshot] {
        let key = "\(columnID.uuidString):\(row.storageKey)"
        return cardsByLocation[key] ?? []
    }

    /// Fetches a column by its ID, or nil if not found.
    func column(id: UUID) -> ColumnSnapshot? {
        columns.first { $0.id == id }
    }

    /// Builds a snapshot from a live KanbanProject. Excludes archived cards and rows
    /// unless `includeArchived` is true.
    @MainActor
    /// `includeArchivedRows` defaults to `includeArchived`; Show Archived on a board shows
    /// archived cards but keeps rows to active memberships (cards of archived ones show as Unassigned).
    static func make(project: KanbanProject, includeArchived: Bool = false, includeArchivedRows: Bool? = nil) -> BoardSnapshot {
        let includeArchivedRows = includeArchivedRows ?? includeArchived
        let columns = project.orderedColumns.map { col in
            ColumnSnapshot(
                id: col.id,
                name: col.name,
                kind: col.kind,
                sortIndex: col.sortIndex,
                wipLimit: col.wipLimit
            )
        }

        var rows: [KanbanRowSnapshot] = []

        // Unassigned row (always first, not affected by archive).
        rows.append(KanbanRowSnapshot(
            key: .unassigned,
            resourceID: nil,
            personID: nil,
            name: "Unassigned",
            sortIndex: -1,
            archived: false
        ))

        // Resource rows, sorted by sortIndex.
        let sortedResources = project.resources.sorted { $0.sortIndex < $1.sortIndex }
        for res in sortedResources {
            let shouldInclude = includeArchivedRows || res.archivedAt == nil
            if shouldInclude {
                rows.append(KanbanRowSnapshot(
                    key: .resource(res.id),
                    resourceID: res.id,
                    personID: res.person?.id,
                    name: res.displayName,
                    sortIndex: res.sortIndex,
                    archived: res.archivedAt != nil
                ))
            }
        }

        // Cards, excluding archived unless requested.
        // Pre-build a set of row keys for O(1) membership checks (instead of O(rows) per card).
        let rowKeys = Set(rows.map(\.key))
        let cardSnapshots = project.tasks
            .filter { includeArchived || $0.archivedAt == nil }
            .map { task in
                CardSnapshot(
                    id: task.id,
                    columnID: task.column?.id ?? UUID(),
                    // A card whose membership isn't a row here (archived) shows as Unassigned.
                    row: task.resource.flatMap { r in rowKeys.contains(.resource(r.id)) ? .resource(r.id) : nil } ?? .unassigned,
                    sortIndex: task.sortIndex,
                    completedAt: task.completedAt,
                    archived: task.archivedAt != nil,
                    priority: task.priority,
                    isCritical: task.isCritical,
                    dueDate: task.dueDate,
                    startDate: task.startDate,
                    estimateHours: task.estimateHours,
                    isBlocked: task.isBlocked
                )
            }

        return BoardSnapshot(
            projectID: project.id,
            wipPolicy: project.wipPolicy,
            columns: columns,
            rows: rows,
            cards: cardSnapshots
        )  // Custom init pre-builds cardsByLocation
    }
}
