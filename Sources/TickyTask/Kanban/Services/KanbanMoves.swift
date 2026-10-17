import Foundation

// MARK: - Move Operations

/// A target for a move operation.
enum MoveTarget: Equatable, Sendable {
    /// Drop into a specific cell before a given card (nil = append).
    case cell(columnID: UUID, row: KanbanRowKey, beforeCardID: UUID?)
    /// Drop onto a column header (row kept, appended to column).
    case columnHeader(UUID)
    /// Drop onto a row header (column kept, appended to row).
    case rowHeader(KanbanRowKey)
}

/// A move operation describing what to move and where.
enum MoveOp: Equatable, Sendable {
    /// Move card IDs to a target.
    case cards([UUID], to: MoveTarget)
    /// Reorder columns by moving one to a given index in the column list.
    case reorderColumn(UUID, toIndex: Int)
    /// Reorder rows by moving a resource to a given index (Unassigned is pinned at 0).
    case reorderRow(UUID, toIndex: Int)
}

// MARK: - Move Planning Results

/// A card's placement: where it is and when it was completed.
struct Placement: Equatable, Sendable {
    let columnID: UUID
    let row: KanbanRowKey
    let sortIndex: Double
    let completedAt: Date?
}

/// The change for one card: from and to placement.
struct CardChange: Equatable, Sendable {
    let id: UUID
    let from: Placement
    let to: Placement
}

/// WIP outcome for a move: ok, warn with affected columns, or blocked with affected columns.
enum WIPOutcome: Equatable, Sendable {
    case ok
    case warn([UUID])
    case blocked([UUID])
}

/// The result of planning a move: what cards change, what column/row orders change, and WIP status.
struct MovePlan: Equatable, Sendable {
    let cardChanges: [CardChange]
    let columnOrder: [UUID]?
    let rowOrder: [UUID]?
    let wip: WIPOutcome
    let isNoOp: Bool
}

// MARK: - Move Planner

/// Pure move planning (design 01 §2.1, §4): turns a drag, keyboard command or bulk
/// action into the exact placements `KanbanService` applies in one save.
nonisolated enum KanbanMoves {
    static func plan(_ op: MoveOp, in snapshot: BoardSnapshot, now: Date) -> MovePlan {
        switch op {
        case let .cards(ids, target): return planCards(ids, to: target, in: snapshot, now: now)
        case let .reorderColumn(id, index): return planColumnReorder(id, toIndex: index, in: snapshot)
        case let .reorderRow(id, index): return planRowReorder(id, toIndex: index, in: snapshot)
        }
    }

    private static let noOp = MovePlan(cardChanges: [], columnOrder: nil, rowOrder: nil, wip: .ok, isNoOp: true)

    private struct Cell: Hashable { let column: UUID; let row: KanbanRowKey }

    // MARK: Cards

    private static func planCards(_ ids: [UUID], to target: MoveTarget, in s: BoardSnapshot, now: Date) -> MovePlan {
        let live = s.cards.filter { !$0.archived }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let columnIndex = Dictionary(s.columns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rowIndex = Dictionary(s.rows.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        let moving = Set(ids)
        guard !ids.isEmpty, ids.allSatisfy({ byID[$0] != nil }) else { return noOp }

        // The selection keeps its relative order: column order, then row order, then position.
        let selection = ids.compactMap { byID[$0] }.sorted {
            (columnIndex[$0.columnID] ?? .max, rowIndex[$0.row] ?? .max, $0.sortIndex)
                < (columnIndex[$1.columnID] ?? .max, rowIndex[$1.row] ?? .max, $1.sortIndex)
        }

        // Where each selected card goes: a cell sets both; a header changes only one axis.
        func destination(of card: CardSnapshot) -> Cell? {
            switch target {
            case let .cell(column, row, _): return Cell(column: column, row: row)
            case let .columnHeader(column): return Cell(column: column, row: card.row)
            case let .rowHeader(row): return Cell(column: card.columnID, row: row)
            }
        }
        var destinations: [UUID: Cell] = [:]
        for card in selection {
            guard let cell = destination(of: card), columnIndex[cell.column] != nil, rowIndex[cell.row] != nil else { return noOp }
            destinations[card.id] = cell
        }

        // Every cell's cards after the move: the cards that stay, in order, plus the selection
        // inserted before the indicator (cell drops) or appended (header drops).
        var cells: [Cell: [CardSnapshot]] = [:]
        for card in live.sorted(by: { $0.sortIndex < $1.sortIndex }) where !moving.contains(card.id) {
            cells[Cell(column: card.columnID, row: card.row), default: []].append(card)
        }
        let affected = Set(selection.map { Cell(column: $0.columnID, row: $0.row) } + destinations.values)
        var incoming: [Cell: [CardSnapshot]] = [:]
        for card in selection { incoming[destinations[card.id]!, default: []].append(card) }
        for (cell, cards) in incoming {
            var list = cells[cell] ?? []
            var index = list.count
            if case let .cell(_, _, before?) = target, let found = list.firstIndex(where: { $0.id == before }) { index = found }
            list.insert(contentsOf: cards, at: index)
            cells[cell] = list
        }

        // Dense re-derivation of every affected cell, with completion transitions for movers.
        var changes: [CardChange] = []
        for cell in affected.sorted(by: { (columnIndex[$0.column]!, rowIndex[$0.row]!) < (columnIndex[$1.column]!, rowIndex[$1.row]!) }) {
            for (position, card) in (cells[cell] ?? []).enumerated() {
                let completedAt: Date?
                if moving.contains(card.id) {
                    let from = s.column(id: card.columnID)?.kind, to = s.column(id: cell.column)?.kind
                    completedAt = to == .done ? (from == .done ? card.completedAt : now) : nil
                } else {
                    completedAt = card.completedAt
                }
                let before = Placement(columnID: card.columnID, row: card.row, sortIndex: card.sortIndex, completedAt: card.completedAt)
                let after = Placement(columnID: cell.column, row: cell.row, sortIndex: Double(position), completedAt: completedAt)
                if before != after { changes.append(CardChange(id: card.id, from: before, to: after)) }
            }
        }

        // WIP counts a whole column (all rows), and only columns gaining cards from elsewhere.
        var over: [UUID] = []
        for column in s.columns where column.wipLimit != nil {
            let gains = selection.contains { $0.columnID != column.id && destinations[$0.id]?.column == column.id }
            guard gains else { continue }
            let count = cells.filter { $0.key.column == column.id }.reduce(0) { $0 + $1.value.count }
            if count > column.wipLimit! { over.append(column.id) }
        }
        if !over.isEmpty, s.wipPolicy == .block {
            return MovePlan(cardChanges: [], columnOrder: nil, rowOrder: nil, wip: .blocked(over), isNoOp: true)
        }
        return MovePlan(cardChanges: changes, columnOrder: nil, rowOrder: nil,
                        wip: over.isEmpty ? .ok : .warn(over), isNoOp: changes.isEmpty)
    }

    // MARK: Columns and rows

    private static func planColumnReorder(_ id: UUID, toIndex: Int, in s: BoardSnapshot) -> MovePlan {
        var order = s.columns.map(\.id)
        guard let from = order.firstIndex(of: id), order.indices.contains(toIndex), from != toIndex else { return noOp }
        order.insert(order.remove(at: from), at: toIndex)
        return MovePlan(cardChanges: [], columnOrder: order, rowOrder: nil, wip: .ok, isNoOp: false)
    }

    /// Reorders resource rows; Unassigned is pinned above them and never moves.
    private static func planRowReorder(_ resourceID: UUID, toIndex: Int, in s: BoardSnapshot) -> MovePlan {
        var order = s.rows.sorted { $0.sortIndex < $1.sortIndex }.compactMap { row -> UUID? in
            if case let .resource(id) = row.key { return id } else { return nil }
        }
        guard let from = order.firstIndex(of: resourceID), order.indices.contains(toIndex), from != toIndex else { return noOp }
        order.insert(order.remove(at: from), at: toIndex)
        return MovePlan(cardChanges: [], columnOrder: nil, rowOrder: order, wip: .ok, isNoOp: false)
    }
}
