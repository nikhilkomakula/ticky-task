import Foundation
import SwiftData
import Observation

/// Bumped by every Kanban save, rollback and restore; board snapshots and metric caches
/// are keyed by it (design 01 §2.5).
@MainActor @Observable
final class KanbanStoreGeneration {
    private(set) var value = 0
    func bump() { value += 1 }
}

enum KanbanServiceError: Error, Equatable, LocalizedError {
    case invariant(String)
    case conflict(String)
    case wipBlocked([UUID])
    case notFound

    var errorDescription: String? {
        switch self {
        case let .invariant(message), let .conflict(message): return message
        case .wipBlocked: return "That column is at its WIP limit."
        case .notFound: return "That item no longer exists."
        }
    }
}

/// Every Kanban mutation, sibling of `DataService` (design 01 §2): each public call
/// checkpoints unrelated edits, validates, prepares everything that can fail, then
/// mutates (deletions last), appends one change-log entry and saves once. A failed
/// save is undone in place, or fails closed when deletions were pending.
@MainActor
struct KanbanService {
    let context: ModelContext
    var history: KanbanHistory?
    var generation: KanbanStoreGeneration?
    var now: () -> Date = Date.init

    init(_ context: ModelContext, history: KanbanHistory? = nil, generation: KanbanStoreGeneration? = nil) {
        self.context = context
        self.history = history
        self.generation = generation
    }

    // MARK: - Projects

    enum Template { case standard, software }

    static let defaultLabels: [(String, String)] = [
        ("Feature", "#34C759"), ("Bug", "#FF3B30"), ("Enhancement", "#007AFF"), ("Tech Debt", "#AF52DE"),
        ("Spike", "#FF9500"), ("Documentation", "#5AC8FA"), ("Chore", "#8E8E93"),
    ]

    /// A new board with the template's columns and the default labels. Not undoable
    /// (archive it instead); its first change-log entry records the creation.
    @discardableResult
    func createProject(name: String, key: String, template: Template = .standard) throws -> KanbanProject {
        try RecurrenceMaterializer.checkpoint(context)
        let existing = try context.fetch(FetchDescriptor<KanbanProject>())
        let project = KanbanProject(name: name, key: key, sortIndex: (existing.map(\.sortIndex).max() ?? -1) + 1)
        let columns: [(String, KanbanColumnKind)] = template == .standard
            ? [("To Do", .backlog), ("In Progress", .active), ("Done", .done)]
            : [("Backlog", .backlog), ("To Do", .active), ("In Progress", .active), ("In Review", .active), ("Done", .done)]
        context.insert(project)
        for (index, column) in columns.enumerated() {
            let model = KanbanColumn(name: column.0, kind: column.1, sortIndex: Double(index))
            context.insert(model)
            model.project = project
        }
        for (index, label) in Self.defaultLabels.enumerated() {
            let model = KanbanLabel(name: label.0, colorHex: label.1, sortIndex: Double(index))
            context.insert(model)
            model.project = project
        }
        try save(project, kind: .structure, taskIDs: [], summary: "Created \(name)", payload: KanbanActivityPayload(), undoable: false)
        return project
    }

    // MARK: - People and memberships

    @discardableResult
    func createPerson(name: String, initials: String, employment: KanbanEmployment = .fte) throws -> KanbanPerson {
        try RecurrenceMaterializer.checkpoint(context)
        let person = KanbanPerson(name: name, initials: initials, employment: employment)
        context.insert(person)
        try saveOrUndo()
        return person
    }

    /// Puts `person` on `project`'s board. One non-archived membership per (person, project).
    @discardableResult
    func addMembership(_ person: KanbanPerson, to project: KanbanProject, allocationPercent: Int = 100,
                       assignment: KanbanAssignment = .fullTime) throws -> KanbanResource {
        try RecurrenceMaterializer.checkpoint(context)
        guard person.archivedAt == nil else { throw KanbanServiceError.invariant("\(person.name) is archived.") }
        guard !project.resources.contains(where: { $0.person?.id == person.id && $0.archivedAt == nil }) else {
            throw KanbanServiceError.invariant("\(person.name) is already on this board.")
        }
        let resource = KanbanResource(person: person, assignment: assignment, allocationPercent: min(max(allocationPercent, 1), 100),
                                      sortIndex: (project.resources.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(resource)
        resource.project = project
        let change = KanbanFieldChange(entity: .resource, id: resource.id, field: "archivedAt", old: .date(.distantPast), new: nil)
        try save(project, kind: .structure, taskIDs: [], summary: "Added \(person.name)",
                 payload: KanbanActivityPayload(changes: [change]))
        return resource
    }

    /// Archives a membership: its tasks go to Unassigned in the same save.
    func archiveMembership(_ resource: KanbanResource) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = resource.project, resource.archivedAt == nil else { throw KanbanServiceError.notFound }
        let stamp = now()
        let transitions = unassignTransitions(resource)
        let payload = KanbanActivityPayload(
            transitions: transitions,
            changes: [KanbanFieldChange(entity: .resource, id: resource.id, field: "archivedAt", old: nil, new: .date(stamp))]
                + subtaskUnassignChanges(resource))
        applyTransitions(transitions, in: project)
        resource.subtaskAssignments.forEach { $0.assignee = nil }
        resource.archivedAt = stamp
        try save(project, kind: .archived, taskIDs: transitions.map(\.taskID),
                 summary: "Archived \(resource.displayName)", payload: payload)
    }

    /// Archives a person and every membership, in one save across all their boards. Each
    /// board gets an informational entry; `undoPersonArchive(group:)` reverses the group.
    @discardableResult
    func archivePerson(_ person: KanbanPerson) throws -> UUID {
        try RecurrenceMaterializer.checkpoint(context)
        guard person.archivedAt == nil else { throw KanbanServiceError.invariant("\(person.name) is already archived.") }
        let group = UUID(), stamp = now()
        // Prepare every board's entry first; nothing has changed yet.
        var entries: [(KanbanProject, KanbanResource, KanbanActivityPayload, Data)] = []
        for resource in person.memberships where resource.archivedAt == nil {
            guard let project = resource.project else { continue }
            let payload = KanbanActivityPayload(
                transitions: unassignTransitions(resource),
                changes: [KanbanFieldChange(entity: .resource, id: resource.id, field: "archivedAt", old: nil, new: .date(stamp))]
                    + subtaskUnassignChanges(resource),
                groupID: group)
            entries.append((project, resource, payload, try payload.encoded()))
        }
        for (project, resource, payload, data) in entries {
            applyTransitions(payload.transitions, in: project)
            resource.subtaskAssignments.forEach { $0.assignee = nil }
            resource.archivedAt = stamp
            appendActivity(project, kind: .memberArchived, taskIDs: payload.transitions.map(\.taskID),
                           summary: "\(person.name) archived", payload: data)
        }
        person.archivedAt = stamp
        try saveOrUndo()
        return group
    }

    /// Reverses `archivePerson` for one group, atomically: refuses as a whole if any task
    /// changed since, unless `membershipsOnly` (then tasks stay Unassigned).
    func undoPersonArchive(_ person: KanbanPerson, group: UUID, membershipsOnly: Bool = false) throws {
        try RecurrenceMaterializer.checkpoint(context)
        let entries = try context.fetch(FetchDescriptor<KanbanActivity>())
            .filter { $0.kindRaw == KanbanActivityKind.memberArchived.rawValue }
            .compactMap { activity -> (KanbanActivity, KanbanActivityPayload)? in
                guard let payload = try? KanbanActivityPayload.decode(activity.payload), payload.groupID == group else { return nil }
                return (activity, payload)
            }
        guard !entries.isEmpty, entries.allSatisfy({ $0.0.revertedByActivityID == nil }) else { throw KanbanServiceError.notFound }
        if !membershipsOnly {
            var conflicts: [String] = []
            for (activity, payload) in entries {
                guard let project = activity.project else { continue }
                for t in payload.transitions where !isAt(t.to, task(t.taskID, in: project)) {
                    conflicts.append(task(t.taskID, in: project)?.title ?? "a deleted card")
                }
            }
            guard conflicts.isEmpty else {
                throw KanbanServiceError.conflict("These cards changed since: \(conflicts.joined(separator: ", ")).")
            }
        }
        let inverses = try entries.map { activity, payload -> (KanbanActivity, KanbanActivityPayload, Data) in
            let inverse = KanbanActivityPayload(transitions: membershipsOnly ? [] : payload.transitions.map(\.reversed),
                                                changes: payload.changes.map(\.reversed), groupID: group)
            return (activity, inverse, try inverse.encoded())
        }
        for (activity, inverse, data) in inverses {
            guard let project = activity.project else { continue }
            applyTransitions(inverse.transitions, in: project)
            for change in inverse.changes where change.entity == .resource { setResource(change, in: project) }
            for change in inverse.changes where change.entity == .subtask && !membershipsOnly { setSubtask(change, in: project) }
            let entry = appendActivity(project, kind: .restored, taskIDs: inverse.transitions.map(\.taskID),
                                       summary: "\(person.name) restored", payload: data)
            entry.revertsActivityID = activity.id
            activity.revertedByActivityID = entry.id
        }
        person.archivedAt = nil
        try saveOrUndo()
    }

    /// Hard-deletes a person; refused while they have any membership, archived included.
    func deletePerson(_ person: KanbanPerson) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard person.memberships.isEmpty else {
            throw KanbanServiceError.invariant("\(person.name) is still on a board; archive them instead.")
        }
        context.delete(person)
        try saveOrUndo()
    }

    // MARK: - Columns

    @discardableResult
    func addColumn(to project: KanbanProject, name: String, at index: Int? = nil) throws -> KanbanColumn {
        try RecurrenceMaterializer.checkpoint(context)
        let ordered = project.orderedColumns
        let column = KanbanColumn(name: name, kind: .active)
        context.insert(column)
        column.project = project
        var order = ordered
        order.insert(column, at: min(max(index ?? order.count, 0), order.count))
        let changes = renumber(order)
        try save(project, kind: .structure, taskIDs: [], summary: "Added column \(name)",
                 payload: KanbanActivityPayload(changes: changes, graph: KanbanRemovedGraph(columns: [KanbanColumnDTO(column)])))
        return column
    }

    func reorderColumn(_ column: KanbanColumn, to index: Int) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = column.project else { throw KanbanServiceError.notFound }
        var order = project.orderedColumns
        guard let from = order.firstIndex(where: { $0.id == column.id }), order.indices.contains(index), from != index else { return }
        order.insert(order.remove(at: from), at: index)
        try save(project, kind: .structure, taskIDs: [], summary: "Moved column \(column.name)",
                 payload: KanbanActivityPayload(changes: renumber(order)))
    }

    /// Edits a column's name, colour or WIP limit. A kind change is allowed only on an
    /// empty column and can't remove the board's backlog or last Done column.
    func editColumn(_ column: KanbanColumn, name: String? = nil, colorHex: String?? = nil,
                    wipLimit: Int?? = nil, kind: KanbanColumnKind? = nil) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = column.project else { throw KanbanServiceError.notFound }
        if let kind, kind != column.kind {
            guard column.tasks.isEmpty else { throw KanbanServiceError.invariant("Move this column's cards out first.") }
            if column.kind == .backlog || kind == .backlog {
                throw KanbanServiceError.invariant("Use “Make this the backlog” to move the backlog role.")
            }
            if column.kind == .done, project.columns.filter({ $0.kind == .done }).count == 1 {
                throw KanbanServiceError.invariant("A board needs at least one Done column.")
            }
        }
        var changes: [KanbanFieldChange] = []
        if let name, name != column.name { changes.append(.init(entity: .column, id: column.id, field: "name", old: .string(column.name), new: .string(name))) }
        if let colorHex, colorHex != column.colorHex { changes.append(.init(entity: .column, id: column.id, field: "colorHex", old: column.colorHex.map(KanbanValue.string), new: colorHex.map(KanbanValue.string))) }
        if let wipLimit, wipLimit != column.wipLimit { changes.append(.init(entity: .column, id: column.id, field: "wipLimit", old: column.wipLimit.map(KanbanValue.int), new: wipLimit.map(KanbanValue.int))) }
        if let kind, kind != column.kind { changes.append(.init(entity: .column, id: column.id, field: "kind", old: .string(column.kindRaw), new: .string(kind.rawValue))) }
        guard !changes.isEmpty else { return }
        let payload = KanbanActivityPayload(changes: changes)
        let data = try payload.encoded()
        changes.forEach { setColumn($0, in: project) }
        try save(project, kind: .structure, taskIDs: [], summary: "Edited column \(column.name)", encodedPayload: data)
    }

    /// Moves the backlog role to `column`; both columns must be empty.
    func makeBacklog(_ column: KanbanColumn) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = column.project, column.kind != .backlog,
              let backlog = project.columns.first(where: { $0.kind == .backlog }) else { return }
        guard column.tasks.isEmpty, backlog.tasks.isEmpty else { throw KanbanServiceError.invariant("Both columns must be empty.") }
        if column.kind == .done, project.columns.filter({ $0.kind == .done }).count == 1 {
            throw KanbanServiceError.invariant("A board needs at least one Done column.")
        }
        let changes = [
            KanbanFieldChange(entity: .column, id: backlog.id, field: "kind", old: .string("backlog"), new: .string(column.kindRaw)),
            KanbanFieldChange(entity: .column, id: column.id, field: "kind", old: .string(column.kindRaw), new: .string("backlog")),
        ]
        let data = try KanbanActivityPayload(changes: changes).encoded()
        changes.forEach { setColumn($0, in: project) }
        try save(project, kind: .structure, taskIDs: [], summary: "\(column.name) is now the backlog", encodedPayload: data)
    }

    /// Deletes a column after moving its cards to `target` (with completion transitions).
    /// The backlog and the last Done column can't be deleted.
    func deleteColumn(_ column: KanbanColumn, movingTasksTo target: KanbanColumn?) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = column.project else { throw KanbanServiceError.notFound }
        guard column.kind != .backlog else { throw KanbanServiceError.invariant("The backlog column can't be deleted.") }
        if column.kind == .done, project.columns.filter({ $0.kind == .done }).count == 1 {
            throw KanbanServiceError.invariant("A board needs at least one Done column.")
        }
        var moves: [KanbanTransition] = []
        let cards = column.tasks.filter { $0.archivedAt == nil }
        if !column.tasks.isEmpty {
            guard let target, target.id != column.id, target.project?.id == project.id else {
                throw KanbanServiceError.invariant("Choose a column for this column's cards.")
            }
            let snapshot = BoardSnapshot.make(project: project)
            let plan = KanbanMoves.plan(.cards(cards.map(\.id), to: .columnHeader(target.id)), in: snapshot, now: now())
            moves = transitions(for: plan, in: project)
            // Archived cards in the column go too, keeping their place in the order.
            for card in column.tasks where card.archivedAt != nil {
                let from = placement(card)
                var to = from
                to.columnID = target.id; to.columnName = target.name; to.columnKind = target.kindRaw
                to.completedAt = target.kind == .done ? (column.kind == .done ? card.completedAt : now()) : nil
                moves.append(KanbanTransition(taskID: card.id, from: from, to: to))
            }
        }
        let order = project.orderedColumns.filter { $0.id != column.id }
        let payload = KanbanActivityPayload(transitions: moves, changes: renumberChanges(order),
                                            graph: KanbanRemovedGraph(columns: [KanbanColumnDTO(column)]))
        let data = try payload.encoded()
        applyTransitions(moves, in: project)
        _ = renumber(order)
        context.delete(column)   // last: deletions follow every fallible step
        try save(project, kind: .deleted, taskIDs: moves.map(\.taskID), summary: "Deleted column \(column.name)",
                 encodedPayload: data)
    }

    // MARK: - Tasks

    @discardableResult
    func createTask(in project: KanbanProject, title: String, column: KanbanColumn? = nil,
                    row: KanbanRowKey = .unassigned, before: UUID? = nil) throws -> KanbanTask {
        try RecurrenceMaterializer.checkpoint(context)
        guard let column = column ?? project.columns.first(where: { $0.kind == .backlog }), column.project?.id == project.id
        else { throw KanbanServiceError.invariant("Pick a column on this board.") }
        let resource = try resource(for: row, in: project)
        let task = KanbanTask(title: title)
        task.createdAt = now(); task.updatedAt = now()
        if column.kind == .done { task.completedAt = now() }
        context.insert(task)
        task.project = project; task.column = column; task.resource = resource
        // Place it among its cell (before `before`, or last), renumbering densely.
        var cell = project.tasks.filter { $0.id != task.id && $0.archivedAt == nil && $0.column?.id == column.id && $0.resource?.id == resource?.id }
            .sorted { $0.sortIndex < $1.sortIndex }
        cell.insert(task, at: before.flatMap { id in cell.firstIndex { $0.id == id } } ?? cell.count)
        for (index, card) in cell.enumerated() { card.sortIndex = Double(index) }
        try save(project, kind: .created, taskIDs: [task.id], summary: "Added \(title)",
                 payload: KanbanActivityPayload(transitions: [KanbanTransition(taskID: task.id, from: placement(task), to: placement(task))],
                                                graph: KanbanRemovedGraph(tasks: [KanbanTaskDTO(task)])))
        return task
    }

    /// Applies a move (drag, keyboard, bulk). Returns the WIP outcome so the UI can warn;
    /// a blocking policy throws instead.
    @discardableResult
    func move(_ op: MoveOp, in project: KanbanProject) throws -> WIPOutcome {
        try RecurrenceMaterializer.checkpoint(context)
        let plan = KanbanMoves.plan(op, in: BoardSnapshot.make(project: project), now: now())
        if case let .blocked(columns) = plan.wip { throw KanbanServiceError.wipBlocked(columns) }
        if let order = plan.columnOrder {
            let columns = order.compactMap { id in project.columns.first { $0.id == id } }
            try save(project, kind: .structure, taskIDs: [], summary: "Reordered columns", payload: KanbanActivityPayload(changes: renumber(columns)))
            return .ok
        }
        if let order = plan.rowOrder {
            let rows = order.compactMap { id in project.resources.first { $0.id == id } }
            let changes = rows.enumerated().compactMap { index, row -> KanbanFieldChange? in
                guard row.sortIndex != Double(index) else { return nil }
                defer { row.sortIndex = Double(index) }
                return .init(entity: .resource, id: row.id, field: "sortIndex", old: .double(row.sortIndex), new: .double(Double(index)))
            }
            try save(project, kind: .structure, taskIDs: [], summary: "Reordered rows", payload: KanbanActivityPayload(changes: changes))
            return .ok
        }
        guard !plan.isNoOp else { return plan.wip }
        let transitions = transitions(for: plan, in: project)
        let data = try KanbanActivityPayload(transitions: transitions).encoded()
        applyTransitions(transitions, in: project)
        try save(project, kind: .moved, taskIDs: transitions.map(\.taskID), summary: moveSummary(transitions, in: project),
                 encodedPayload: data)
        return plan.wip
    }

    /// The editable fields of a card.
    enum TaskField: String, CaseIterable {
        case title, notes, notesRich, priority, isCritical, dueDate, startDate, estimateHours, jiraURL, isBlocked, blockedReason
    }

    /// Edits card fields; only changed fields are recorded.
    func edit(_ task: KanbanTask, _ values: [TaskField: KanbanValue?]) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = task.project else { throw KanbanServiceError.notFound }
        let changes = values.compactMap { field, value -> KanbanFieldChange? in
            let old = taskValue(task, field.rawValue)
            return old == value ? nil : KanbanFieldChange(entity: .task, id: task.id, field: field.rawValue, old: old, new: value)
        }.sorted { $0.field < $1.field }
        guard !changes.isEmpty else { return }
        let data = try KanbanActivityPayload(changes: changes).encoded()
        changes.forEach { setTask($0, in: project) }
        task.updatedAt = now()
        try save(project, kind: .edited, taskIDs: [task.id], summary: "Edited \(task.title)", encodedPayload: data)
    }

    /// Replaces a card's labels.
    func setLabels(_ task: KanbanTask, _ labels: [KanbanLabel]) throws {
        try setRelation(task, field: "labels", ids: labels.map(\.id))
    }

    /// Replaces a card's prerequisites; refuses self edges and cycles.
    func setDependencies(_ task: KanbanTask, _ prerequisites: [KanbanTask]) throws {
        guard let project = task.project else { throw KanbanServiceError.notFound }
        for prerequisite in prerequisites {
            guard prerequisite.project?.id == project.id else { throw KanbanServiceError.invariant("Dependencies stay within a board.") }
            if prerequisite.id == task.id || dependsTransitively(prerequisite, on: task) {
                throw KanbanServiceError.invariant("“\(prerequisite.title)” already depends on this card.")
            }
        }
        try setRelation(task, field: "dependsOn", ids: prerequisites.map(\.id))
    }

    func archiveTask(_ task: KanbanTask) throws { try setArchived(task, archived: true) }
    func restoreTask(_ task: KanbanTask) throws { try setArchived(task, archived: false) }

    /// Hard-deletes a card (from the Archive view), keeping a graph that Revert can re-insert.
    func deleteTask(_ task: KanbanTask) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = task.project else { throw KanbanServiceError.notFound }
        let graph = KanbanRemovedGraph(tasks: [KanbanTaskDTO(task)], subtasks: task.subtasks.map(KanbanSubtaskDTO.init),
                                       incomingDependencies: task.dependents.map { [$0.id, task.id] })
        let data = try KanbanActivityPayload(graph: graph).encoded()
        let title = task.title, id = task.id
        context.delete(task)   // last: its subtasks cascade, its edges are nullified
        try save(project, kind: .deleted, taskIDs: [id], summary: "Deleted \(title)", encodedPayload: data)
    }

    // MARK: - Subtasks

    @discardableResult
    func addSubtask(to task: KanbanTask, title: String) throws -> KanbanSubtask {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = task.project else { throw KanbanServiceError.notFound }
        let subtask = KanbanSubtask(title: title, sortIndex: (task.subtasks.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(subtask)
        subtask.task = task
        try save(project, kind: .created, taskIDs: [task.id], summary: "Added step to \(task.title)",
                 payload: KanbanActivityPayload(graph: KanbanRemovedGraph(subtasks: [KanbanSubtaskDTO(subtask)])))
        return subtask
    }

    /// Ticks or unticks a step. Returns whether to suggest moving the card to Done (its last
    /// open step was just ticked and the board allows the suggestion). Never moves the card.
    @discardableResult
    func setSubtaskDone(_ subtask: KanbanSubtask, _ done: Bool) throws -> Bool {
        try RecurrenceMaterializer.checkpoint(context)
        guard let task = subtask.task, let project = task.project, subtask.isDone != done else { return false }
        let stamp = done ? now() : nil
        let changes = [
            KanbanFieldChange(entity: .subtask, id: subtask.id, field: "isDone", old: .bool(subtask.isDone), new: .bool(done)),
            KanbanFieldChange(entity: .subtask, id: subtask.id, field: "completedAt", old: subtask.completedAt.map(KanbanValue.date), new: stamp.map(KanbanValue.date)),
        ]
        let data = try KanbanActivityPayload(changes: changes).encoded()
        changes.forEach { setSubtask($0, in: project) }
        try save(project, kind: .edited, taskIDs: [task.id], summary: "\(done ? "Finished" : "Reopened") \(subtask.title)", encodedPayload: data)
        return done && project.suggestDoneWhenSubtasksComplete && task.column?.kind != .done && task.subtasks.allSatisfy(\.isDone)
    }

    func deleteSubtask(_ subtask: KanbanSubtask) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let task = subtask.task, let project = task.project else { throw KanbanServiceError.notFound }
        let data = try KanbanActivityPayload(graph: KanbanRemovedGraph(subtasks: [KanbanSubtaskDTO(subtask)])).encoded()
        context.delete(subtask)
        try save(project, kind: .deleted, taskIDs: [task.id], summary: "Removed a step from \(task.title)", encodedPayload: data)
    }

    /// Steps in display order: open ones by position, then finished ones by completion.
    static func orderedSubtasks(_ task: KanbanTask) -> [KanbanSubtask] {
        task.subtasks.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            if a.isDone, a.completedAt != b.completedAt { return (a.completedAt ?? .distantPast) < (b.completedAt ?? .distantPast) }
            return a.sortIndex < b.sortIndex
        }
    }

    // MARK: - Revert (undo, redo, Change Log)

    /// Applies the inverse of `activity` as a new entry, after checking that every row it
    /// touched still holds the values it left. Refuses before changing anything otherwise.
    @discardableResult
    func revert(_ activity: KanbanActivity, recordAsUserOperation: Bool = true) throws -> KanbanActivity {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = activity.project, let kind = KanbanActivityKind(rawValue: activity.kindRaw) else { throw KanbanServiceError.notFound }
        guard activity.revertedByActivityID == nil else { throw KanbanServiceError.conflict("That change was already reverted.") }
        let payload = try KanbanActivityPayload.decode(activity.payload)
        // Informational entries (a board's creation, a person archive's per-board record,
        // scheduling to the planner) have no board-level inverse.
        let informational = kind == .structure && payload.changes.isEmpty && payload.graph == nil
        guard ![.memberArchived, .scheduled].contains(kind), !informational else {
            throw KanbanServiceError.conflict("That change can't be reverted here.")
        }
        let inverse = try inverse(of: kind, payload, in: project)
        let data = try inverse.payload.encoded()
        inverse.apply()
        let entry = appendActivity(project, kind: inverse.kind, taskIDs: activity.taskIDs, summary: "Reverted: \(activity.summary)", payload: data)
        entry.revertsActivityID = activity.id
        activity.revertedByActivityID = entry.id
        try saveOrUndo()
        if recordAsUserOperation { history?.recordUserOperation(entry.id, project: project.id) }
        return entry
    }

    /// ⌘Z: reverts the newest user operation on the board's undo stack.
    func undo(in project: KanbanProject) throws {
        guard let history, let id = history.peekUndo(project.id), let activity = try activity(id) else { return }
        let inverse = try revert(activity, recordAsUserOperation: false)
        history.didUndo(original: id, inverse: inverse.id, project: project.id)
    }

    /// ⇧⌘Z: re-applies the most recently undone operation by reverting its inverse.
    func redo(in project: KanbanProject) throws {
        guard let history, let original = history.peekRedo(project.id),
              let inverseID = try activity(original)?.revertedByActivityID, let inverse = try activity(inverseID) else { return }
        let reapplied = try revert(inverse, recordAsUserOperation: false)
        history.didRedo(original: original, reapplied: reapplied.id, project: project.id)
    }

    // MARK: - Internals: persistence

    /// For changes made before their payload was encoded: an encoding failure undoes them in place.
    private func save(_ project: KanbanProject, kind: KanbanActivityKind, taskIDs: [UUID], summary: String,
                      payload: KanbanActivityPayload, undoable: Bool = true) throws {
        let data: Data
        do { data = try payload.encoded() } catch { context.undoFailedTransaction(); throw error }
        try save(project, kind: kind, taskIDs: taskIDs, summary: summary, encodedPayload: data, undoable: undoable)
    }

    /// Appends the entry and saves once. Callers encode the payload before mutating, so the
    /// only fallible step left after the first change is this save.
    private func save(_ project: KanbanProject, kind: KanbanActivityKind, taskIDs: [UUID], summary: String,
                      encodedPayload: Data, undoable: Bool = true) throws {
        let entry = appendActivity(project, kind: kind, taskIDs: taskIDs, summary: summary, payload: encodedPayload)
        try saveOrUndo()
        if undoable { history?.recordUserOperation(entry.id, project: project.id) }
    }

    @discardableResult
    private func appendActivity(_ project: KanbanProject, kind: KanbanActivityKind, taskIDs: [UUID], summary: String,
                                payload: Data) -> KanbanActivity {
        let entry = KanbanActivity(seq: project.nextActivitySeq, at: now(), kind: kind.rawValue, taskIDs: taskIDs,
                                   summary: summary, payload: payload)
        context.insert(entry)
        entry.project = project
        project.nextActivitySeq += 1
        project.updatedAt = now()
        return entry
    }

    private func saveOrUndo() throws {
        do {
            try context.saveTransaction()
        } catch {
            context.undoFailedTransaction()
            generation?.bump()
            throw error
        }
        generation?.bump()
    }

    private func activity(_ id: UUID) throws -> KanbanActivity? {
        try context.fetch(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: - Internals: placements and transitions

    private func placement(_ task: KanbanTask) -> KanbanPlacementRecord {
        KanbanPlacementRecord(columnID: task.column?.id ?? UUID(), columnName: task.column?.name ?? "",
                              columnKind: task.column?.kindRaw ?? KanbanColumnKind.active.rawValue,
                              resourceID: task.resource?.id, sortIndex: task.sortIndex, completedAt: task.completedAt)
    }

    private func record(_ placement: Placement, in project: KanbanProject) -> KanbanPlacementRecord {
        let column = project.columns.first { $0.id == placement.columnID }
        var resourceID: UUID?
        if case let .resource(id) = placement.row { resourceID = id }
        return KanbanPlacementRecord(columnID: placement.columnID, columnName: column?.name ?? "",
                                     columnKind: column?.kindRaw ?? KanbanColumnKind.active.rawValue,
                                     resourceID: resourceID, sortIndex: placement.sortIndex, completedAt: placement.completedAt)
    }

    private func transitions(for plan: MovePlan, in project: KanbanProject) -> [KanbanTransition] {
        plan.cardChanges.map { KanbanTransition(taskID: $0.id, from: record($0.from, in: project), to: record($0.to, in: project)) }
    }

    private func task(_ id: UUID, in project: KanbanProject) -> KanbanTask? { project.tasks.first { $0.id == id } }

    private func isAt(_ placement: KanbanPlacementRecord, _ task: KanbanTask?) -> Bool {
        guard let task else { return false }
        return task.column?.id == placement.columnID && task.resource?.id == placement.resourceID
            && task.sortIndex == placement.sortIndex && task.completedAt == placement.completedAt
    }

    private func applyTransitions(_ transitions: [KanbanTransition], in project: KanbanProject) {
        for t in transitions {
            guard let task = task(t.taskID, in: project) else { continue }
            if let column = project.columns.first(where: { $0.id == t.to.columnID }) { task.column = column }
            task.resource = t.to.resourceID.flatMap { id in project.resources.first { $0.id == id } }
            task.sortIndex = t.to.sortIndex
            task.completedAt = t.to.completedAt
            task.updatedAt = now()
        }
    }

    /// The moves that send a membership's cards to the bottom of each Unassigned cell.
    private func unassignTransitions(_ resource: KanbanResource) -> [KanbanTransition] {
        guard let project = resource.project, !resource.tasks.isEmpty else { return [] }
        var transitions: [KanbanTransition] = []
        let byColumn = Dictionary(grouping: resource.tasks) { $0.column?.id ?? UUID() }
        for (columnID, cards) in byColumn {
            var next = (project.tasks.filter { $0.column?.id == columnID && $0.resource == nil }.map(\.sortIndex).max() ?? -1) + 1
            for card in cards.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                var to = placement(card)
                to.resourceID = nil; to.sortIndex = next
                next += 1
                transitions.append(KanbanTransition(taskID: card.id, from: placement(card), to: to))
            }
        }
        return transitions.sorted { $0.taskID.uuidString < $1.taskID.uuidString }
    }

    private func subtaskUnassignChanges(_ resource: KanbanResource) -> [KanbanFieldChange] {
        resource.subtaskAssignments.map {
            KanbanFieldChange(entity: .subtask, id: $0.id, field: "assignee", old: .uuid(resource.id), new: nil)
        }
    }

    private func resource(for row: KanbanRowKey, in project: KanbanProject) throws -> KanbanResource? {
        guard case let .resource(id) = row else { return nil }
        guard let resource = project.resources.first(where: { $0.id == id && $0.archivedAt == nil }) else {
            throw KanbanServiceError.invariant("That person isn't on this board.")
        }
        return resource
    }

    private func moveSummary(_ transitions: [KanbanTransition], in project: KanbanProject) -> String {
        let moved = transitions.filter { $0.from.columnID != $0.to.columnID || $0.from.resourceID != $0.to.resourceID }
        guard let first = moved.first else { return "Reordered cards" }
        if moved.count > 1 { return "Moved \(moved.count) cards" }
        return "Moved \(task(first.taskID, in: project)?.title ?? "a card")"
    }

    // MARK: - Internals: ordering

    /// Dense sort indices for `columns`; returns the changes it made.
    @discardableResult
    private func renumber(_ columns: [KanbanColumn]) -> [KanbanFieldChange] {
        let changes = renumberChanges(columns)
        for (index, column) in columns.enumerated() { column.sortIndex = Double(index) }
        return changes
    }

    private func renumberChanges(_ columns: [KanbanColumn]) -> [KanbanFieldChange] {
        columns.enumerated().compactMap { index, column in
            column.sortIndex == Double(index) ? nil
                : .init(entity: .column, id: column.id, field: "sortIndex", old: .double(column.sortIndex), new: .double(Double(index)))
        }
    }

    // MARK: - Internals: archive and relations

    private func setArchived(_ task: KanbanTask, archived: Bool) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = task.project, (task.archivedAt == nil) == archived else { return }
        let stamp = archived ? now() : nil
        let change = KanbanFieldChange(entity: .task, id: task.id, field: "archivedAt",
                                       old: task.archivedAt.map(KanbanValue.date), new: stamp.map(KanbanValue.date))
        let data = try KanbanActivityPayload(changes: [change]).encoded()
        task.archivedAt = stamp
        try save(project, kind: archived ? .archived : .restored, taskIDs: [task.id],
                 summary: "\(archived ? "Archived" : "Restored") \(task.title)", encodedPayload: data)
    }

    private func setRelation(_ task: KanbanTask, field: String, ids: [UUID]) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = task.project else { throw KanbanServiceError.notFound }
        let old = taskValue(task, field), new = KanbanValue.uuids(ids.sorted { $0.uuidString < $1.uuidString })
        guard old != new else { return }
        let change = KanbanFieldChange(entity: .task, id: task.id, field: field, old: old, new: new)
        let data = try KanbanActivityPayload(changes: [change]).encoded()
        setTask(change, in: project)
        task.updatedAt = now()
        try save(project, kind: .edited, taskIDs: [task.id], summary: "Edited \(task.title)", encodedPayload: data)
    }

    private func dependsTransitively(_ task: KanbanTask, on target: KanbanTask) -> Bool {
        var stack = task.dependsOn, seen: Set<UUID> = []
        while let next = stack.popLast() {
            if next.id == target.id { return true }
            if seen.insert(next.id).inserted { stack.append(contentsOf: next.dependsOn) }
        }
        return false
    }

    // MARK: - Internals: field access (one place that knows every editable field)

    private func taskValue(_ task: KanbanTask, _ field: String) -> KanbanValue? {
        switch field {
        case "title": return .string(task.title)
        case "notes": return .string(task.notes)
        case "notesRich": return task.notesRich.map(KanbanValue.data)
        case "priority": return .int(task.priority)
        case "isCritical": return .bool(task.isCritical)
        case "dueDate": return task.dueDate.map(KanbanValue.date)
        case "startDate": return task.startDate.map(KanbanValue.date)
        case "estimateHours": return task.estimateHours.map(KanbanValue.double)
        case "jiraURL": return task.jiraURL.map(KanbanValue.string)
        case "isBlocked": return .bool(task.isBlocked)
        case "blockedReason": return task.blockedReason.map(KanbanValue.string)
        case "archivedAt": return task.archivedAt.map(KanbanValue.date)
        case "labels": return .uuids(task.labels.map(\.id).sorted { $0.uuidString < $1.uuidString })
        case "dependsOn": return .uuids(task.dependsOn.map(\.id).sorted { $0.uuidString < $1.uuidString })
        default: return nil
        }
    }

    private func setTask(_ change: KanbanFieldChange, in project: KanbanProject) {
        guard let task = task(change.id, in: project) else { return }
        let v = change.new
        switch change.field {
        case "title": if case let .string(s)? = v { task.title = s }
        case "notes": if case let .string(s)? = v { task.notes = s }
        case "notesRich": if case let .data(d)? = v { task.notesRich = d } else { task.notesRich = nil }
        case "priority": if case let .int(i)? = v { task.priority = min(max(i, 0), 2) }
        case "isCritical": if case let .bool(b)? = v { task.isCritical = b }
        case "dueDate": if case let .date(d)? = v { task.dueDate = d } else { task.dueDate = nil }
        case "startDate": if case let .date(d)? = v { task.startDate = d } else { task.startDate = nil }
        case "estimateHours": if case let .double(d)? = v { task.estimateHours = d } else { task.estimateHours = nil }
        case "jiraURL": if case let .string(s)? = v { task.jiraURL = s } else { task.jiraURL = nil }
        case "isBlocked": if case let .bool(b)? = v { task.isBlocked = b }
        case "blockedReason": if case let .string(s)? = v { task.blockedReason = s } else { task.blockedReason = nil }
        case "archivedAt": if case let .date(d)? = v { task.archivedAt = d } else { task.archivedAt = nil }
        case "labels":
            if case let .uuids(ids)? = v { task.labels = project.labels.filter { ids.contains($0.id) } }
        case "dependsOn":
            if case let .uuids(ids)? = v { task.dependsOn = project.tasks.filter { ids.contains($0.id) && $0.id != task.id } }
        default: break
        }
    }

    private func columnValue(_ column: KanbanColumn, _ field: String) -> KanbanValue? {
        switch field {
        case "name": return .string(column.name)
        case "colorHex": return column.colorHex.map(KanbanValue.string)
        case "wipLimit": return column.wipLimit.map(KanbanValue.int)
        case "kind": return .string(column.kindRaw)
        case "sortIndex": return .double(column.sortIndex)
        default: return nil
        }
    }

    private func setColumn(_ change: KanbanFieldChange, in project: KanbanProject) {
        guard let column = project.columns.first(where: { $0.id == change.id }) else { return }
        switch (change.field, change.new) {
        case let ("name", .string(s)?): column.name = s
        case let ("colorHex", .string(s)?): column.colorHex = s
        case ("colorHex", nil): column.colorHex = nil
        case let ("wipLimit", .int(i)?): column.wipLimit = i
        case ("wipLimit", nil): column.wipLimit = nil
        case let ("kind", .string(s)?): column.kindRaw = s
        case let ("sortIndex", .double(d)?): column.sortIndex = d
        default: break
        }
    }

    private func resourceValue(_ resource: KanbanResource, _ field: String) -> KanbanValue? {
        switch field {
        case "archivedAt": return resource.archivedAt.map(KanbanValue.date)
        case "sortIndex": return .double(resource.sortIndex)
        default: return nil
        }
    }

    private func setResource(_ change: KanbanFieldChange, in project: KanbanProject) {
        guard let resource = project.resources.first(where: { $0.id == change.id }) else { return }
        switch (change.field, change.new) {
        case let ("archivedAt", .date(d)?): resource.archivedAt = d
        case ("archivedAt", nil): resource.archivedAt = nil
        case let ("sortIndex", .double(d)?): resource.sortIndex = d
        default: break
        }
    }

    private func subtaskValue(_ subtask: KanbanSubtask, _ field: String) -> KanbanValue? {
        switch field {
        case "isDone": return .bool(subtask.isDone)
        case "completedAt": return subtask.completedAt.map(KanbanValue.date)
        case "assignee": return subtask.assignee.map { .uuid($0.id) }
        default: return nil
        }
    }

    private func setSubtask(_ change: KanbanFieldChange, in project: KanbanProject) {
        guard let subtask = project.tasks.lazy.flatMap(\.subtasks).first(where: { $0.id == change.id }) else { return }
        switch (change.field, change.new) {
        case let ("isDone", .bool(b)?): subtask.isDone = b
        case let ("completedAt", .date(d)?): subtask.completedAt = d
        case ("completedAt", nil): subtask.completedAt = nil
        case let ("assignee", .uuid(id)?): subtask.assignee = project.resources.first { $0.id == id }
        case ("assignee", nil): subtask.assignee = nil
        default: break
        }
    }

    private func currentValue(_ change: KanbanFieldChange, in project: KanbanProject) -> KanbanValue?? {
        switch change.entity {
        case .task: return task(change.id, in: project).map { taskValue($0, change.field) }
        case .column: return project.columns.first { $0.id == change.id }.map { columnValue($0, change.field) }
        case .resource: return project.resources.first { $0.id == change.id }.map { resourceValue($0, change.field) }
        case .subtask: return project.tasks.lazy.flatMap(\.subtasks).first { $0.id == change.id }.map { subtaskValue($0, change.field) }
        case .label, .project: return nil
        }
    }

    private func set(_ change: KanbanFieldChange, in project: KanbanProject) {
        switch change.entity {
        case .task: setTask(change, in: project)
        case .column: setColumn(change, in: project)
        case .resource: setResource(change, in: project)
        case .subtask: setSubtask(change, in: project)
        case .label, .project: break
        }
    }

    // MARK: - Internals: inverses

    private struct Inverse {
        var kind: KanbanActivityKind
        var payload: KanbanActivityPayload
        var apply: () -> Void
    }

    /// The inverse of an entry, after its conflict checks. Throws `.conflict` (before any
    /// mutation) when a row it touched has changed since.
    private func inverse(of kind: KanbanActivityKind, _ payload: KanbanActivityPayload, in project: KanbanProject) throws -> Inverse {
        // Every field must still hold the value this entry left.
        for change in payload.changes {
            guard let current = currentValue(change, in: project) else {
                if change.entity == .resource, change.field == "archivedAt", change.old == .date(.distantPast) { continue }
                throw KanbanServiceError.conflict("Something this change touched no longer exists.")
            }
            guard current == change.new else {
                throw KanbanServiceError.conflict("This changed again after that entry. Revert the newer changes first.")
            }
        }
        for t in payload.transitions where !(kind == .created) {
            guard isAt(t.to, task(t.taskID, in: project)) else {
                throw KanbanServiceError.conflict("“\(task(t.taskID, in: project)?.title ?? "A card")” moved again after that entry. Revert the newer changes first.")
            }
        }
        let reversedChanges = payload.changes.map(\.reversed)
        let reversedTransitions = payload.transitions.map(\.reversed)

        switch kind {
        case .structure where payload.graph != nil:
            break
        case .moved, .edited, .archived, .restored, .structure:
            let inverseKind: KanbanActivityKind = kind == .archived ? .restored : kind == .restored ? .archived : kind
            return Inverse(kind: inverseKind, payload: KanbanActivityPayload(transitions: reversedTransitions, changes: reversedChanges)) {
                applyTransitions(reversedTransitions, in: project)
                reversedChanges.forEach { set($0, in: project) }
            }

        case .deleted, .restoredGraph:
            return try reinsert(payload, reversedTransitions: reversedTransitions, reversedChanges: reversedChanges, in: project)
        case .memberArchived, .scheduled:
            throw KanbanServiceError.conflict("That change can't be reverted here.")
        case .created:
            break
        }

        if kind == .structure {
            // Undo of "added a column" or "added a membership": remove the new row.
            let graph = payload.graph ?? KanbanRemovedGraph()
            let addedColumns = graph.columns.compactMap { dto in project.columns.first { $0.id == dto.id } }
            let addedMembership = payload.changes.first { $0.entity == .resource && $0.old == .date(.distantPast) }
                .flatMap { change in project.resources.first { $0.id == change.id } }
            guard addedColumns.allSatisfy(\.tasks.isEmpty) else { throw KanbanServiceError.conflict("That column has cards now.") }
            if let addedMembership, !addedMembership.tasks.isEmpty || !addedMembership.subtaskAssignments.isEmpty {
                throw KanbanServiceError.conflict("\(addedMembership.displayName) has cards now; archive them instead.")
            }
            let removed = KanbanRemovedGraph(columns: addedColumns.map(KanbanColumnDTO.init),
                                             resources: addedMembership.map { [KanbanResourceDTO($0)] } ?? [])
            let restoreOrder = payload.changes.filter { $0.field == "sortIndex" }.map(\.reversed)
            return Inverse(kind: .deleted, payload: KanbanActivityPayload(changes: restoreOrder, graph: removed)) {
                restoreOrder.forEach { set($0, in: project) }
                addedColumns.forEach { context.delete($0) }
                if let addedMembership { context.delete(addedMembership) }
            }
        }

        do {
            // Undo of creating a card or a step: remove it (it must be unchanged).
            let graph = payload.graph ?? KanbanRemovedGraph()
            let cards = graph.tasks.compactMap { dto in task(dto.id, in: project) }
            let steps = graph.subtasks.compactMap { dto in project.tasks.lazy.flatMap(\.subtasks).first { $0.id == dto.id } }
            guard cards.count == graph.tasks.count, steps.count == graph.subtasks.count else {
                throw KanbanServiceError.conflict("What that change added no longer exists.")
            }
            guard cards.allSatisfy({ $0.subtasks.isEmpty && $0.dependents.isEmpty }) else {
                throw KanbanServiceError.conflict("That card has steps or dependents now; archive it instead.")
            }
            let removed = KanbanRemovedGraph(tasks: cards.map(KanbanTaskDTO.init), subtasks: steps.map(KanbanSubtaskDTO.init))
            return Inverse(kind: .deleted, payload: KanbanActivityPayload(graph: removed)) {
                steps.forEach { context.delete($0) }
                cards.forEach { context.delete($0) }
            }
        }
    }

    /// Re-inserts a removed graph (revert of a delete), revalidating every reference first.
    private func reinsert(_ payload: KanbanActivityPayload, reversedTransitions: [KanbanTransition],
                          reversedChanges: [KanbanFieldChange], in project: KanbanProject) throws -> Inverse {
        let graph = payload.graph ?? KanbanRemovedGraph()
        let existing = Set(project.tasks.map(\.id))
        guard graph.tasks.allSatisfy({ !existing.contains($0.id) }), graph.columns.allSatisfy({ c in !project.columns.contains { $0.id == c.id } })
        else { throw KanbanServiceError.conflict("That was already put back.") }
        let columnIDs = Set(project.columns.map(\.id)).union(graph.columns.map(\.id))
        for dto in graph.tasks {
            guard let column = dto.columnId, columnIDs.contains(column) else {
                throw KanbanServiceError.conflict("“\(dto.title)”’s column no longer exists.")
            }
        }
        for dto in graph.resources {
            guard let person = try context.fetch(FetchDescriptor<KanbanPerson>()).first(where: { $0.id == dto.personId }),
                  person.archivedAt == nil
            else { throw KanbanServiceError.conflict("Restore that person in People first.") }
            guard !project.resources.contains(where: { $0.person?.id == dto.personId && $0.archivedAt == nil }) else {
                throw KanbanServiceError.conflict("That person is already on this board.")
            }
        }
        let people = try context.fetch(FetchDescriptor<KanbanPerson>())
        let planner = Set(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.recurrence == nil || $0.templateID != nil }.map(\.id))
        let restored = KanbanActivityPayload(transitions: reversedTransitions, changes: reversedChanges, graph: graph)
        return Inverse(kind: .restoredGraph, payload: restored) {
            var columns = Dictionary(uniqueKeysWithValues: project.columns.map { ($0.id, $0) })
            for dto in graph.columns {
                let column = KanbanColumn(id: dto.id, name: dto.name, kind: KanbanColumnKind(rawValue: dto.kindRaw) ?? .active, sortIndex: dto.sortIndex)
                column.colorHex = dto.colorHex; column.wipLimit = dto.wipLimit
                context.insert(column); column.project = project
                columns[column.id] = column
            }
            for dto in graph.resources {
                let resource = KanbanResource(id: dto.id, person: people.first { $0.id == dto.personId },
                                              assignment: KanbanAssignment(rawValue: dto.assignmentRaw) ?? .fullTime,
                                              allocationPercent: dto.allocationPercent, sortIndex: dto.sortIndex)
                resource.role = dto.role; resource.capacityHoursPerWeekOverride = dto.capacityHoursPerWeekOverride
                resource.openTaskTargetOverride = dto.openTaskTargetOverride; resource.startDate = dto.startDate; resource.endDate = dto.endDate
                context.insert(resource); resource.project = project
            }
            var inserted: [UUID: KanbanTask] = [:]
            for dto in graph.tasks {
                let task = KanbanTask(id: dto.id, title: dto.title, priority: dto.priority, sortIndex: dto.sortIndex)
                task.notes = dto.notes; task.notesRich = dto.notesRich; task.isCritical = dto.isCritical
                task.dueDate = dto.dueDate; task.startDate = dto.startDate; task.estimateHours = dto.estimateHours
                task.jiraURL = dto.jiraURL; task.isBlocked = dto.isBlocked; task.blockedReason = dto.blockedReason
                task.linkedPlannerTaskID = dto.linkedPlannerTaskID.flatMap { planner.contains($0) ? $0 : nil }
                task.createdAt = dto.createdAt; task.updatedAt = dto.updatedAt; task.completedAt = dto.completedAt; task.archivedAt = dto.archivedAt
                context.insert(task)
                task.project = project
                task.column = dto.columnId.flatMap { columns[$0] }
                task.resource = dto.resourceId.flatMap { id in project.resources.first { $0.id == id && $0.archivedAt == nil } }
                task.labels = project.labels.filter { dto.labelIds.contains($0.id) }
                inserted[task.id] = task
            }
            for dto in graph.tasks {
                inserted[dto.id]?.dependsOn = project.tasks.filter { dto.dependsOnIds.contains($0.id) }
            }
            for edge in graph.incomingDependencies where edge.count == 2 {
                if let dependent = project.tasks.first(where: { $0.id == edge[0] }), let prerequisite = inserted[edge[1]] {
                    dependent.dependsOn.append(prerequisite)
                }
            }
            for dto in graph.subtasks {
                guard let owner = project.tasks.first(where: { $0.id == dto.taskId }) else { continue }
                let subtask = KanbanSubtask(id: dto.id, title: dto.title, isDone: dto.isDone, sortIndex: dto.sortIndex)
                subtask.completedAt = dto.completedAt
                context.insert(subtask); subtask.task = owner
                subtask.assignee = dto.assigneeId.flatMap { id in project.resources.first { $0.id == id && $0.archivedAt == nil } }
            }
            applyTransitions(reversedTransitions, in: project)
            reversedChanges.forEach { set($0, in: project) }
        }
    }
}

extension KanbanFieldChange {
    var reversed: KanbanFieldChange { KanbanFieldChange(entity: entity, id: id, field: field, old: new, new: old) }
}

extension KanbanTransition {
    var reversed: KanbanTransition { KanbanTransition(taskID: taskID, from: to, to: from) }
}
