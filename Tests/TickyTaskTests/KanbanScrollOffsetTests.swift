import Testing
import SwiftUI
import Observation
@testable import TickyTask

/// Scrolling must not redraw the board: a tick only notifies what actually changed.
@MainActor
@Suite("Kanban scroll offset")
struct KanbanScrollOffsetTests {
    private func geometry(x: CGFloat = 0, y: CGFloat) -> ScrollGeometry {
        ScrollGeometry(contentOffset: CGPoint(x: x, y: y), contentSize: CGSize(width: 3000, height: 20000),
                       contentInsets: EdgeInsets(), containerSize: CGSize(width: 1000, height: 700))
    }

    /// Whether reading `read` and then running `change` notifies an observer.
    private func notifies(_ scroll: KanbanScrollOffset, _ read: @escaping () -> Void, _ change: () -> Void) -> Bool {
        var fired = false
        withObservationTracking(read) { fired = true }
        change()
        return fired
    }

    @Test("Vertical ticks inside one step change nothing observed; crossing a step re-windows once; x only moves sticky views")
    func ticks() {
        let scroll = KanbanScrollOffset()
        scroll.update(geometry(y: 10))
        let range = scroll.visibleRange
        #expect(!notifies(scroll, { _ = scroll.visibleRange }) { scroll.update(geometry(y: 60)) }, "same 400-point step")
        #expect(!notifies(scroll, { _ = scroll.x }) { scroll.update(geometry(y: 90)) }, "vertical scrolls leave the sticky headers")
        #expect(notifies(scroll, { _ = scroll.visibleRange }) { scroll.update(geometry(y: 450)) })
        #expect(scroll.visibleRange != range)
        #expect(notifies(scroll, { _ = scroll.x }) { scroll.update(geometry(x: 40, y: 450)) })
    }
}
