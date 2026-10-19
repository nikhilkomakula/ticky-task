import Foundation
import CoreGraphics

/// Full cell extent without creating card views. Only the intersecting slots are drawn.
struct BoardCardLayout: Equatable, Sendable {
    let ids: [UUID]
    let heights: [CGFloat]
    let offsets: [CGFloat]
    let totalHeight: CGFloat

    init(ids: [UUID], measuredHeights: [UUID: CGFloat] = [:], estimatedHeight: CGFloat = 72, spacing: CGFloat = 6) {
        self.ids = ids
        heights = ids.map { max(1, measuredHeights[$0] ?? estimatedHeight) }
        var offsets: [CGFloat] = []
        var end: CGFloat = 0
        for height in heights {
            offsets.append(end)
            end += height + spacing
        }
        self.offsets = offsets
        totalHeight = ids.isEmpty ? 0 : end - spacing
    }

    /// Binary searches bound the window; distant focus/reveal targets stay isolated slots.
    func visibleIndices(in range: ClosedRange<CGFloat>, pinned: Set<UUID> = [], overscan: CGFloat = 800) -> [Int] {
        func firstIndex(where predicate: (Int) -> Bool) -> Int {
            var lower = 0, upper = ids.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if predicate(middle) { upper = middle } else { lower = middle + 1 }
            }
            return lower
        }
        let start = firstIndex { offsets[$0] + heights[$0] >= range.lowerBound - overscan }
        let end = firstIndex { offsets[$0] > range.upperBound + overscan }
        var indices = Set(start..<max(start, end))
        if !pinned.isEmpty {
            for (index, id) in ids.enumerated() where pinned.contains(id) { indices.insert(index) }
        }
        return indices.sorted()
    }

    func gap(before index: Int, after previous: Int?) -> CGFloat {
        offsets[index] - (previous.map { offsets[$0] + heights[$0] } ?? 0)
    }

    func trailingGap(after index: Int?) -> CGFloat {
        totalHeight - (index.map { offsets[$0] + heights[$0] } ?? 0)
    }
}
