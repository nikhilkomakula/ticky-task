import Foundation

/// A value model of one board's structural invariants (design 01 §1.1, §2.2). A revert
/// applies its inverse here first and is refused if the result would break one, before
/// anything in the store changes.
struct KanbanInvariants {
    struct Card { var column: UUID?; var resource: UUID?; var live: Bool; var completed: Bool }
    struct Membership { var person: UUID?; var active: Bool }

    private var archivedPeople: Set<UUID> = []
    /// Columns whose kind the inverse changes; they must hold no cards.
    private var kindChanged: Set<UUID> = []
    /// Cards the inverse places or inserts; their completion must match their column.
    private var placed: Set<UUID> = []

    private var columns: [UUID: String] = [:]          // id → kind
    private var memberships: [UUID: Membership] = [:]
    private var cards: [UUID: Card] = [:]
    private var dependencies: [UUID: Set<UUID>] = [:]

    @MainActor
    init(_ project: KanbanProject, archivedPeople: Set<UUID> = []) {
        self.archivedPeople = archivedPeople
        for column in project.columns { columns[column.id] = column.kindRaw }
        for r in project.resources { memberships[r.id] = Membership(person: r.person?.id, active: r.archivedAt == nil) }
        for t in project.tasks {
            cards[t.id] = Card(column: t.column?.id, resource: t.resource?.id, live: t.archivedAt == nil, completed: t.completedAt != nil)
            dependencies[t.id] = Set(t.dependsOn.map(\.id))
        }
    }

    /// The board after an inverse of `kind` with `payload` is applied.
    func applying(_ kind: KanbanActivityKind, _ payload: KanbanActivityPayload) -> KanbanInvariants {
        var next = self
        let graph = payload.graph ?? KanbanRemovedGraph()
        if kind == .deleted {
            // A removal: the graph's rows go away (and edges into removed cards).
            let gone = Set(graph.tasks.map(\.id))
            graph.tasks.forEach { next.cards[$0.id] = nil; next.dependencies[$0.id] = nil }
            for key in next.dependencies.keys { next.dependencies[key]?.subtract(gone) }
            graph.columns.forEach { next.columns[$0.id] = nil }
            graph.resources.forEach { next.memberships[$0.id] = nil }
        } else if kind == .restoredGraph {
            graph.columns.forEach { next.columns[$0.id] = $0.kindRaw }
            graph.resources.forEach { next.memberships[$0.id] = Membership(person: $0.personId, active: $0.archivedAt == nil) }
            for t in graph.tasks {
                // A live card only goes back onto an active membership (as `reinsert` does).
                let active = t.resourceId.map { next.memberships[$0]?.active == true } ?? false
                let resource = t.archivedAt != nil || active ? t.resourceId : nil
                next.cards[t.id] = Card(column: t.columnId, resource: resource, live: t.archivedAt == nil, completed: t.completedAt != nil)
                next.placed.insert(t.id)
                next.dependencies[t.id] = Set(t.dependsOnIds)
            }
            for edge in graph.incomingDependencies where edge.count == 2 { next.dependencies[edge[0], default: []].insert(edge[1]) }
        }
        for t in payload.transitions where next.cards[t.taskID] != nil {
            next.cards[t.taskID]?.column = t.to.columnID
            next.cards[t.taskID]?.resource = t.to.resourceID
            next.cards[t.taskID]?.completed = t.to.completedAt != nil
            next.placed.insert(t.taskID)
        }
        for change in payload.changes {
            switch (change.entity, change.field) {
            case (.task, "dependsOn"): if case let .uuids(ids)? = change.new { next.dependencies[change.id] = Set(ids) }
            case (.task, "archivedAt"): next.cards[change.id]?.live = change.new == nil
            case (.resource, "archivedAt"): next.memberships[change.id]?.active = change.new == nil
            case (.column, "kind"):
                if case let .string(kind)? = change.new { next.columns[change.id] = kind }
                next.kindChanged.insert(change.id)
            default: break
            }
        }
        return next
    }

    /// The first broken invariant, in plain words, or nil.
    var violation: String? {
        let kinds = Array(columns.values)
        if kinds.filter({ $0 == KanbanColumnKind.backlog.rawValue }).count != 1 { return "a board needs exactly one backlog column" }
        if !kinds.contains(KanbanColumnKind.done.rawValue) { return "a board needs at least one Done column" }
        for card in cards.values where card.live {
            guard let column = card.column, columns[column] != nil else { return "a card would have no column" }
            if let resource = card.resource, memberships[resource]?.active != true { return "a card would be assigned to someone not on the board" }
        }
        // A card is complete exactly when it sits in a Done column.
        for id in placed {
            guard let card = cards[id], card.live, let column = card.column, let kind = columns[column] else { continue }
            if (kind == KanbanColumnKind.done.rawValue) != card.completed {
                return kind == KanbanColumnKind.done.rawValue
                    ? "a card would sit in a Done column without being complete"
                    : "a card would be complete outside a Done column"
            }
        }
        for column in kindChanged where cards.values.contains(where: { $0.column == column }) {
            _ = column
            return "a column holding cards would change kind"
        }
        var seen: Set<UUID> = []
        for membership in memberships.values where membership.active {
            guard let person = membership.person else { return "a membership would have no person" }
            if archivedPeople.contains(person) { return "an archived person would be back on the board" }
            if !seen.insert(person).inserted { return "someone would be on the board twice" }
        }
        // Dependencies stay acyclic.
        var state: [UUID: Int] = [:]   // 1 visiting, 2 done
        func cycle(from node: UUID) -> Bool {
            if state[node] == 1 { return true }
            if state[node] == 2 { return false }
            state[node] = 1
            for next in dependencies[node] ?? [] where cards[next] != nil { if cycle(from: next) { return true } }
            state[node] = 2
            return false
        }
        for node in dependencies.keys where cycle(from: node) { return "dependencies would form a cycle" }
        return nil
    }
}
