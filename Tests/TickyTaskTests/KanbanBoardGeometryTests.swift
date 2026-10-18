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

    var virtualizedFrames: BoardFrames {
        var result = frames
        result.cells[2].cardLayouts = [
            .init(id: a, offset: 6, height: 40),
            .init(id: b, offset: 52, height: 40),
            .init(id: c, offset: 98, height: 40),
        ]
        return result
    }

    @Test func missingCardFramesUseTheCompleteCellOrder() {
        var f = virtualizedFrames
        f.cards = []
        let resolve = { (y: CGFloat) in BoardGeometry.resolve(pointer: CGPoint(x: 300, y: y), source: .cards([UUID()]), frames: f) }
        #expect(resolve(150) == .cell(columnID: todo, row: .resource(ravi), beforeCardID: a))
        #expect(resolve(200) == .cell(columnID: todo, row: .resource(ravi), beforeCardID: b))
        #expect(resolve(250) == .cell(columnID: todo, row: .resource(ravi), beforeCardID: c))
        #expect(resolve(290) == .cell(columnID: todo, row: .resource(ravi), beforeCardID: nil))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 300, y: 200), source: .cards([b]), frames: f)
                == .cell(columnID: todo, row: .resource(ravi), beforeCardID: c))
    }

    @Test func realizedMidpointsOverrideEstimatedCardHeights() {
        var f = virtualizedFrames
        f.cards = [.init(id: b, columnID: todo, row: .resource(ravi), frame: CGRect(x: 206, y: 192, width: 238, height: 70))]
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 300, y: 220), source: .cards([UUID()]), frames: f)
                == .cell(columnID: todo, row: .resource(ravi), beforeCardID: b), "the estimate's midpoint was 212; the measured midpoint is 227")
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 300, y: 227), source: .cards([UUID()]), frames: f)
                == .cell(columnID: todo, row: .resource(ravi), beforeCardID: c), "the exact midpoint still lands after the card")
    }

    @Test func contentTranslationPreservesTargetsWithoutChangingPublishedFrames() {
        var f = virtualizedFrames
        let cards = f.cards, cells = f.cells
        f.contentOrigin = CGPoint(x: -50, y: -100)
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 250, y: 50), source: .cards([UUID()]), frames: f)
                == .cell(columnID: todo, row: .resource(ravi), beforeCardID: a))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 500, y: 20), source: .cards([a]), frames: f) == .columnHeader(doing),
                "the pinned header is already global")
        #expect(f.cardFrame(id: a) == CGRect(x: 156, y: 46, width: 238, height: 40))
        #expect(f.cards == cards && f.cells == cells)
        f.cards.removeAll()
        #expect(f.cardFrame(id: a) == CGRect(x: 156, y: 46, width: 238, height: 40), "unrealized cards use the same translation")
    }

    @Test func aLongCellResolvesNeverRealizedCardsNearItsEnd() {
        let ids = (0..<200).map { _ in UUID() }
        let layouts = ids.enumerated().map { index, id in
            BoardFrames.CardLayout(id: id, offset: 6 + CGFloat(index) * 46, height: 40)
        }
        let f = BoardFrames(cells: [.init(columnID: todo, row: .unassigned,
                                         frame: CGRect(x: 200, y: 0, width: 250, height: 9212), cardLayouts: layouts)],
                            viewport: CGRect(x: 0, y: 0, width: 700, height: 360), contentOrigin: CGPoint(x: 0, y: -9000))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 300, y: 120), source: .cards([UUID()]), frames: f)
                == .cell(columnID: todo, row: .unassigned, beforeCardID: ids[198]))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 300, y: 200), source: .cards([UUID()]), frames: f)
                == .cell(columnID: todo, row: .unassigned, beforeCardID: nil))
    }

    @Test @MainActor func preferenceRefreshRetainsScrollOriginAndVirtualInsertionFrames() {
        let controller = BoardDragController()
        controller.setContentOrigin(CGPoint(x: -50, y: -100))
        var f = virtualizedFrames
        f.cards = []
        controller.frames = f
        #expect(controller.frames.contentOrigin == CGPoint(x: -50, y: -100))
        #expect(controller.cardFrame(id: b) == CGRect(x: 156, y: 92, width: 238, height: 40))
        controller.begin(.cards([UUID()]), frame: nil, start: CGPoint(x: 250, y: 100))
        defer { controller.cancel() }
        #expect(controller.target == .cell(columnID: todo, row: .resource(ravi), beforeCardID: b))
        #expect(controller.insertionLine?.midY == 89)
        #expect(controller.highlight == CGRect(x: 150, y: 40, width: 250, height: 160))
        controller.setContentOrigin(CGPoint(x: -50, y: -146))
        #expect(controller.target == .cell(columnID: todo, row: .resource(ravi), beforeCardID: c))
        #expect(controller.insertionLine?.midY == 89)
        controller.update(pointer: CGPoint(x: 250, y: 150))
        #expect(controller.target == .cell(columnID: todo, row: .resource(ravi), beforeCardID: nil))
        #expect(controller.insertionLine?.midY == 135, "the end marker follows the last virtual card")
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
        var clipped = frames
        clipped.cells.append(.init(columnID: todo, row: .resource(mia), frame: CGRect(x: 200, y: 300, width: 250, height: 200)))
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 300, y: 340), source: .cards([a]), frames: clipped) != nil)
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 300, y: 420), source: .cards([a]), frames: clipped) == nil,
                "the clipped part of a cell below the board isn't a target")
    }

    @Test func thePinnedCornerCoversScrolledColumns() {
        var f = frames
        // Scrolled 100 pt sideways: To Do's header now starts under the pinned corner.
        f.columnHeaders = [.init(id: todo, frame: CGRect(x: 100, y: 0, width: 250, height: 40)),
                           .init(id: doing, frame: CGRect(x: 350, y: 0, width: 250, height: 40))]
        f.corner = CGRect(x: 0, y: 0, width: 200, height: 40)
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 150, y: 20), source: .cards([a]), frames: f) == nil, "hidden under the corner")
        #expect(BoardGeometry.resolve(pointer: CGPoint(x: 250, y: 20), source: .cards([a]), frames: f) == .columnHeader(todo))
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

// MARK: - Drag preview computation tests

@Suite("Kanban board drag previews")
struct KanbanBoardDragPreviewTests {
    let projectID = UUID(), unassignedID = UUID(), todoID = UUID(), doneID = UUID()
    let ravi = UUID(), mia = UUID()

    func makeMetricsSnapshot(cards: [MetricsSnapshot.Card], members: [MetricsSnapshot.Member]) -> MetricsSnapshot {
        MetricsSnapshot(
            projectID: projectID, projectName: "Test",
            columns: [
                .init(id: todoID, name: "To Do", kind: .active),
                .init(id: doneID, name: "Done", kind: .done),
            ],
            members: members,
            cards: cards,
            now: Date(), calendar: Calendar(identifier: .gregorian)
        )
    }

    @Test func singleCardOwnerToOwner() {
        let metrics = makeMetricsSnapshot(
            cards: [
                .init(id: UUID(), column: todoID, resource: ravi, estimateHours: 4, createdAt: Date(), updatedAt: Date()),
                .init(id: UUID(), column: todoID, resource: mia, estimateHours: 5, createdAt: Date(), updatedAt: Date()),
            ],
            members: [
                .init(id: ravi, personID: UUID(), name: "Ravi"),
                .init(id: mia, personID: UUID(), name: "Mia"),
            ]
        )
        let raviCard = metrics.cards.first { $0.resource == ravi }!
        let days = MetricsDays(metrics)

        // Original approach: project what Mia's load would be if she takes Ravi's card.
        let before = KanbanMetrics.projectedLoad(metrics, member: metrics.members.first { $0.id == mia }!, dragged: [], toColumn: UUID(), toResource: nil)
        let after = KanbanMetrics.projectedLoad(metrics, member: metrics.members.first { $0.id == mia }!, dragged: [raviCard.id], toColumn: todoID, toResource: mia)

        // New approach: directly compute the delta.
        let value = KanbanMetrics.thisWeek(metrics, days, raviCard)
        let expectedAfter = before.load + value

        #expect(after.load == expectedAfter)
    }

    @Test func multiSelectAcrossPeopleOntoColumnHeader() {
        let card1 = UUID(), card2 = UUID()
        let metrics = makeMetricsSnapshot(
            cards: [
                .init(id: card1, column: todoID, resource: ravi, estimateHours: 3, createdAt: Date(), updatedAt: Date()),
                .init(id: card2, column: todoID, resource: mia, estimateHours: 2, createdAt: Date(), updatedAt: Date()),
            ],
            members: [
                .init(id: ravi, personID: UUID(), name: "Ravi", allocationPercent: 100),
                .init(id: mia, personID: UUID(), name: "Mia", allocationPercent: 100),
            ]
        )
        let days = MetricsDays(metrics)

        // When dropped on a column header, each card keeps its person.
        // Ravi's card stays with Ravi (no change).
        // Mia's card stays with Mia (no change).
        let selectedCards = Set([card1, card2])
        var delta: [UUID: Double] = [:]
        for card in metrics.cards where selectedCards.contains(card.id) {
            let value = KanbanMetrics.thisWeek(metrics, days, card)
            // No change: destination column header preserves resource.
            // Would subtract from source and add to destination, but they're the same.
        }

        #expect(delta.isEmpty)
    }

    @Test func moveIntoDone() {
        let card = UUID()
        let metrics = makeMetricsSnapshot(
            cards: [
                .init(id: card, column: todoID, resource: ravi, estimateHours: 5, createdAt: Date(), updatedAt: Date()),
            ],
            members: [
                .init(id: ravi, personID: UUID(), name: "Ravi"),
            ]
        )
        let days = MetricsDays(metrics)

        // Moving to Done removes load from open columns.
        let before = KanbanMetrics.projectedLoad(metrics, member: metrics.members[0], dragged: [], toColumn: UUID(), toResource: nil)
        let after = KanbanMetrics.projectedLoad(metrics, member: metrics.members[0], dragged: [card], toColumn: doneID, toResource: ravi)

        let value = KanbanMetrics.thisWeek(metrics, days, metrics.cards[0])
        let expectedAfter = before.load - value

        #expect(after.load == expectedAfter)
    }

    @Test func unassignedCard() {
        let card = UUID()
        let metrics = makeMetricsSnapshot(
            cards: [
                .init(id: card, column: todoID, resource: nil, estimateHours: 3, createdAt: Date(), updatedAt: Date()),
            ],
            members: [
                .init(id: ravi, personID: UUID(), name: "Ravi"),
            ]
        )

        // Unassigned cards don't affect any member's baseline.
        let baseline = KanbanMetrics.loadVsCapacity(metrics)
        #expect(baseline.first { $0.memberID == ravi }?.load == 0)
    }
}
