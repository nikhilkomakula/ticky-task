import CoreGraphics

/// Keeps the first visible card in place as estimated cell heights settle.
enum BoardScrollAnchor {
    /// Positive adjustments increase the vertical scroll offset. Content translations
    /// are excluded so ordinary scrolling never produces another scroll correction.
    static func verticalAdjustment(from old: BoardFrames, to new: BoardFrames) -> CGFloat {
        guard old.rowOrder == new.rowOrder else { return 0 }
        let top = max(max(old.viewport.minY, old.corner.maxY),
                      old.columnHeaders.map(\.frame.maxY).max() ?? old.viewport.minY)
        let leading = max(max(old.viewport.minX, old.corner.maxX),
                          old.rowHeaders.filter { !$0.isSummary }.map(\.frame.maxX).max() ?? old.viewport.minX)
        guard leading < old.viewport.maxX, top < old.viewport.maxY else { return 0 }
        let visible = CGRect(x: leading, y: top, width: old.viewport.maxX - leading,
                             height: old.viewport.maxY - top)

        var anchor: (cell: BoardFrames.Cell, layout: BoardFrames.CardLayout, frame: CGRect)?
        for cell in old.cells {
            guard old.globalFrame(cell.frame).intersects(visible) else { continue }
            for layout in cell.cardLayouts {
                let frame = old.globalFrame(CGRect(x: cell.frame.minX + 6, y: cell.frame.minY + layout.offset,
                                                  width: max(0, cell.frame.width - 12), height: layout.height))
                guard frame.intersects(visible) else { continue }
                if let current = anchor {
                    if frame.minY > current.frame.minY { break }
                    if frame.minY == current.frame.minY && frame.minX >= current.frame.minX { break }
                }
                anchor = (cell, layout, frame)
                break
            }
        }
        guard let anchor,
              let cell = new.cells.first(where: { $0.columnID == anchor.cell.columnID && $0.row == anchor.cell.row }),
              cell.cardLayouts.map(\.id) == anchor.cell.cardLayouts.map(\.id),
              let layout = cell.cardLayouts.first(where: { $0.id == anchor.layout.id }) else { return 0 }
        // Differences first: identical fractional frames then cancel exactly, and sub-point
        // noise never asks the board to scroll.
        let adjustment = (cell.frame.minY - anchor.cell.frame.minY) + (layout.offset - anchor.layout.offset)
        return abs(adjustment) < 0.5 ? 0 : adjustment
    }
}
