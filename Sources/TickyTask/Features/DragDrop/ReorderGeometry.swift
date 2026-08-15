import CoreGraphics
import Foundation

/// Pure, testable geometry for drag-to-reorder. No SwiftUI, no SwiftData — just
/// frames and ids — so the drop-resolution logic (the part that decides where an
/// item lands) can be unit-tested without any UI or gesture.
enum ReorderGeometry {

    /// Resolve the drop target under `pointer`:
    /// 1. Among containers that accept `kind` and contain the pointer, pick the
    ///    innermost (smallest-area) — a row's own list wins over any enclosing region.
    /// 2. Within it, order the rows (excluding the dragged one) along the container
    ///    axis and return the first whose midpoint is past the pointer → insert
    ///    *before* it. Past the last midpoint → append (`beforeID == nil`). This
    ///    midpoint test is what makes dropping on a row's lower half insert *after* it.
    /// Returns nil when no accepting container is under the pointer (the caller keeps
    /// its previous target rather than clearing it).
    static func resolveTarget(pointer: CGPoint,
                              rows: [RowSnapshot],
                              containers: [ContainerSnapshot],
                              draggingID: UUID,
                              kind: DragKind) -> ReorderTarget? {
        let candidates = containers.filter { $0.accepts == kind && $0.frame.contains(pointer) }
        guard let chosen = candidates.min(by: { area($0.frame) < area($1.frame) }) else { return nil }

        let axis = chosen.axis
        let siblings = rows
            .filter { $0.container == chosen.container && $0.id != draggingID }
            .sorted { leadingEdge($0.frame, axis) < leadingEdge($1.frame, axis) }

        guard !siblings.isEmpty else {
            return ReorderTarget(container: chosen.container, beforeID: nil)
        }
        let p = pointerPosition(pointer, axis)
        if let before = siblings.first(where: { p < midpoint($0.frame, axis) }) {
            return ReorderTarget(container: chosen.container, beforeID: before.id)
        }
        return ReorderTarget(container: chosen.container, beforeID: nil)
    }

    /// Honor the fine-grained insertion position only in manual sort. In time/priority
    /// sort a within-container reorder would be re-sorted away, so we append instead
    /// (a cross-container *move* still happens — only the position is dropped).
    static func effectiveBeforeID(_ target: ReorderTarget?, manual: Bool) -> UUID? {
        manual ? target?.beforeID : nil
    }

    // MARK: - Axis helpers
    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }
    private static func pointerPosition(_ p: CGPoint, _ axis: ReorderAxis) -> CGFloat { axis == .vertical ? p.y : p.x }
    private static func leadingEdge(_ r: CGRect, _ axis: ReorderAxis) -> CGFloat { axis == .vertical ? r.minY : r.minX }
    private static func midpoint(_ r: CGRect, _ axis: ReorderAxis) -> CGFloat { axis == .vertical ? r.midY : r.midX }
}
