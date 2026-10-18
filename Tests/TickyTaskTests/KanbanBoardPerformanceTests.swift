import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Kanban board performance benchmarks: unit tests that measure data preparation
/// time and rendering cost. These tests create 2,000 cards in memory and time:
/// - BoardSnapshot.make (grid structure construction)
/// - Filter and sort logic
/// - Board view body property evaluation
///
/// Budgets are scaled by `PERF_BUDGET_SCALE` (set on CI to stretch for slower runners).
@MainActor
@Suite("Kanban board performance")
struct KanbanBoardPerformanceTests {
    typealias F = MetricsFixture

    private static func budget(_ milliseconds: Int) -> Duration {
        let scale = ProcessInfo.processInfo.environment["PERF_BUDGET_SCALE"].flatMap(Double.init) ?? 1
        return .milliseconds(Int(Double(milliseconds) * max(scale, 1)))
    }

    /// Seeds 2,000 cards into a board with 30 people and times how long BoardSnapshot.make takes.
    /// This measures grid construction (grouping cards into cells) without rendering.
    @Test func boardSnapshotCreation() async throws {
        let context = ModelContainerProvider.makeInMemoryContainer().mainContext
        let project = try KanbanVolumeSeed.seed(into: context, cardCount: 2000)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = BoardSnapshot.make(project: project, includeArchived: false, includeArchivedRows: false)
        }

        print("KANBAN-PERF: BoardSnapshot.make (2000 cards): \(elapsed)")
        #expect(elapsed < Self.budget(500), "snapshot creation under 500ms scaled")
    }

    /// Seeds 2,000 cards and times the board view state decoding and filter/sort operations.
    /// Measures how long it takes to compute which cards are on screen and in what order.
    @Test func boardStateFilterAndSort() async throws {
        let context = ModelContainerProvider.makeInMemoryContainer().mainContext
        let project = try KanbanVolumeSeed.seed(into: context, cardCount: 2000)

        let snapshot = BoardSnapshot.make(project: project, includeArchived: false, includeArchivedRows: false)
        let state = KanbanBoardState.decode(project.boardState)
        let tasks = Dictionary(project.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let calendar = KanbanUI.calendar(weekStartsMonday: true)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let cells = Dictionary(
                grouping: snapshot.cards.compactMap { card in
                    tasks[card.id].map { (CellKey(column: card.columnID, row: card.row), $0) }
                }
                .filter { state.filter.matches($0.1, calendar: calendar) },
                by: \.0
            ).mapValues { state.sorted($0.map(\.1)) }
            _ = cells
        }

        print("KANBAN-PERF: filter & sort (2000 cards): \(elapsed)")
        #expect(elapsed < Self.budget(300), "filter/sort under 300ms scaled")
    }

    /// Seeds 2,000 cards and times metrics snapshot creation (load calculations, gauges, etc.).
    @Test func metricsSnapshot() async throws {
        let context = ModelContainerProvider.makeInMemoryContainer().mainContext
        let project = try KanbanVolumeSeed.seed(into: context, cardCount: 2000)

        let calendar = KanbanUI.calendar(weekStartsMonday: true)
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            _ = MetricsSnapshot(project: project, now: Date(), calendar: calendar)
        }

        print("KANBAN-PERF: MetricsSnapshot creation (2000 cards): \(elapsed)")
        #expect(elapsed < Self.budget(400), "metrics snapshot under 400ms scaled")
    }

    /// Seeds 2,000 cards and times the full board state computation that KanbanBoardView.body performs:
    /// BoardSnapshot.make, decoding state, building the tasks dict, filtering, sorting, and metrics.
    @Test func completeBoardStateComputation() async throws {
        let context = ModelContainerProvider.makeInMemoryContainer().mainContext
        let project = try KanbanVolumeSeed.seed(into: context, cardCount: 2000)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let state = KanbanBoardState.decode(project.boardState)
            let snapshot = BoardSnapshot.make(project: project, includeArchived: state.showArchived, includeArchivedRows: false)
            let columns = project.orderedColumns
            let calendar = KanbanUI.calendar(weekStartsMonday: true)
            let tasks = Dictionary(project.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            let cells = Dictionary(
                grouping: snapshot.cards.compactMap { card in
                    tasks[card.id].map { (CellKey(column: card.columnID, row: card.row), $0) }
                }
                .filter { state.filter.matches($0.1, calendar: calendar) },
                by: \.0
            ).mapValues { state.sorted($0.map(\.1)) }

            let metrics = MetricsSnapshot(project: project, now: Date(), calendar: calendar)
            _ = (cells, metrics, columns)
        }

        print("KANBAN-PERF: complete board state (2000 cards): \(elapsed)")
        #expect(elapsed < Self.budget(800), "complete state under 800ms scaled")
    }
}

// Helper type matching KanbanBoardView's CellKey
private struct CellKey: Hashable {
    let column: UUID
    let row: KanbanRowKey
}
