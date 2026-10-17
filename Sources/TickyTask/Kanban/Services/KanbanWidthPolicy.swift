import Foundation

/// The Board view's resizable widths: the board sidebar (per Mac), the People column and each
/// status column (per board, in its view state).
struct KanbanWidthPolicy: Sendable {
    let defaultWidth: Double
    let range: ClosedRange<Double>

    static let sidebar = KanbanWidthPolicy(defaultWidth: 230, range: 180...360)
    static let rowHeader = KanbanWidthPolicy(defaultWidth: 230, range: 160...400)
    static let column = KanbanWidthPolicy(defaultWidth: 250, range: 180...480)
    static let sidebarKey = "kanban.sidebarWidth"

    func clamp(_ width: Double) -> Double { min(max(width, range.lowerBound), range.upperBound) }
}

/// The widths one board is drawn with.
struct KanbanBoardWidths: Equatable {
    var rowHeader: CGFloat
    var columns: [UUID: CGFloat]

    init(_ state: KanbanBoardState) {
        rowHeader = CGFloat(state.rowHeaderWidth ?? KanbanWidthPolicy.rowHeader.defaultWidth)
        columns = Dictionary(uniqueKeysWithValues: (state.columnWidths ?? [:]).compactMap { key, width in
            UUID(uuidString: key).map { ($0, CGFloat(width)) }
        })
    }

    func column(_ id: UUID) -> CGFloat { columns[id] ?? CGFloat(KanbanWidthPolicy.column.defaultWidth) }
}

extension KanbanBoardState {
    /// Sets (or, with nil, resets) one column's width, dropping widths of columns that are gone.
    mutating func setColumnWidth(_ width: Double?, for column: UUID, keeping columns: [UUID]) {
        let live = Set(columns.map(\.uuidString))
        var widths = (columnWidths ?? [:]).filter { live.contains($0.key) }
        widths[column.uuidString] = width.map(KanbanWidthPolicy.column.clamp)
        columnWidths = widths.isEmpty ? nil : widths
    }

    mutating func setRowHeaderWidth(_ width: Double?) {
        rowHeaderWidth = width.map(KanbanWidthPolicy.rowHeader.clamp)
    }
}
