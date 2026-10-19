import SwiftUI

/// Numeric scrolling also reaches cards whose only position is a windowed cell's layout estimate.
enum BoardCardReveal {
    static func visibleViewport(in frames: BoardFrames) -> CGRect {
        let top = max(max(frames.viewport.minY, frames.corner.maxY),
                      frames.columnHeaders.map(\.frame.maxY).max() ?? frames.viewport.minY)
        let leading = max(max(frames.viewport.minX, frames.corner.maxX),
                          frames.rowHeaders.filter { !$0.isSummary }.map(\.frame.maxX).max() ?? frames.viewport.minX)
        return CGRect(x: leading + 4, y: top + 4,
                      width: max(0, frames.viewport.maxX - leading - 8),
                      height: max(0, frames.viewport.maxY - top - 8))
    }

    static func targetOffset(for card: CGRect, in frames: BoardFrames, geometry: ScrollGeometry) -> CGPoint? {
        let visible = visibleViewport(in: frames)
        guard visible.width > 0, visible.height > 0 else { return nil }
        // Use content coordinates, so an unacknowledged scroll tick cannot reuse an old offset.
        let content = card.offsetBy(dx: -frames.contentOrigin.x, dy: -frames.contentOrigin.y)
        return CGPoint(
            x: min(max(0, content.midX - (visible.midX - frames.viewport.minX)),
                   max(0, geometry.contentSize.width - geometry.containerSize.width)),
            y: min(max(0, content.midY - (visible.midY - frames.viewport.minY)),
                   max(0, geometry.contentSize.height - geometry.containerSize.height)))
    }
}
