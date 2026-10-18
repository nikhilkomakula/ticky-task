import Testing
import Foundation
import CoreGraphics
@testable import TickyTask

@Suite("Board card windowing")
struct BoardCardLayoutTests {
    @Test("Visible slots stay bounded as a cell grows", arguments: [200, 10_000])
    func boundedWindow(cardCount: Int) {
        let layout = BoardCardLayout(ids: (0..<cardCount).map { _ in UUID() })
        let indices = layout.visibleIndices(in: 7_800...8_400)

        #expect(indices == Array(96...111))
        #expect(indices.count < 20, "only the viewport and overscan create card views")
        #expect(layout.totalHeight == CGFloat(cardCount * 72 + (cardCount - 1) * 6))
    }

    @Test("Measured cards and spacers reconstruct the complete cell height")
    func measuredHeightsAndGaps() {
        let ids = (0..<5).map { _ in UUID() }
        let layout = BoardCardLayout(ids: ids, measuredHeights: [ids[0]: 40, ids[1]: 90, ids[2]: 25, ids[3]: 55])
        let indices = layout.visibleIndices(in: 50...70, pinned: [ids[3]], overscan: 0)

        #expect(layout.heights == [40, 90, 25, 55, 72])
        #expect(layout.offsets == [0, 46, 142, 173, 234])
        #expect(indices == [1, 3])
        #expect(layout.gap(before: 1, after: nil) == 46)
        #expect(layout.gap(before: 3, after: 1) == 37)
        #expect(layout.trailingGap(after: 3) == 78)

        var reconstructedHeight: CGFloat = 0
        var previous: Int?
        for index in indices {
            reconstructedHeight += layout.gap(before: index, after: previous) + layout.heights[index]
            previous = index
        }
        reconstructedHeight += layout.trailingGap(after: previous)
        #expect(reconstructedHeight == layout.totalHeight)
        #expect(layout.totalHeight == 306)
        #expect(layout.trailingGap(after: nil) == layout.totalHeight, "an unrealized cell is one spacer")
    }

    @Test("A distant focus target stays an isolated slot")
    func distantPinnedCard() {
        let ids = (0..<10_000).map { _ in UUID() }
        let layout = BoardCardLayout(ids: ids)
        let indices = layout.visibleIndices(in: 7_800...8_400, pinned: [ids[9_999], UUID()])

        #expect(indices == Array(96...111) + [9_999])
        #expect(indices.count == 17, "pinning must not realize intervening cards")
        #expect(layout.gap(before: 9_999, after: 111) > 700_000)
    }

    @Test("Empty cells and windows outside a cell realize no cards")
    func emptyAndOutsideWindows() {
        let empty = BoardCardLayout(ids: [])
        #expect(empty.totalHeight == 0)
        #expect(empty.visibleIndices(in: 0...600, pinned: [UUID()]).isEmpty)
        #expect(empty.trailingGap(after: nil) == 0)

        let ids = [UUID(), UUID()]
        let layout = BoardCardLayout(ids: ids, estimatedHeight: 40)
        #expect(layout.visibleIndices(in: -20 ... -1, overscan: 0).isEmpty)
        #expect(layout.visibleIndices(in: 87...100, overscan: 0).isEmpty)
        #expect(layout.visibleIndices(in: 1_000...2_000).isEmpty)
        #expect(layout.visibleIndices(in: 1_000...2_000, pinned: [ids[1]], overscan: 0) == [1])
    }

    @Test("Window endpoints include touching cards and exclude spacing alone")
    func exactBoundaries() {
        let layout = BoardCardLayout(ids: [UUID(), UUID(), UUID()], estimatedHeight: 40)

        #expect(layout.visibleIndices(in: 0...0, overscan: 0) == [0])
        #expect(layout.visibleIndices(in: 40...40, overscan: 0) == [0])
        #expect(layout.visibleIndices(in: 41...45, overscan: 0).isEmpty)
        #expect(layout.visibleIndices(in: 46...46, overscan: 0) == [1])
        #expect(layout.visibleIndices(in: 40...46, overscan: 0) == [0, 1])
        #expect(layout.visibleIndices(in: 132...132, overscan: 0) == [2])
        #expect(layout.visibleIndices(in: 133...133, overscan: 0).isEmpty)
        #expect(layout.visibleIndices(in: 41...45, overscan: 1) == [0, 1])
    }
}
