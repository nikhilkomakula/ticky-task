import Foundation

/// Pure task-search matching + ranking, isolated from SwiftData/UI so it's
/// unit-testable. The view passes its live `@Query` task list and a query
/// string; results come back title-matches-first, then most-recently-updated.
enum TaskSearch {
    /// Whitespace-trimmed query. Empty means "no active search". Case folding is
    /// left to `localizedCaseInsensitiveContains` so matching respects the user's
    /// locale (e.g. Turkish dotted/dotless I).
    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a task with this title/notes matches an already-trimmed query.
    static func matches(title: String, notes: String, query: String) -> Bool {
        guard !query.isEmpty else { return false }
        return title.localizedCaseInsensitiveContains(query)
            || notes.localizedCaseInsensitiveContains(query)
    }

    /// Ranked matches for `query`: title hits rank above notes-only hits, ties
    /// break by most-recently-updated, then by `id` for a fully stable order.
    /// Empty/whitespace query returns nothing.
    static func rank(_ tasks: [TaskItem], query: String) -> [TaskItem] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        return tasks
            .filter { matches(title: $0.title, notes: $0.notes, query: q) }
            .sorted { lhs, rhs in
                let lTitle = lhs.title.localizedCaseInsensitiveContains(q)
                let rTitle = rhs.title.localizedCaseInsensitiveContains(q)
                if lTitle != rTitle { return lTitle }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}
