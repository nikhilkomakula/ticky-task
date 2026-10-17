import Testing
import Foundation
import CoreGraphics
@testable import TickyTask

/// Pure drop resolution for board drags (design 01 §4).
@Suite("Kanban board geometry")
struct KanbanBoardGeometryTests {
    let todo = UUID(), doing = UUID(), ravi = UUID(), mia = UUID()
    let a = UUID(), b = UUID(), c = UUID()

    /// Two columns (x 200–450, 450–700) and two rows (Unassigned y 40–140, Ravi 140–300);
    /// row headers at x 0–200, column headers at y 0–40. Ravi's To Do cell holds a, b, c.
    var frames: BoardFrames {
        BoardFrames(
            cards: [
                .init(id: a, columnID: todo, row: .resource(ravi), frame: CGRect(x: 206, y: 146, width: 238, height: 40)),
                .init(id: b, columnID: todo, row: .resource(ravi), frame: CGRect(x: 206, y: 192, width: 238, height: 40)),
                .init(id: c, columnID: todo, row: .resource(ravi), frame: CGRect(x: 206, y: 238, width: 238, height: 40)),
            ],
            cells: [
                .init(columnID: todo, row: .unassigned, frame: CGRect(x: 200, y: 40, width: 250, height: 100)),
                .init(columnID: doing, row: .unassigned, frame: CGRect(x: 450, y: 40, width: 250, height: 100)),
                .init(columnID: todo, row: .resource(ravi), frame: CGRect(x: 200, y: 140, width: 250, height: 160)),
                .init(columnID: doing, row: .resource(ravi), frame: CGRect(x: 450, y: 140, width: 250, height: 160)),
            ],
            columnHeaders: [
                .init(id: todo, frame: CGRect(x: 200, y: 0, width: 250, height: 40)),
                .init(id: doing, frame: CGRect(x: 450, y: 0, width: 250, height: 40)),
            ],
            rowHeaders: [
                .init(row: .unassigned, frame: CGRect(x: 0, y: 40, width: 200, height: 100)),
                .init(row: .resource(ravi), frame: CGRect(x: 0, y: 140, width: 200, height: 160)),
                .init(row: .resource(mia), frame: CGRect(x: 0, y: 300, width: 200, height: 60)),
                .init(row: .resource(mia), frame: CGRect(x: 200, y: 300, width: 500, height: 60), isSummary: true),
            ],
            viewport: CGRect(x: 0, y: 0, width: 700, height: 360),
            rowOrder: [ravi, mia])
    }

    @Test func cellInsertionFollowsTheMidpointRule() {
        let resolve = { (y: CGFloat) in BoardGeometry.resolve(pointer: CGPoint(x: 300, y: y), source: .cards([UUID()]), frames: frames) }
        #expect(resolve(150) == .cell(columnID: todo, row: .resource(ravi), beforeCardID: a))
        #expect(resolve(170) == .cell(columnID: todo, row: .resource(ravi), beforeCardID: b), "below a's middle lands after a")
        #expect(resolve(290) == .cell(columnID: todo, row: .resource(ravi), beforeCardID: nil))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 600, y: 90), source: .cards([a]), frames: frames)
                == .cell(columnID: doing, row: .unassigned, beforeCardID: nil))
    }

    @Test func theDraggedCardIsntASibling() {
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 300, y: 200), source: .cards([b]), frames: frames)
                == .cell(columnID: todo, row: .resource(ravi), beforeCardID: c))
    }

    @Test func headersWinOverCells() {
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 100, y: 200), source: .cards([a]), frames: frames) == .rowHeader(.resource(ravi)))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 500, y: 20), source: .cards([a]), frames: frames) == .columnHeader(doing))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 400, y: 330), source: .cards([a]), frames: frames) == .rowHeader(.resource(mia)),
                "a collapsed row's strip reassigns like its header")
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 900, y: 900), source: .cards([a]), frames: frames) == nil)
    }

    @Test func columnAndRowSlots() {
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 690, y: 100), source: .column(todo), frames: frames) == .columnSlot(1))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 210, y: 100), source: .column(doing), frames: frames) == .columnSlot(0))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 50, y: 350), source: .row(ravi), frames: frames) == .rowSlot(1),
                "Unassigned and collapsed strips aren't slots")
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 50, y: 50), source: .row(mia), frames: frames) == .rowSlot(0))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 900, y: 50), source: .row(mia), frames: frames) == nil)
    }

    @Test func whatThePointerSeesWins() {
        var f = frames
        // Mia's collapsed strip scrolled up under the pinned column headers.
        f.rowHeaders.append(.init(row: .resource(mia), frame: CGRect(x: 200, y: 10, width: 500, height: 60), isSummary: true))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 500, y: 20), source: .cards([a]), frames: f) == .columnHeader(doing),
                "the pinned column header is on top")
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 100, y: 20), source: .cards([a]), frames: f) == nil, "the corner isn't a target")
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 300, y: 380), source: .cards([a]), frames: frames) == nil,
                "clipped content outside the board isn't a target")
    }

    @Test func rowSlotsCountTheCompleteOrder() {
        let w = UUID(), x = UUID(), y = UUID(), z = UUID()
        // Only y and z are drawn; w and x are scrolled away.
        let f = BoardFrames(rowHeaders: [.init(row: .resource(y), frame: CGRect(x: 0, y: 100, width: 200, height: 50)),
                                         .init(row: .resource(z), frame: CGRect(x: 0, y: 150, width: 200, height: 50))],
                            viewport: CGRect(x: 0, y: 0, width: 700, height: 400), rowOrder: [w, x, y, z])
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 50, y: 110), source: .row(z), frames: f) == .rowSlot(2), "just above y, after x")
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 50, y: 190), source: .row(w), frames: f) == .rowSlot(3), "below z, last")
    }

    @Test func dropsMapToServiceOperations() {
        #expect(BoardGeometry.operation(source: .cards([a]), target: .rowHeader(.unassigned)) == .cards([a], to: .rowHeader(.unassigned)))
        #expect(BoardGeometry.operation(source: .column(todo), target: .columnSlot(1)) == .reorderColumn(todo, toIndex: 1))
        #expect(BoardGeometry.operation(source: .row(ravi), target: .rowSlot(0)) == .reorderRow(ravi, toIndex: 0))
        #expect(BoardGeometry.operation(source: .column(todo), target: .rowHeader(.unassigned)) == nil)
    }

    @Test func autoScrollNearTheEdgesOnly() {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(BoardGeometry.autoScrollDelta(pointer: CGPoint(x: 400, y: 300), viewport: viewport) == .zero)
        let right = BoardGeometry.autoScrollDelta(pointer: CGPoint(x: 790, y: 300), viewport: viewport)
        #expect(right.dx > 0 && right.dy == 0)
        let topLeft = BoardGeometry.autoScrollDelta(pointer: CGPoint(x: 5, y: 5), viewport: viewport)
        #expect(topLeft.dx < 0 && topLeft.dy < 0, "both axes at a corner")
        #expect(abs(BoardGeometry.autoScrollDelta(pointer: CGPoint(x: 1, y: 300), viewport: viewport).dx)
                > abs(BoardGeometry.autoScrollDelta(pointer: CGPoint(x: 30, y: 300), viewport: viewport).dx), "faster nearer the edge")
    }
}
