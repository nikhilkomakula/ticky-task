import Testing
import SwiftUI
@testable import TickyTask

@Suite("Board card reveal offsets")
struct BoardCardRevealTests {
    private let column = UUID()
    private let row = KanbanRowKey.resource(UUID())
    private let ids = (0..<201).map { _ in UUID() }

    private func frames(measuredHeights: [UUID: CGFloat] = [:]) -> BoardFrames {
        let layout = BoardCardLayout(ids: ids, measuredHeights: measuredHeights)
        return BoardFrames(
            cells: [.init(columnID: column, row: row,
                          frame: CGRect(x: 200, y: 140, width: 250, height: layout.totalHeight + 38),
                          cardLayouts: ids.indices.map {
                              .init(id: ids[$0], offset: layout.offsets[$0] + 6, height: layout.heights[$0])
                          })],
            columnHeaders: [.init(id: column, frame: CGRect(x: 300, y: 100, width: 250, height: 40))],
            rowHeaders: [.init(row: row, frame: CGRect(x: 100, y: 240, width: 200, height: layout.totalHeight + 38))],
            viewport: CGRect(x: 100, y: 100, width: 700, height: 600),
            corner: CGRect(x: 100, y: 100, width: 200, height: 40),
            contentOrigin: CGPoint(x: 100, y: 100))
    }

    private func geometry(y: CGFloat = 0, contentHeight: CGFloat = 30_000) -> ScrollGeometry {
        ScrollGeometry(contentOffset: CGPoint(x: 0, y: y), contentSize: CGSize(width: 1_000, height: contentHeight),
                       contentInsets: EdgeInsets(), containerSize: CGSize(width: 700, height: 600))
    }

    @Test("An appended, never-realized card in a 200-card cell scrolls below pinned headers")
    func estimatedEndOfLongCell() throws {
        var frames = frames()
        let lastID = try #require(ids.last)
        let card = try #require(frames.cardFrame(id: lastID))
        #expect(frames.cards.isEmpty, "the target only has a virtual layout slot")
        #expect(card.minY == 15_846)
        let target = try #require(BoardCardReveal.targetOffset(for: card, in: frames, geometry: geometry()))
        #expect(target == CGPoint(x: 0, y: 15_462))

        frames.contentOrigin.y -= target.y
        let visible = BoardCardReveal.visibleViewport(in: frames)
        let revealed = try #require(frames.cardFrame(id: lastID))
        #expect(visible.contains(revealed))
        #expect(visible.minY > frames.columnHeaders[0].frame.maxY)

        let layout = BoardCardLayout(ids: ids)
        let indices = layout.visibleIndices(in: 0...600, pinned: [lastID])
        #expect(indices.contains(200), "the reveal pins the target before the scroll is acknowledged")
        #expect(indices.count < 25, "pinning never realizes all intervening cards")
    }

    @Test("Measurements before the target revise the reveal offset")
    func measuredHeightsSettle() throws {
        let old = frames()
        let new = frames(measuredHeights: Dictionary(uniqueKeysWithValues: ids.prefix(200).map { ($0, CGFloat(88)) }))
        let lastID = try #require(ids.last)
        let inner1 = try #require(old.cardFrame(id: lastID))
        let oldTarget = try #require(BoardCardReveal.targetOffset(for: inner1, in: old, geometry: geometry()))
        let inner2 = try #require(new.cardFrame(id: lastID))
        let newTarget = try #require(BoardCardReveal.targetOffset(for: inner2, in: new, geometry: geometry()))
        #expect(newTarget.y - oldTarget.y == 3_200)
    }

    @Test("Content translation and unacknowledged scroll geometry do not change the destination")
    func translationDoesNotReuseStaleOffset() throws {
        var frames = frames()
        let lastID = try #require(ids.last)
        let inner3 = try #require(frames.cardFrame(id: lastID))
        let original = try #require(BoardCardReveal.targetOffset(for: inner3, in: frames, geometry: geometry()))
        frames.contentOrigin.y -= 8_000
        let inner4 = try #require(frames.cardFrame(id: lastID))
        let stale = try #require(BoardCardReveal.targetOffset(for: inner4, in: frames, geometry: geometry()))
        let inner5 = try #require(frames.cardFrame(id: lastID))
        let acknowledged = try #require(BoardCardReveal.targetOffset(for: inner5, in: frames, geometry: geometry(y: 8_000)))
        #expect(stale == original)
        #expect(acknowledged == original)
    }

    @Test("Targets respect both content edges and wait for a usable viewport")
    func boundsAndMissingViewport() throws {
        var frames = frames()
        frames.cells[0].frame.origin.y = 40
        let first = try #require(frames.cardFrame(id: ids[0]))
        #expect(BoardCardReveal.targetOffset(for: first, in: frames, geometry: geometry()) == .zero)
        #expect(BoardCardReveal.visibleViewport(in: frames).contains(first),
                "the first cell's 6-point padding already clears both pinned headers")
        let lastID = try #require(ids.last)
        let last = try #require(frames.cardFrame(id: lastID))
        let height = frames.cells[0].frame.maxY
        let target = try #require(BoardCardReveal.targetOffset(for: last, in: frames, geometry: geometry(contentHeight: height)))
        #expect(target.y == height - 600, "a target near the content bottom clamps to the scroll extent")
        frames.viewport = .zero
        #expect(BoardCardReveal.targetOffset(for: last, in: frames, geometry: geometry()) == nil)
    }
}
