import CoreGraphics
import Foundation

/// What's being dragged on a board.
enum BoardDragSource: Equatable, Sendable {
    case cards([UUID])
    case column(UUID)
    case row(UUID)          // a membership; Unassigned can't be dragged
}

/// Where a drop would land (design 01 §4).
enum BoardDropTarget: Equatable, Sendable {
    case cell(columnID: UUID, row: KanbanRowKey, beforeCardID: UUID?)
    case columnHeader(UUID)
    case rowHeader(KanbanRowKey)
    /// The dragged column's index in the final column order.
    case columnSlot(Int)
    /// The dragged row's index among the membership rows (Unassigned stays first).
    case rowSlot(Int)
}

/// Board element frames in global coordinates, as published by the views.
struct BoardFrames: Equatable, Sendable {
    struct Card: Equatable, Sendable { var id: UUID; var columnID: UUID; var row: KanbanRowKey; var frame: CGRect }
    struct Cell: Equatable, Sendable { var columnID: UUID; var row: KanbanRowKey; var frame: CGRect }
    struct ColumnHeader: Equatable, Sendable { var id: UUID; var frame: CGRect }
    struct RowHeader: Equatable, Sendable {
        var row: KanbanRowKey
        var frame: CGRect
        /// A collapsed row's counts strip: a drop target like its header, but not a reorder slot.
        var isSummary = false
    }

    var cards: [Card] = []
    var cells: [Cell] = []
    var columnHeaders: [ColumnHeader] = []
    var rowHeaders: [RowHeader] = []
    /// The visible board, for auto-scroll and to ignore clipped content.
    var viewport: CGRect = .zero
    /// Every membership row in board order, including rows the lazy grid hasn't drawn.
    var rowOrder: [UUID] = []
    /// The pinned top-left corner, which covers whatever scrolls under it.
    var corner: CGRect = .zero
}

/// Pure drop resolution, unit-tested without any UI (design 01 §4).
enum BoardGeometry {
    /// The drop target under `pointer`, or nil over nothing that accepts the drag.
    /// For cards, header zones win over cells; inside a cell the insertion point follows
    /// the planner's midpoint rule (drop on a card's lower half to land after it).
    static func resolve(pointer: CGPoint, source: BoardDragSource, frames: BoardFrames) -> BoardDropTarget? {
        guard frames.viewport.contains(pointer) else { return nil }
        switch source {
        case let .cards(ids):
            let dragged = Set(ids)
            if frames.corner.contains(pointer) { return nil }
            // In stacking order: the pinned column headers (and the corner) sit above the rows,
            // the pinned row headers above the cells, so whatever the pointer sees wins.
            let headerBottom = frames.columnHeaders.map(\.frame.maxY).max() ?? -.infinity
            if pointer.y <= headerBottom {
                return frames.columnHeaders.first { $0.frame.contains(pointer) }.map { .columnHeader($0.id) }
            }
            if let header = frames.rowHeaders.first(where: { !$0.isSummary && $0.frame.contains(pointer) }) { return .rowHeader(header.row) }
            if let strip = frames.rowHeaders.first(where: { $0.isSummary && $0.frame.contains(pointer) }) { return .rowHeader(strip.row) }
            guard let cell = frames.cells.first(where: { $0.frame.contains(pointer) }) else { return nil }
            let siblings = frames.cards
                .filter { $0.columnID == cell.columnID && $0.row == cell.row && !dragged.contains($0.id) }
                .sorted { $0.frame.minY < $1.frame.minY }
            let before = siblings.first { pointer.y < $0.frame.midY }?.id
            return .cell(columnID: cell.columnID, row: cell.row, beforeCardID: before)
        case let .column(id):
            // Anywhere over the board: the slot follows the pointer across the columns.
            return .columnSlot(frames.columnHeaders.filter { $0.id != id && $0.frame.midX < pointer.x }.count)
        case let .row(id):
            // The lazy grid only draws some rows, so place the row relative to a visible one
            // and count its index in the complete order.
            let order = frames.rowOrder.filter { $0 != id }
            let visible = frames.rowHeaders.compactMap { header -> (id: UUID, frame: CGRect)? in
                guard !header.isSummary, let rid = header.row.resourceID, rid != id else { return nil }
                return (rid, header.frame)
            }.sorted { $0.frame.minY < $1.frame.minY }
            if let before = visible.first(where: { pointer.y < $0.frame.midY }), let index = order.firstIndex(of: before.id) {
                return .rowSlot(index)
            }
            if let last = visible.last, let index = order.firstIndex(of: last.id) { return .rowSlot(index + 1) }
            return nil
        }
    }

    /// The service operation for a drop.
    static func operation(source: BoardDragSource, target: BoardDropTarget) -> MoveOp? {
        switch (source, target) {
        case let (.cards(ids), .cell(column, row, before)): .cards(ids, to: .cell(columnID: column, row: row, beforeCardID: before))
        case let (.cards(ids), .columnHeader(column)): .cards(ids, to: .columnHeader(column))
        case let (.cards(ids), .rowHeader(row)): .cards(ids, to: .rowHeader(row))
        case let (.column(id), .columnSlot(index)): .reorderColumn(id, toIndex: index)
        case let (.row(id), .rowSlot(index)): .reorderRow(id, toIndex: index)
        default: nil
        }
    }

    /// Within 40 pt of the viewport's edge the board scrolls toward it, faster nearer the
    /// edge; returns the per-tick scroll delta (zero when the pointer is well inside).
    static func autoScrollDelta(pointer: CGPoint, viewport: CGRect, edge: CGFloat = 40, maxStep: CGFloat = 18) -> CGVector {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        func step(_ distanceIn: CGFloat) -> CGFloat { distanceIn < edge ? maxStep * (1 - max(distanceIn, 0) / edge) : 0 }
        let dx = step(pointer.x - viewport.minX) > 0 ? -step(pointer.x - viewport.minX) : step(viewport.maxX - pointer.x)
        let dy = step(pointer.y - viewport.minY) > 0 ? -step(pointer.y - viewport.minY) : step(viewport.maxY - pointer.y)
        return CGVector(dx: dx, dy: dy)
    }
}
