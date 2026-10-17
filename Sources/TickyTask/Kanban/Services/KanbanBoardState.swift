import Foundation

/// A board's remembered view: Board or List, filters, sort and Show Archived (design 01 §5).
/// Stored as JSON in `KanbanProject.boardState`; every key is optional, so older or newer
/// states decode to what they have.
struct KanbanBoardState: Codable, Equatable, Sendable {
    enum ViewKind: String, Codable, CaseIterable, Sendable { case board, list }
    enum Sort: String, Codable, CaseIterable, Sendable {
        case manual, priority, dueDate, title
        var label: String {
            switch self {
            case .manual: "Manual"
            case .priority: "Priority"
            case .dueDate: "Due date"
            case .title: "Title"
            }
        }
    }

    var view: ViewKind = .board
    var filter = KanbanCardFilter()
    var sort: Sort = .manual
    var showArchived = false
    /// The List view's sorted column ("title", "column", "assignee", "priority", "due",
    /// "labels", "estimate"); nil follows `sort`.
    var listSortKey: String?
    var listSortAscending = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        view = (try? c.decodeIfPresent(ViewKind.self, forKey: .view)) ?? .board
        filter = (try? c.decodeIfPresent(KanbanCardFilter.self, forKey: .filter)) ?? KanbanCardFilter()
        sort = (try? c.decodeIfPresent(Sort.self, forKey: .sort)) ?? .manual
        showArchived = (try? c.decodeIfPresent(Bool.self, forKey: .showArchived)) ?? false
        listSortKey = try? c.decodeIfPresent(String.self, forKey: .listSortKey)
        listSortAscending = (try? c.decodeIfPresent(Bool.self, forKey: .listSortAscending)) ?? true
    }

    /// The List view's sort: its own header choice, or the board sort's equivalent.
    var effectiveListSort: (key: String, ascending: Bool) {
        if let listSortKey { return (listSortKey, listSortAscending) }
        switch sort {
        case .manual: return ("column", true)
        case .priority: return ("priority", false)
        case .dueDate: return ("due", true)
        case .title: return ("title", true)
        }
    }

    static func decode(_ data: Data?) -> KanbanBoardState {
        data.flatMap { try? JSONDecoder().decode(KanbanBoardState.self, from: $0) } ?? KanbanBoardState()
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Orders one cell's (or the list's) cards.
    func sorted(_ tasks: [KanbanTask]) -> [KanbanTask] {
        switch sort {
        case .manual:
            return tasks.sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
        case .priority:
            func rank(_ t: KanbanTask) -> Int { t.isCritical ? 3 : t.priority }
            return tasks.sorted { (-rank($0), $0.sortIndex) < (-rank($1), $1.sortIndex) }
        case .dueDate:
            return tasks.sorted { ($0.dueDate ?? .distantFuture, $0.sortIndex) < ($1.dueDate ?? .distantFuture, $1.sortIndex) }
        case .title:
            return tasks.sorted { ($0.title.localizedLowercase, $0.sortIndex) < ($1.title.localizedLowercase, $1.sortIndex) }
        }
    }
}

/// Which cards a board shows (design 01 §5). Every condition that's set must hold.
struct KanbanCardFilter: Codable, Equatable, Sendable {
    enum Due: String, Codable, CaseIterable, Sendable {
        case overdue, thisWeek, nextWeek, none
        var label: String {
            switch self {
            case .overdue: "Overdue"
            case .thisWeek: "Due this week"
            case .nextWeek: "Due next week"
            case .none: "No due date"
            }
        }
    }

    var text = ""
    var labelIDs: Set<UUID> = []
    /// 0 low, 1 medium, 2 high; Critical is its own flag.
    var priorities: Set<Int> = []
    var criticalOnly = false
    /// Membership ids; `unassigned` adds the Unassigned row.
    var resourceIDs: Set<UUID> = []
    var unassigned = false
    var due: Due?
    var blockedOnly = false
    /// nil: either; true: has one; false: hasn't.
    var hasJira: Bool?
    var hasEstimate: Bool?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        labelIDs = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .labelIDs)) ?? []
        priorities = (try? c.decodeIfPresent(Set<Int>.self, forKey: .priorities)) ?? []
        criticalOnly = (try? c.decodeIfPresent(Bool.self, forKey: .criticalOnly)) ?? false
        resourceIDs = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .resourceIDs)) ?? []
        unassigned = (try? c.decodeIfPresent(Bool.self, forKey: .unassigned)) ?? false
        due = try? c.decodeIfPresent(Due.self, forKey: .due)
        blockedOnly = (try? c.decodeIfPresent(Bool.self, forKey: .blockedOnly)) ?? false
        hasJira = try? c.decodeIfPresent(Bool.self, forKey: .hasJira)
        hasEstimate = try? c.decodeIfPresent(Bool.self, forKey: .hasEstimate)
    }

    var isActive: Bool { self != KanbanCardFilter() }

    func matches(_ task: KanbanTask, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let needle = TaskSearch.normalize(text)
        if !needle.isEmpty, !TaskSearch.matches(title: task.title, notes: task.notes, query: text) { return false }
        if !labelIDs.isEmpty, !task.labels.contains(where: { labelIDs.contains($0.id) }) { return false }
        if !priorities.isEmpty, !priorities.contains(task.priority) { return false }
        if criticalOnly, !task.isCritical { return false }
        if !resourceIDs.isEmpty || unassigned {
            let id = task.resource.flatMap { $0.archivedAt == nil ? $0.id : nil }
            guard id.map(resourceIDs.contains) ?? unassigned else { return false }
        }
        if let due, !Self.matches(due, task.dueDate, now: now, calendar: calendar) { return false }
        if blockedOnly, !task.isBlocked { return false }
        if let hasJira, (task.jiraURL.map { KanbanMetrics.isWebURL($0) } ?? false) != hasJira { return false }
        if let hasEstimate, (task.estimateHours != nil) != hasEstimate { return false }
        return true
    }

    private static func matches(_ due: Due, _ date: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let date else { return due == .none }
        let today = calendar.startOfDay(for: now), day = calendar.startOfDay(for: date)
        let week = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let next = calendar.date(byAdding: .day, value: 7, to: week) ?? week
        let after = calendar.date(byAdding: .day, value: 14, to: week) ?? week
        switch due {
        case .overdue: return day < today
        case .thisWeek: return day >= today && day < next
        case .nextWeek: return day >= next && day < after
        case .none: return false
        }
    }
}
