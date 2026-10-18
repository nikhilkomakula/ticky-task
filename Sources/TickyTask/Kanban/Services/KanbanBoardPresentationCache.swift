import Foundation

/// Selection, focus and hover redraws reuse the board's grouping and Done subsets.
@MainActor
final class KanbanBoardPresentationCache {
    struct CellKey: Hashable {
        let column: UUID
        let row: KanbanRowKey
    }

    private struct Key: Equatable {
        let projectID: UUID
        let metrics: KanbanMetricsCache.Key
        let state: KanbanBoardState
        let day: Date
        let calendar: Calendar
        let expandedDone: Set<CellKey>
    }

    @MainActor
    final class Presentation {
        let snapshot: BoardSnapshot
        let columns: [KanbanColumn]
        let tasks: [UUID: KanbanTask]
        let cells: [CellKey: [KanbanTask]]
        let shown: [CellKey: [KanbanTask]]
        let doneHidden: [CellKey: Int]
        let tucked: Set<UUID>
        let hiddenByColumn: [UUID: Int]

        init(project: KanbanProject, state: KanbanBoardState, calendar: Calendar, now: Date, expandedDone: Set<CellKey>) {
            // Archived memberships stay out of the move targets even with Show Archived.
            let snapshot = BoardSnapshot.make(project: project, includeArchived: state.showArchived, includeArchivedRows: false)
            let columns = project.orderedColumns
            self.snapshot = snapshot
            self.columns = columns
            let tasks = Dictionary(project.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.tasks = tasks
            let cells = Dictionary(grouping: snapshot.cards.compactMap { card in
                tasks[card.id].map { (CellKey(column: card.columnID, row: card.row), $0) }
            }.filter { state.filter.matches($0.1, now: now, calendar: calendar) }, by: \.0)
                .mapValues { state.sorted($0.map(\.1)) }
            self.cells = cells

            let done = Set(columns.filter { $0.kind == .done }.map(\.id))
            var shown = cells
            var doneHidden: [CellKey: Int] = [:]
            var tucked: Set<UUID> = []
            var hiddenByColumn: [UUID: Int] = [:]
            if state.compactsDone {
                for (key, cell) in cells where done.contains(key.column) {
                    let recent = KanbanDoneCards.recent(cell)
                    let hidden = cell.count - recent.count
                    guard hidden > 0 else { continue }
                    doneHidden[key] = hidden
                    if !expandedDone.contains(key) {
                        shown[key] = recent
                        tucked.formUnion(Set(cell.map(\.id)).subtracting(recent.map(\.id)))
                        hiddenByColumn[key.column, default: 0] += hidden
                    }
                }
            }
            self.shown = shown
            self.doneHidden = doneHidden
            self.tucked = tucked
            self.hiddenByColumn = hiddenByColumn
        }
    }

    /// Tests pin the day without reading or changing a persistent store.
    var now: () -> Date = { Date() }
    private var key: Key?
    private var cached: Presentation?

    func presentation(of project: KanbanProject, key metricsKey: KanbanMetricsCache.Key, state: KanbanBoardState,
                      calendar: Calendar, expandedDone: Set<CellKey>) -> Presentation {
        let now = now()
        let key = Key(projectID: project.id, metrics: metricsKey, state: state, day: calendar.startOfDay(for: now),
                      calendar: calendar, expandedDone: expandedDone)
        if self.key == key, let cached { return cached }
        let presentation = Presentation(project: project, state: state, calendar: calendar, now: now, expandedDone: expandedDone)
        self.key = key
        cached = presentation
        return presentation
    }
}
