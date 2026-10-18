import Testing
import Foundation
import CoreGraphics
@testable import TickyTask

@Suite("Board scroll anchoring")
struct BoardScrollAnchorTests {
    let column = UUID()
    let ids = (0..<200).map { _ in UUID() }

    private func frames(measuredHeights: [UUID: CGFloat] = [:], estimatedHeight: CGFloat = 72) -> BoardFrames {
        let layout = BoardCardLayout(ids: ids, measuredHeights: measuredHeights, estimatedHeight: estimatedHeight)
        let cards = ids.indices.map { index in
            BoardFrames.CardLayout(id: ids[index], offset: 6 + layout.offsets[index], height: layout.heights[index])
        }
        return BoardFrames(
            cells: [.init(columnID: column, row: .unassigned,
                          frame: CGRect(x: 200, y: 40, width: 250, height: layout.totalHeight + 12), cardLayouts: cards)],
            columnHeaders: [.init(id: column, frame: CGRect(x: 200, y: 0, width: 250, height: 40))],
            rowHeaders: [.init(row: .unassigned, frame: CGRect(x: 0, y: 40, width: 200, height: 320))],
            viewport: CGRect(x: 0, y: 0, width: 700, height: 360),
            corner: CGRect(x: 0, y: 0, width: 200, height: 40),
            contentOrigin: CGPoint(x: 0, y: -7_820))
    }

    @Test("Measuring earlier cards preserves a partly clipped card and its realized window")
    func estimatedHeightsSettle() {
        let old = frames()
        let measurements = Dictionary(uniqueKeysWithValues: ids.prefix(100).map { ($0, CGFloat(88)) })
        var new = frames(measuredHeights: measurements)
        let adjustment = BoardScrollAnchor.verticalAdjustment(from: old, to: new)

        #expect(adjustment == 1_600)
        #expect(old.cardFrame(id: ids[100])?.minY == 26, "the anchor extends beneath the 40 pt header")
        new.contentOrigin.y -= adjustment
        #expect(new.cardFrame(id: ids[100])?.minY == old.cardFrame(id: ids[100])?.minY)

        let layout = BoardCardLayout(ids: ids, measuredHeights: measurements)
        let visibleTop = 40 - new.contentOrigin.y - new.cells[0].frame.minY - 6
        let visibleBottom = 360 - new.contentOrigin.y - new.cells[0].frame.minY - 6
        let indices = layout.visibleIndices(in: visibleTop...visibleBottom, overscan: 0)
        #expect(indices == Array(100...104), "settling does not jump to another part of the 200-card cell")
    }

    @Test("Width or density changes preserve the visible card", arguments: [CGFloat(44), CGFloat(100)])
    func revisedEstimates(estimatedHeight: CGFloat) {
        let old = frames()
        var new = frames(estimatedHeight: estimatedHeight)
        new.cells[0].frame.size.width = 320
        let adjustment = BoardScrollAnchor.verticalAdjustment(from: old, to: new)

        #expect(adjustment == 100 * (estimatedHeight - 72))
        new.contentOrigin.y -= adjustment
        #expect(new.cardFrame(id: ids[100])?.minY == old.cardFrame(id: ids[100])?.minY)
    }

    @Test("An earlier row's height change is included in the correction")
    func earlierRowHeightChanges() {
        var old = frames()
        let laterRow = UUID()
        old.rowOrder = [laterRow]
        old.cells[0].row = .resource(laterRow)
        old.cells[0].frame.origin.y += 240
        old.contentOrigin.y -= 240
        old.cells.insert(.init(columnID: column, row: .unassigned,
                               frame: CGRect(x: 200, y: 40, width: 250, height: 240)), at: 0)
        var new = old
        new.cells[0].frame.size.height += 90
        new.cells[1].frame.origin.y += 90

        #expect(BoardScrollAnchor.verticalAdjustment(from: old, to: new) == 90)
    }

    @Test("Changes to the anchor's height or cards below it do not move its top")
    func laterHeightChanges() {
        let old = frames()
        let new = frames(measuredHeights: [ids[100]: 150, ids[150]: 120])
        #expect(BoardScrollAnchor.verticalAdjustment(from: old, to: new) == 0)
    }

    @Test("Scrolling and realized frame updates never introduce a correction")
    func unchangedVirtualLayout() {
        let old = frames()
        var new = old
        new.contentOrigin = CGPoint(x: -50, y: -8_000)
        new.cards = [.init(id: ids[100], columnID: column, row: .unassigned,
                           frame: CGRect(x: 206, y: 8_000, width: 238, height: 100))]

        #expect(BoardScrollAnchor.verticalAdjustment(from: old, to: new) == 0)
    }

    @Test("Cards covered by the pinned row header are excluded from anchor selection")
    func hiddenColumnIsExcluded() {
        var old = frames()
        let hiddenCard = UUID()
        old.cells.insert(.init(columnID: UUID(), row: .unassigned,
                               frame: CGRect(x: 0, y: 7_830, width: 150, height: 100),
                               cardLayouts: [.init(id: hiddenCard, offset: 6, height: 72)]), at: 0)
        var new = old
        new.cells[1].cardLayouts[0].height += 20
        for index in 1..<new.cells[1].cardLayouts.count {
            new.cells[1].cardLayouts[index].offset += 20
        }

        #expect(BoardScrollAnchor.verticalAdjustment(from: old, to: new) == 20)
    }

    @Test("Removal, movement and reordering leave structural changes unanchored")
    func structuralChanges() {
        let old = frames()
        var removed = frames(estimatedHeight: 100)
        removed.cells[0].cardLayouts.remove(at: 100)
        #expect(BoardScrollAnchor.verticalAdjustment(from: old, to: removed) == 0)

        var reordered = frames(estimatedHeight: 100)
        reordered.cells[0].cardLayouts.swapAt(99, 100)
        #expect(BoardScrollAnchor.verticalAdjustment(from: old, to: reordered) == 0)

        var moved = frames(estimatedHeight: 100)
        moved.cells[0].row = .resource(UUID())
        #expect(BoardScrollAnchor.verticalAdjustment(from: old, to: moved) == 0)

        var reorderedRows = frames(estimatedHeight: 100)
        reorderedRows.rowOrder = [UUID()]
        #expect(BoardScrollAnchor.verticalAdjustment(from: old, to: reorderedRows) == 0)
    }

    @Test("Initial, missing and fully clipped geometry has no scroll anchor")
    func missingGeometry() {
        let old = frames()
        #expect(BoardScrollAnchor.verticalAdjustment(from: BoardFrames(), to: old) == 0)
        #expect(BoardScrollAnchor.verticalAdjustment(from: old, to: BoardFrames()) == 0)
        var clipped = old
        clipped.viewport.size.width = 100
        #expect(BoardScrollAnchor.verticalAdjustment(from: clipped, to: frames(estimatedHeight: 100)) == 0)
    }
}
