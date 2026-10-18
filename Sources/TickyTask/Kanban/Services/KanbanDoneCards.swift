import Foundation

/// Keeping finished work from piling up: a Done cell shows its most recent cards, and
/// finished cards can be archived (by hand or automatically).
enum KanbanDoneCards {
    static let recentCount = 5

    /// What a shortened Done cell shows, in the cell's order: its most recently finished cards
    /// (ties broken by id) and any without a completion date.
    static func recent(_ cell: [KanbanTask]) -> [KanbanTask] {
        let dated = cell.filter { $0.completedAt != nil }
        guard dated.count > recentCount else { return cell }
        let newest = dated.sorted { ($0.completedAt ?? .distantPast, $0.id.uuidString) > ($1.completedAt ?? .distantPast, $1.id.uuidString) }
        let kept = Set(newest.prefix(recentCount).map(\.id))
        return cell.filter { $0.completedAt == nil || kept.contains($0.id) }
    }

    /// A board's live cards in Done columns, every person and regardless of filters. With a
    /// number of days, only those finished longer ago than that (undated cards never qualify).
    static func archivable(in project: KanbanProject, finishedMoreThan days: Int? = nil, now: Date = Date()) -> [KanbanTask] {
        let done = project.tasks.filter { $0.archivedAt == nil && $0.column?.kind == .done }
        guard let days else { return done }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return [] }
        return done.filter { $0.completedAt.map { $0 < cutoff } ?? false }
    }
}
