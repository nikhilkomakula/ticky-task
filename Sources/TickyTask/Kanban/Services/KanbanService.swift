import Foundation
import SwiftData
import Observation

/// Bumped by every Kanban save, rollback and restore; board snapshots and metric caches
/// are keyed by it (design 01 §2.5).
@MainActor @Observable
final class KanbanStoreGeneration {
    private(set) var value = 0
    /// App-wide follow-up to every bump (Kanban reminder sync), whichever window saved.
    @ObservationIgnored var onBump: (() -> Void)?
    func bump() {
        value += 1
        onBump?()
    }
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

    /// A new board with `template`'s columns and labels. Not undoable (archive it instead);
    /// its first change-log entry records the creation.
    @discardableResult
    func createProject(name: String, key: String, template: KanbanTemplate = .standard,
                       defaults: KanbanBoardDefaults = KanbanBoardDefaults(),
                       startDay: String? = nil, endDay: String? = nil) throws -> KanbanProject {
        try RecurrenceMaterializer.checkpoint(context)
        if let problem = template.problem { throw KanbanServiceError.invariant(problem) }
        let existing = try context.fetch(FetchDescriptor<KanbanProject>())
        try Self.checkBoardDates(startDay, endDay)
        let project = KanbanProject(name: name, key: key, sortIndex: (existing.map(\.sortIndex).max() ?? -1) + 1)
        defaults.apply(to: project)
        project.startDay = startDay
        project.endDay = endDay
        context.insert(project)
        for (index, column) in template.columns.enumerated() {
            let model = KanbanColumn(name: column.name, kind: column.kind, sortIndex: Double(index))
            model.colorHex = column.colorHex
            model.symbolName = column.symbolName
            model.wipLimit = column.wipLimit
            context.insert(model)
            model.project = project
        }
        // Built-in templates take Settings › Kanban's default labels; saved templates keep their own.
        for (index, label) in (template.isBuiltIn ? defaults.labelsForNewBoard() : template.labels).enumerated() {
            let model = KanbanLabel(name: label.name, colorHex: label.colorHex, sortIndex: Double(index))
            model.symbolName = label.symbolName
            context.insert(model)
            model.project = project
        }
        try save(project, kind: .structure, taskIDs: [], summary: "Created \(name)", payload: KanbanActivityPayload(), undoable: false)
        return project
    }

    /// A new board with `project`'s columns and labels, and no cards or people.
    @discardableResult
    func duplicateStructure(of project: KanbanProject, name: String, key: String) throws -> KanbanProject {
        try createProject(name: name, key: key, template: KanbanTemplate(from: project, name: name))
    }

    /// Saves `project`'s structure as a user template.
    @discardableResult
    func saveAsTemplate(_ project: KanbanProject, name: String, defaults: UserDefaults = .standard) throws -> KanbanTemplate {
        let template = KanbanTemplate(from: project, name: name)
        try KanbanTemplateStore.save(template, defaults)
        return template
    }

    /// Archives finished cards whose completion is more than `days` days old, on every board
    /// (one entry per board). Opt-in (Settings › Kanban); never deletes; skipped in a
    /// recovery session, like the planner's auto-delete.
    func autoArchive(olderThanDays days: Int, now: Date = Date()) throws {
        guard days >= 1, !PersistenceRecovery.didRelaunch else { return }
        for project in try context.fetch(FetchDescriptor<KanbanProject>()) where project.archivedAt == nil {
            let stale = KanbanDoneCards.archivable(in: project, finishedMoreThan: days, now: now)
            if !stale.isEmpty { try setArchived(stale, archived: true) }
        }
    }

    /// The board-level settings and appearance that can be edited (and undone).
    enum ProjectField: String, CaseIterable {
        case name, key, details, colorHex, symbolName, isPinned, workWeekDays, hoursPerDay, defaultCapacityHoursPerWeek
        case wipPolicyRaw, loadMeasureRaw, openTaskTarget, defaultEstimateHours, weightedLoad, dueSoonThresholdDays
        case suggestDoneWhenSubtasksComplete
    }

    /// Edits a board's name, appearance or settings; only changed fields are recorded.
    func editProject(_ project: KanbanProject, _ values: [ProjectField: KanbanValue]) throws {
        try RecurrenceMaterializer.checkpoint(context)
        for (field, value) in values {
            guard let current = projectValue(project, field.rawValue), Self.sameKind(current, value) else {
                throw KanbanServiceError.invariant("\(field.rawValue) can't hold that kind of value.")
            }
        }
        if case let .ints(days)? = values[.workWeekDays], days.contains(where: { !(1...7).contains($0) }) {
            throw KanbanServiceError.invariant("Work days are weekday numbers 1–7.")
        }
        for field in [ProjectField.hoursPerDay, .defaultCapacityHoursPerWeek, .openTaskTarget, .defaultEstimateHours] {
            if case let .double(v)? = values[field], !(v.isFinite && v >= 0) {
                throw KanbanServiceError.invariant("\(field.rawValue) can't be negative.")
            }
        }
        if case let .int(days)? = values[.dueSoonThresholdDays], days < 0 {
            throw KanbanServiceError.invariant("The due-soon threshold can't be negative.")
        }
        if case let .string(raw)? = values[.wipPolicyRaw], KanbanWIPPolicy(rawValue: raw) == nil {
            throw KanbanServiceError.invariant("Unknown WIP policy \(raw).")
        }
        if case let .string(raw)? = values[.loadMeasureRaw], KanbanLoadMeasure(rawValue: raw) == nil {
            throw KanbanServiceError.invariant("Unknown load measure \(raw).")
        }
        let changes = values.compactMap { field, value -> KanbanFieldChange? in
            let old = projectValue(project, field.rawValue)
            return old == value ? nil : KanbanFieldChange(entity: .project, id: project.id, field: field.rawValue, old: old, new: value)
        }.sorted { $0.field < $1.field }
        guard !changes.isEmpty else { return }
        try editProjectFields(project, changes)
    }

    /// Records and applies already-checked board field changes as one entry.
    func editProjectFields(_ project: KanbanProject, _ changes: [KanbanFieldChange]) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard !changes.isEmpty else { return }
        let data = try KanbanActivityPayload(changes: changes).encoded()
        changes.forEach { setProject($0, in: project) }
        try save(project, kind: .structure, taskIDs: [], summary: "Edited \(project.name)", encodedPayload: data)
    }

    /// Archives or restores a board (reversible, recorded on the board).
    func setProjectArchived(_ project: KanbanProject, _ archived: Bool) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard (project.archivedAt == nil) == archived else { return }
        let stamp = archived ? now() : nil
        let change = KanbanFieldChange(entity: .project, id: project.id, field: "archivedAt",
                                       old: project.archivedAt.map(KanbanValue.date), new: stamp.map(KanbanValue.date))
        let data = try KanbanActivityPayload(changes: [change]).encoded()
        project.archivedAt = stamp
        try save(project, kind: .structure, taskIDs: [], summary: "\(archived ? "Archived" : "Restored") \(project.name)", encodedPayload: data)
    }

    /// Sidebar order. Not a board change, so it isn't in any change log.
    func reorderProjects(_ ordered: [KanbanProject]) throws {
        try RecurrenceMaterializer.checkpoint(context)
        for (index, project) in ordered.enumerated() { project.sortIndex = Double(index) }
        try saveOrUndo()
    }

    /// Permanently deletes a board with all its cards, rows and history. Irreversible: the
    /// UI confirms first. People stay in the directory.
    func deleteProject(_ project: KanbanProject) throws {
        try RecurrenceMaterializer.checkpoint(context)
        context.delete(project)   // cascades; the only step after the checkpoint, then one save
        try saveOrUndo()
    }

    /// Remembers a row as collapsed or expanded (view state, not in the change log).
    func setRowCollapsed(_ project: KanbanProject, _ row: KanbanRowKey, _ collapsed: Bool) throws {
        try RecurrenceMaterializer.checkpoint(context)
        var keys = Set(project.collapsedRowKeys)
        if collapsed { keys.insert(row.storageKey) } else { keys.remove(row.storageKey) }
        project.collapsedRowKeys = keys.sorted()
        try saveOrUndo()
    }

    /// Collapses or expands every row at once (⌃⌘↑ / ⌃⌘↓).
    func setAllRowsCollapsed(_ project: KanbanProject, _ collapsed: Bool) throws {
        try RecurrenceMaterializer.checkpoint(context)
        project.collapsedRowKeys = collapsed
            ? ([KanbanRowKey.unassigned.storageKey] + project.resources.filter { $0.archivedAt == nil }.map(\.id.uuidString)).sorted()
            : []
        try saveOrUndo()
    }

    /// Stores the encoded board view state (last view, filters, sort, density, show-archived).
    func setBoardState(_ project: KanbanProject, _ state: Data?) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard project.boardState != state else { return }
        project.boardState = state
        try saveOrUndo()
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
        try save(project, kind: .structure, taskIDs: [], summary: "Added \(person.name)",
                 payload: KanbanActivityPayload(graph: KanbanRemovedGraph(resources: [KanbanResourceDTO(resource)])))
        return resource
    }

    /// The editable fields of a membership (a person's place on one board).
    enum MembershipField: String, CaseIterable {
        case role, assignmentRaw, allocationPercent, capacityHoursPerWeekOverride, openTaskTargetOverride, startDate, endDate
    }

    /// Edits a membership's role, assignment, allocation, capacity overrides or dates;
    /// recorded on the board and undoable. Everything is validated before anything changes.
    func editMembership(_ resource: KanbanResource, _ values: [MembershipField: KanbanValue?]) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = resource.project, resource.archivedAt == nil else { throw KanbanServiceError.notFound }
        for (field, value) in values {
            switch (field, value) {
            case (.role, .string?), (.role, nil), (.startDate, .date?), (.startDate, nil), (.endDate, .date?), (.endDate, nil): break
            case let (.assignmentRaw, .string(raw)?) where KanbanAssignment(rawValue: raw) != nil: break
            case let (.allocationPercent, .int(p)?) where (1...100).contains(p): break
            case let (.capacityHoursPerWeekOverride, .double(v)?), let (.openTaskTargetOverride, .double(v)?):
                guard v.isFinite && v >= 0 else { throw KanbanServiceError.invariant("Capacity can't be negative.") }
            case (.capacityHoursPerWeekOverride, nil), (.openTaskTargetOverride, nil): break
            default: throw KanbanServiceError.invariant("\(field.rawValue) can't hold that value.")
            }
        }
        func date(_ field: MembershipField, _ current: Date?) -> Date? {
            guard let entry = values[field] else { return current }
            if case let .date(d)? = entry { return d }
            return nil
        }
        if let start = date(.startDate, resource.startDate), let end = date(.endDate, resource.endDate), end < start {
            throw KanbanServiceError.invariant("The end date is before the start date.")
        }
        let changes = values.compactMap { field, value -> KanbanFieldChange? in
            let old = resourceValue(resource, field.rawValue)
            return old == value ? nil : KanbanFieldChange(entity: .resource, id: resource.id, field: field.rawValue, old: old, new: value)
        }.sorted { $0.field < $1.field }
        guard !changes.isEmpty else { return }
        let data = try KanbanActivityPayload(changes: changes).encoded()
        changes.forEach { setResource($0, in: project) }
        try save(project, kind: .structure, taskIDs: [], summary: "Edited \(resource.displayName)", encodedPayload: data)
    }

    /// Edits a person's name, initials or employment. A person isn't one board's, so this is
    /// a plain confirmed edit, outside every Change Log (01 §2.2).
    func editPerson(_ person: KanbanPerson, name: String? = nil, initials: String? = nil, employment: KanbanEmployment? = nil) throws {
        try RecurrenceMaterializer.checkpoint(context)
        if let name, name.trimmingCharacters(in: .whitespaces).isEmpty { throw KanbanServiceError.invariant("A resource needs a name.") }
        if let name { person.name = name }
        if let initials { person.initials = initials }
        if let employment { person.employmentRaw = employment.rawValue }
        try saveOrUndo()
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
        assignedSteps(resource).forEach { $0.assignee = nil }
        resource.archivedAt = stamp
        try save(project, kind: .archived, taskIDs: transitions.map(\.taskID),
                 summary: "Archived \(resource.displayName)", payload: payload)
    }

    /// Archives a person and every membership, in one save across all their boards. Each
    /// board gets an informational entry; `undoPersonArchive(group:)` reverses the group. Returns
    /// nil when the person was on no board (use `unarchivePerson`).
    @discardableResult
    func archivePerson(_ person: KanbanPerson) throws -> UUID? {
        try RecurrenceMaterializer.checkpoint(context)
        guard person.archivedAt == nil else { throw KanbanServiceError.invariant("\(person.name) is already archived.") }
        let group = UUID(), stamp = now()
        // Prepare every board's entry first; nothing has changed yet.
        var entries: [(KanbanProject, KanbanResource, KanbanActivityPayload, Data)] = []
        for resource in try memberships(of: person) where resource.archivedAt == nil {
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
            assignedSteps(resource).forEach { $0.assignee = nil }
            resource.archivedAt = stamp
            appendActivity(project, kind: .memberArchived, taskIDs: payload.transitions.map(\.taskID),
                           summary: "\(person.name) archived", payload: data)
        }
        person.archivedAt = stamp
        try saveOrUndo()
        return entries.isEmpty ? nil : group
    }

    /// Reverses `archivePerson` for one group, atomically: refuses as a whole if any card,
    /// membership or step it changed has changed since, unless `membershipsOnly` (then cards
    /// and steps stay unassigned). Restores only the memberships this group archived.
    func undoPersonArchive(_ person: KanbanPerson, group: UUID, membershipsOnly: Bool = false) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard person.archivedAt != nil else { throw KanbanServiceError.notFound }
        // Decode every per-board entry strictly: a malformed one refuses the whole undo.
        var entries: [(KanbanActivity, KanbanActivityPayload)] = []
        for activity in try context.fetch(FetchDescriptor<KanbanActivity>()) where activity.kindRaw == KanbanActivityKind.memberArchived.rawValue {
            let payload = try KanbanActivityPayload.decode(activity.payload)
            if payload.groupID == group { entries.append((activity, payload)) }
        }
        guard entries.allSatisfy({ $0.0.revertedByActivityID == nil }) else { throw KanbanServiceError.conflict("That archive was already undone.") }
        guard entries.allSatisfy({ ($0.0.project?.historyBoundarySeq ?? 0) < $0.0.seq }) else {
            throw KanbanServiceError.conflict("That archive is from before a restore, so it can't be undone.")
        }
        guard !entries.isEmpty else { throw KanbanServiceError.notFound }
        // The group must be this person's: every membership it archived belongs to them.
        let theirs = Set(try memberships(of: person).map(\.id))
        guard entries.allSatisfy({ $0.1.changes.filter { $0.entity == .resource }.allSatisfy { theirs.contains($0.id) } }) else {
            throw KanbanServiceError.invariant("That archive belongs to someone else.")
        }
        var conflicts: [String] = []
        for (activity, payload) in entries {
            guard let project = activity.project else { continue }
            for change in payload.changes where change.entity == .resource || !membershipsOnly {
                if currentValue(change, in: project) != .some(change.new) { conflicts.append("a membership or step") }
            }
            if !membershipsOnly {
                for t in payload.transitions where !isAt(t.to, task(t.taskID, in: project)) {
                    conflicts.append(task(t.taskID, in: project)?.title ?? "a deleted card")
                }
            }
            let reactivated = payload.changes.filter { $0.entity == .resource }.map(\.id)
            if project.resources.contains(where: { $0.person?.id == person.id && $0.archivedAt == nil && !reactivated.contains($0.id) }) {
                conflicts.append("\(person.name) is on \(project.name) again")
            }
        }
        guard conflicts.isEmpty else {
            throw KanbanServiceError.conflict("These changed since: \(conflicts.joined(separator: ", ")).")
        }
        let inverses = try entries.map { activity, payload -> (KanbanActivity, KanbanActivityPayload, Data) in
            let changes = payload.changes.filter { $0.entity == .resource || !membershipsOnly }.map(\.reversed)
            let inverse = KanbanActivityPayload(transitions: membershipsOnly ? [] : payload.transitions.map(\.reversed),
                                                changes: changes, groupID: group)
            return (activity, inverse, try inverse.encoded())
        }
        for (activity, inverse, data) in inverses {
            guard let project = activity.project else { continue }
            applyTransitions(inverse.transitions, in: project)
            inverse.changes.forEach { set($0, in: project) }
            let entry = appendActivity(project, kind: .restored, taskIDs: inverse.transitions.map(\.taskID),
                                       summary: "\(person.name) restored", payload: data)
            entry.revertsActivityID = activity.id
            activity.revertedByActivityID = entry.id
        }
        person.archivedAt = nil
        try saveOrUndo()
    }

    /// Un-archives a person who was on no board when archived (so there's no group to undo).
    func unarchivePerson(_ person: KanbanPerson) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let stamp = person.archivedAt else { return }
        guard !(try memberships(of: person).contains { $0.archivedAt == stamp }) else {
            throw KanbanServiceError.invariant("Undo the archive of \(person.name) to put them back on their boards.")
        }
        person.archivedAt = nil
        try saveOrUndo()
    }

    /// Hard-deletes a person; refused while they have any membership, archived included.
    func deletePerson(_ person: KanbanPerson) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard try memberships(of: person).isEmpty else {
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
        let position = min(max(index ?? order.count, 0), order.count)
        order.insert(column, at: position)
        column.sortIndex = Double(position)
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
                    wipLimit: Int?? = nil, kind: KanbanColumnKind? = nil, symbolName: String?? = nil) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = column.project else { throw KanbanServiceError.notFound }
        if let kind, kind != column.kind {
            guard columnCards(column).isEmpty else { throw KanbanServiceError.invariant("Move this column's cards out first.") }
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
        if let symbolName, symbolName != column.symbolName { changes.append(.init(entity: .column, id: column.id, field: "symbolName", old: column.symbolName.map(KanbanValue.string), new: symbolName.map(KanbanValue.string))) }
        if let wipLimit, wipLimit != column.wipLimit { changes.append(.init(entity: .column, id: column.id, field: "wipLimit", old: column.wipLimit.map(KanbanValue.int), new: wipLimit.map(KanbanValue.int))) }
        if let kind, kind != column.kind { changes.append(.init(entity: .column, id: column.id, field: "kind", old: .string(column.kindRaw), new: .string(kind.rawValue))) }
        guard !changes.isEmpty else { return }
        let payload = KanbanActivityPayload(changes: changes)
        let data = try payload.encoded()
        changes.forEach { setColumn($0, in: project) }
        try save(project, kind: .structure, taskIDs: [], summary: Self.columnEditSummary(changes, name: column.name), encodedPayload: data)
    }

    /// "Changed Review icon", "Reset Review appearance", …; other edits stay "Edited column".
    static func columnEditSummary(_ changes: [KanbanFieldChange], name: String) -> String {
        let fields = Set(changes.map(\.field))
        if fields == ["colorHex"] { return "Changed \(name) colour" }
        if fields == ["symbolName"] { return "Changed \(name) icon" }
        if fields == ["colorHex", "symbolName"] {
            return changes.allSatisfy { $0.new == nil } ? "Reset \(name) appearance" : "Changed \(name) appearance"
        }
        return "Edited column \(name)"
    }

    /// Moves the backlog role to `column`; both columns must be empty.
    func makeBacklog(_ column: KanbanColumn) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = column.project, column.kind != .backlog,
              let backlog = project.columns.first(where: { $0.kind == .backlog }) else { return }
        guard columnCards(column).isEmpty, columnCards(backlog).isEmpty else { throw KanbanServiceError.invariant("Both columns must be empty.") }
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
        let inColumn = columnCards(column)
        let cards = inColumn.filter { $0.archivedAt == nil }
        if !inColumn.isEmpty {
            guard let target, target.id != column.id, target.project?.id == project.id else {
                throw KanbanServiceError.invariant("Choose a column for this column's cards.")
            }
            // A column being deleted must empty out, whatever the target's WIP limit.
            let board = BoardSnapshot.make(project: project)
            let snapshot = BoardSnapshot(projectID: board.projectID, wipPolicy: .warn, columns: board.columns, rows: board.rows, cards: board.cards)
            let plan = KanbanMoves.plan(.cards(cards.map(\.id), to: .columnHeader(target.id)), in: snapshot, now: now())
            moves = transitions(for: plan, in: project)
            let moved = Set(moves.filter { $0.to.columnID == target.id }.map(\.taskID))
            guard cards.allSatisfy({ moved.contains($0.id) }) else {
                throw KanbanServiceError.invariant("Couldn't move every card out of \(column.name).")
            }
            // Archived cards in the column go too, keeping their place in the order.
            for card in inColumn where card.archivedAt != nil {
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
                    row: KanbanRowKey = .unassigned, before: UUID? = nil, dueDate: Date? = nil) throws -> KanbanTask {
        try RecurrenceMaterializer.checkpoint(context)
        guard let column = column ?? project.columns.first(where: { $0.kind == .backlog }), column.project?.id == project.id
        else { throw KanbanServiceError.invariant("Pick a column on this board.") }
        // A blocking WIP limit refuses a new card in a full column, as it refuses a move.
        if project.wipPolicy == .block, let limit = column.wipLimit,
           columnCards(column).filter({ $0.archivedAt == nil }).count >= limit {
            throw KanbanServiceError.wipBlocked([column.id])
        }
        let resource = try resource(for: row, in: project)
        let task = KanbanTask(title: title)
        task.createdAt = now(); task.updatedAt = now()
        task.dueDate = dueDate
        if column.kind == .done { task.completedAt = now() }
        // Its cell after insertion (before `before`, or last), renumbered densely. The
        // siblings that shift are recorded, so undoing the creation shifts them back.
        let siblings = project.tasks.filter { $0.archivedAt == nil && $0.column?.id == column.id && $0.resource?.id == resource?.id }
            .sorted { $0.sortIndex < $1.sortIndex }
        let position = before.flatMap { id in siblings.firstIndex { $0.id == id } } ?? siblings.count
        var shifts: [KanbanTransition] = []
        for (index, card) in siblings.enumerated() {
            let newIndex = Double(index < position ? index : index + 1)
            guard card.sortIndex != newIndex else { continue }
            var to = placement(card)
            to.sortIndex = newIndex
            shifts.append(KanbanTransition(taskID: card.id, from: placement(card), to: to))
        }
        task.sortIndex = Double(position)
        context.insert(task)
        task.project = project; task.column = column; task.resource = resource
        let payload = KanbanActivityPayload(transitions: shifts, graph: KanbanRemovedGraph(tasks: [KanbanTaskDTO(task)]))
        applyTransitions(shifts, in: project)
        try save(project, kind: .created, taskIDs: [task.id] + shifts.map(\.taskID), summary: "Added \(title)", payload: payload)
        return task
    }

    /// A copy of `task` right after it in its cell, as one new card (one entry; undo removes it).
    /// It keeps the card's fields, labels, what it depends on and its steps (not done); not its
    /// history, completion, planner link or the cards that depend on it.
    @discardableResult
    func duplicateCard(_ task: KanbanTask) throws -> KanbanTask {
        guard let project = task.project, task.archivedAt == nil else { throw KanbanServiceError.invariant("Only a card on the board can be duplicated.") }
        var draft = KanbanCardDraft()
        draft.title = "\(task.title) copy"
        draft.notes = task.notes
        draft.notesRich = task.notesRich
        draft.priority = task.priority
        draft.isCritical = task.isCritical
        draft.columnID = task.column?.id
        draft.row = task.resource.flatMap { $0.archivedAt == nil ? .resource($0.id) : nil } ?? .unassigned
        draft.dueDate = task.dueDate
        draft.startDate = task.startDate
        draft.estimateHours = task.estimateHours
        draft.complexity = task.complexity
        draft.jiraURL = task.jiraURL
        draft.isBlocked = task.isBlocked
        draft.blockedReason = task.blockedReason
        draft.labelIDs = task.labels.sorted { $0.sortIndex < $1.sortIndex }.map(\.id)
        draft.dependencyIDs = task.dependsOn.map(\.id)
        // A step's assignee who has left the board isn't carried over.
        draft.steps = task.subtasks.sorted { $0.sortIndex < $1.sortIndex }.map { step in
            .init(title: step.title, assigneeID: step.assignee.flatMap { $0.archivedAt == nil ? $0.id : nil })
        }
        return try createCard(draft, in: project, after: task.id)
    }

    /// Creates a card from a complete draft in one transaction. Validates everything
    /// first; on failure, no model is inserted. Records one `.created` entry with the
    /// complete graph and sibling shifts; undo removes the whole card. `after` places it right
    /// after that card in its cell (otherwise last).
    @discardableResult
    func createCard(_ draft: KanbanCardDraft, in project: KanbanProject, after anchor: UUID? = nil) throws -> KanbanTask {
        try RecurrenceMaterializer.checkpoint(context)

        // Refuse archived board
        guard project.archivedAt == nil else { throw KanbanServiceError.invariant("That board is archived.") }

        // Validate title
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { throw KanbanServiceError.invariant("A card needs a title.") }

        // Validate and resolve column
        let columnID = draft.columnID ?? project.columns.first(where: { $0.kind == .backlog })?.id
        guard let columnID, let column = project.columns.first(where: { $0.id == columnID }) else {
            throw KanbanServiceError.invariant("Pick a column on this board.")
        }

        // Validate WIP limit
        if project.wipPolicy == .block, let limit = column.wipLimit,
           columnCards(column).filter({ $0.archivedAt == nil }).count >= limit {
            throw KanbanServiceError.wipBlocked([column.id])
        }

        // Validate and resolve resource (person)
        let resource = try self.resource(for: draft.row, in: project)

        // Validate labels and dependencies (must be on same board)
        for labelID in draft.labelIDs {
            guard project.labels.contains(where: { $0.id == labelID }) else {
                throw KanbanServiceError.invariant("That label isn't on this board.")
            }
        }

        for depID in draft.dependencyIDs {
            guard let dep = project.tasks.first(where: { $0.id == depID }) else {
                throw KanbanServiceError.invariant("That dependency isn't on this board.")
            }
        }

        // Validate step titles
        for step in draft.steps {
            guard !step.title.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw KanbanServiceError.invariant("A step can't have a blank title.")
            }
        }

        // Validate assignee for steps
        for step in draft.steps {
            if let assigneeID = step.assigneeID {
                guard project.resources.contains(where: { $0.id == assigneeID && $0.archivedAt == nil }) else {
                    throw KanbanServiceError.invariant("That resource isn't an active member of this board.")
                }
            }
        }

        // Validate notes and Jira
        try Self.checkEdit([
            .notes: .string(draft.notes),
            .notesRich: draft.notesRich.map(KanbanValue.data),
            .priority: .int(draft.priority),
            .isCritical: .bool(draft.isCritical),
            .estimateHours: draft.estimateHours.map(KanbanValue.double),
            .complexity: draft.complexity.map(KanbanValue.int),
            .jiraURL: draft.jiraURL.map(KanbanValue.string),
            .isBlocked: .bool(draft.isBlocked),
            .blockedReason: draft.blockedReason.map(KanbanValue.string),
        ])

        // All validation passed; now insert
        let task = KanbanTask(title: trimmedTitle)
        task.createdAt = now()
        task.updatedAt = now()
        task.notes = draft.notes
        task.notesRich = draft.notesRich
        task.priority = draft.priority
        task.isCritical = draft.isCritical
        task.dueDate = draft.dueDate
        task.startDate = draft.startDate
        task.estimateHours = draft.estimateHours
        task.complexity = draft.complexity
        task.jiraURL = draft.jiraURL
        task.isBlocked = draft.isBlocked
        task.blockedReason = draft.blockedReason
        if column.kind == .done { task.completedAt = now() }

        // Place in cell and calculate shifts
        // By the row a card shows in: an archived member's cards show as Unassigned.
        let siblings = project.tasks.filter { card in
            card.archivedAt == nil && card.column?.id == column.id && card.resource.flatMap { $0.archivedAt == nil ? $0.id : nil } == resource?.id
        }
            .sorted { $0.sortIndex < $1.sortIndex }
        let position = anchor.flatMap { id in siblings.firstIndex { $0.id == id }.map { $0 + 1 } } ?? siblings.count
        var shifts: [KanbanTransition] = []
        for (index, card) in siblings.enumerated() {
            let newIndex = Double(index < position ? index : index + 1)
            guard card.sortIndex != newIndex else { continue }
            var to = placement(card)
            to.sortIndex = newIndex
            shifts.append(KanbanTransition(taskID: card.id, from: placement(card), to: to))
        }
        task.sortIndex = Double(position)

        // Insert task and set relationships
        context.insert(task)
        task.project = project
        task.column = column
        task.resource = resource

        // Set labels, dependencies and create steps
        task.labels = project.labels.filter { draft.labelIDs.contains($0.id) }
        task.dependsOn = project.tasks.filter { draft.dependencyIDs.contains($0.id) }

        for (index, stepDraft) in draft.steps.enumerated() {
            let step = KanbanSubtask(id: UUID(), title: stepDraft.title.trimmingCharacters(in: .whitespaces),
                                     isDone: stepDraft.isDone, sortIndex: Double(index))
            context.insert(step)
            step.task = task
            if let assigneeID = stepDraft.assigneeID, let assignee = project.resources.first(where: { $0.id == assigneeID }) {
                step.assignee = assignee
            }
        }

        // Build activity payload with complete graph
        var graph = KanbanRemovedGraph(tasks: [KanbanTaskDTO(task)])
        for step in task.subtasks {
            graph.subtasks.append(KanbanSubtaskDTO(step))
        }

        let payload = KanbanActivityPayload(transitions: shifts, graph: graph)
        applyTransitions(shifts, in: project)

        try save(project, kind: .created, taskIDs: [task.id] + shifts.map(\.taskID),
                 summary: "Added \(trimmedTitle)", payload: payload)
        return task
    }

    /// Applies batched label changes (add, edit, reorder, delete) in one transaction.
    /// Deletes remove the label from all cards (archived too) and prune it from board filters.
    /// Returns without saving if there are no effective changes.
    func applyLabelChanges(_ changes: KanbanLabelChanges, to project: KanbanProject) throws {
        try RecurrenceMaterializer.checkpoint(context)
        let current = project.labels.sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let addedIDs = Set(changes.adds.map(\.id))
        let knownIDs = Set(byID.keys).union(addedIDs)
        for id in changes.edits.map(\.id) + changes.deleteIDs + changes.orderIDs where !knownIDs.contains(id) {
            throw KanbanServiceError.invariant("That label isn't on this board.")
        }
        let deleted = Set(changes.deleteIDs)
        let edits = Dictionary(changes.edits.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        func clean(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

        // The catalog as it will be. Only names being added or changed must be unique, so an
        // untouched legacy duplicate doesn't block other edits.
        let surviving = current.filter { !deleted.contains($0.id) }
        var finalNames = surviving.map { (id: Optional($0.id), name: clean(edits[$0.id]?.name ?? $0.name), changed: edits[$0.id]?.name != nil) }
        finalNames += changes.adds.map { (id: nil, name: clean($0.name), changed: true) }
        for (index, entry) in finalNames.enumerated() where entry.changed {
            guard !entry.name.isEmpty else { throw KanbanServiceError.invariant("A label needs a name.") }
            let clash = finalNames.enumerated().contains { $0.offset != index && $0.element.name.caseInsensitiveCompare(entry.name) == .orderedSame }
            guard !clash else { throw KanbanServiceError.invariant("There's already a label called “\(entry.name)”.") }
        }
        let ordered = changes.orderIDs.filter { !deleted.contains($0) }
        // Listed first (new labels included), then unlisted existing ones as they were, then unlisted new ones.
        let order = ordered + surviving.map(\.id).filter { !ordered.contains($0) } + changes.adds.map(\.id).filter { !ordered.contains($0) }
        let position = Dictionary(order.enumerated().map { ($1, Double($0)) }, uniquingKeysWith: { a, _ in a })
        let affected = project.tasks.filter { task in task.labels.contains { deleted.contains($0.id) } }
        var state = KanbanBoardState.decode(project.boardState)
        let prunesFilter = !state.filter.labelIDs.isDisjoint(with: deleted)
        state.filter.labelIDs.subtract(deleted)
        let stateData = prunesFilter ? state.encoded() : nil
        if prunesFilter && stateData == nil { throw KanbanServiceError.invariant("The board's filter couldn't be updated.") }

        var notes: [String] = []
        for add in changes.adds { notes.append("added \(clean(add.name))") }
        for label in surviving {
            guard let edit = edits[label.id] else { continue }
            if let name = edit.name, clean(name) != label.name { notes.append("renamed \(label.name) to \(clean(name))") }
            else if (edit.colorHex.map { $0 != label.colorHex } ?? false) || (edit.symbolName.map { $0 != label.symbolName } ?? false)
                        || (edit.clearsSymbol && label.symbolName != nil) { notes.append("changed \(label.name)") }
        }
        for id in changes.deleteIDs { if let label = byID[id] { notes.append("deleted \(label.name)") } }
        let moved = order.enumerated().contains { byID[$0.element]?.sortIndex != Double($0.offset) }
        if !changes.orderIDs.isEmpty && moved && notes.isEmpty { notes.append("reordered") }
        guard !notes.isEmpty || moved || !changes.adds.isEmpty else { return }   // nothing changes, nothing is saved
        let payload = try KanbanActivityPayload().encoded()   // informational: label edits aren't revertible

        // Nothing below throws until the save.
        for label in surviving {
            guard let edit = edits[label.id] else { continue }
            if let name = edit.name { label.name = clean(name) }
            if let color = edit.colorHex { label.colorHex = color }
            if let symbol = edit.symbolName { label.symbolName = symbol } else if edit.clearsSymbol { label.symbolName = nil }
        }
        for (id, index) in position { byID[id]?.sortIndex = index }
        for add in changes.adds {
            let label = KanbanLabel(id: add.id, name: clean(add.name), colorHex: add.colorHex, sortIndex: position[add.id] ?? Double(order.count))
            label.symbolName = add.symbolName
            context.insert(label)
            label.project = project
        }
        for task in affected { task.labels.removeAll { deleted.contains($0.id) } }   // archived cards too
        if let stateData { project.boardState = stateData }
        for id in changes.deleteIDs { if let label = byID[id] { context.delete(label) } }   // last
        try save(project, kind: .structure, taskIDs: affected.map(\.id),
                 summary: "Edited labels" + (notes.isEmpty ? "" : ": " + notes.joined(separator: ", ")),
                 encodedPayload: payload, undoable: false)
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
        case title, notes, notesRich, priority, isCritical, dueDate, startDate, estimateHours, jiraURL, isBlocked, blockedReason, complexity
    }

    /// Throws what `edit` would throw for `values`, changing nothing (the editor checks
    /// everything before it saves anything).
    static func checkEdit(_ values: [TaskField: KanbanValue?]) throws {
        for (field, value) in values {
            switch (field, value) {
            case let (.title, .string(t)?): guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { throw KanbanServiceError.invariant("A card needs a title.") }
            case (.notes, .string?), (.blockedReason, .string?), (.blockedReason, nil), (.isCritical, .bool?), (.isBlocked, .bool?),
                 (.notesRich, .data?), (.notesRich, nil), (.dueDate, .date?), (.dueDate, nil), (.startDate, .date?), (.startDate, nil),
                 (.estimateHours, nil), (.jiraURL, nil), (.complexity, nil): break
            case let (.priority, .int(p)?) where (0...2).contains(p): break
            case let (.complexity, .int(c)?) where KanbanComplexity(rawValue: c) != nil: break
            case let (.estimateHours, .double(h)?): guard h.isFinite && h >= 0 else { throw KanbanServiceError.invariant("An estimate can't be negative.") }
            case let (.jiraURL, .string(url)?): guard KanbanMetrics.isWebURL(url) else { throw KanbanServiceError.invariant("The Jira link must be a web address.") }
            default: throw KanbanServiceError.invariant("\(field.rawValue) can't hold that value.")
            }
        }
    }

    /// Throws if `op` would be refused (a blocking WIP limit), changing nothing.
    func checkMove(_ op: MoveOp, in project: KanbanProject) throws {
        if case let .blocked(columns) = KanbanMoves.plan(op, in: BoardSnapshot.make(project: project), now: now()).wip {
            throw KanbanServiceError.wipBlocked(columns)
        }
    }

    /// Throws if `setDependencies` would refuse `prerequisites`, changing nothing.
    func checkDependencies(_ task: KanbanTask, _ prerequisites: [KanbanTask]) throws {
        guard let project = task.project else { throw KanbanServiceError.notFound }
        for prerequisite in prerequisites {
            guard prerequisite.project?.id == project.id else { throw KanbanServiceError.invariant("Dependencies stay within a board.") }
            if prerequisite.id == task.id || dependsTransitively(prerequisite, on: task) {
                throw KanbanServiceError.invariant("“\(prerequisite.title)” already depends on this card.")
            }
        }
    }

    /// Edits card fields; only changed fields are recorded. Every value is checked first.
    func edit(_ task: KanbanTask, _ values: [TaskField: KanbanValue?]) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = task.project else { throw KanbanServiceError.notFound }
        try Self.checkEdit(values)
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
        try checkDependencies(task, prerequisites)
        try setRelation(task, field: "dependsOn", ids: prerequisites.map(\.id))
    }

    func archiveTask(_ task: KanbanTask) throws { try setArchived([task], archived: true) }
    func restoreTask(_ task: KanbanTask) throws { try setArchived([task], archived: false) }

    // MARK: - Bulk (one grouped entry each, design 01 §2.2)

    /// Archives or restores several cards in one entry.
    func setArchived(_ tasks: [KanbanTask], _ archived: Bool) throws { try setArchived(tasks, archived: archived) }

    /// The same field values on several cards, in one entry.
    func editMany(_ tasks: [KanbanTask], _ values: [TaskField: KanbanValue?]) throws {
        try RecurrenceMaterializer.checkpoint(context)
        let project = try sameProject(tasks)
        try Self.checkEdit(values)
        let changes = tasks.flatMap { task in
            values.compactMap { field, value -> KanbanFieldChange? in
                let old = taskValue(task, field.rawValue)
                return old == value ? nil : KanbanFieldChange(entity: .task, id: task.id, field: field.rawValue, old: old, new: value)
            }
        }.sorted { ($0.id.uuidString, $0.field) < ($1.id.uuidString, $1.field) }
        guard !changes.isEmpty else { return }
        let data = try KanbanActivityPayload(changes: changes).encoded()
        changes.forEach { setTask($0, in: project) }
        let stamp = now()
        let changed = Set(changes.map(\.id))
        tasks.filter { changed.contains($0.id) }.forEach { $0.updatedAt = stamp }
        try save(project, kind: .edited, taskIDs: tasks.map(\.id).filter(changed.contains),
                 summary: "Edited \(changed.count) cards", encodedPayload: data)
    }

    /// Adds `label` to (or removes it from) several cards, in one entry.
    func setLabel(_ label: KanbanLabel, on tasks: [KanbanTask], _ present: Bool) throws {
        try RecurrenceMaterializer.checkpoint(context)
        let project = try sameProject(tasks)
        guard label.project?.id == project.id else { throw KanbanServiceError.invariant("Labels stay within a board.") }
        let changes = tasks.compactMap { task -> KanbanFieldChange? in
            var ids = Set(task.labels.map(\.id))
            if present { ids.insert(label.id) } else { ids.remove(label.id) }
            let old = taskValue(task, "labels"), new = KanbanValue.uuids(ids.sorted { $0.uuidString < $1.uuidString })
            return old == new ? nil : KanbanFieldChange(entity: .task, id: task.id, field: "labels", old: old, new: new)
        }
        guard !changes.isEmpty else { return }
        let data = try KanbanActivityPayload(changes: changes).encoded()
        changes.forEach { setTask($0, in: project) }
        let stamp = now()
        let changed = Set(changes.map(\.id))
        tasks.filter { changed.contains($0.id) }.forEach { $0.updatedAt = stamp }
        try save(project, kind: .edited, taskIDs: tasks.map(\.id).filter(changed.contains),
                 summary: "\(present ? "Labelled" : "Unlabelled") \(changed.count) cards \(label.name)", encodedPayload: data)
    }

    /// Puts these cards of one cell in this order (a reorder under a non-manual sort, from
    /// the order on screen). Cards the view hides keep their places; the whole cell is then
    /// renumbered densely, so no two share a position. One entry.
    func arrange(_ ordered: [KanbanTask]) throws {
        try RecurrenceMaterializer.checkpoint(context)
        let project = try sameProject(ordered)
        guard let first = ordered.first, ordered.allSatisfy({ $0.archivedAt == nil && $0.column?.id == first.column?.id && $0.resource?.id == first.resource?.id })
        else { throw KanbanServiceError.invariant("Those cards aren't in one cell.") }
        let cell = project.tasks.filter { $0.archivedAt == nil && $0.column?.id == first.column?.id && $0.resource?.id == first.resource?.id }
            .sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
        let requested = Set(ordered.map(\.id))
        var queue = ordered[...]
        let result = cell.map { card -> KanbanTask in requested.contains(card.id) ? queue.popFirst() ?? card : card }
        let transitions = result.enumerated().compactMap { index, task -> KanbanTransition? in
            guard task.sortIndex != Double(index) else { return nil }
            var to = placement(task)
            to.sortIndex = Double(index)
            return KanbanTransition(taskID: task.id, from: placement(task), to: to)
        }
        guard !transitions.isEmpty else { return }
        let data = try KanbanActivityPayload(transitions: transitions).encoded()
        applyTransitions(transitions, in: project)
        try save(project, kind: .moved, taskIDs: transitions.map(\.taskID), summary: "Reordered \(transitions.count) cards", encodedPayload: data)
    }

    private func sameProject(_ tasks: [KanbanTask]) throws -> KanbanProject {
        guard let project = tasks.first?.project, tasks.allSatisfy({ $0.project?.id == project.id }) else {
            throw KanbanServiceError.invariant("Pick cards on one board.")
        }
        return project
    }

    /// Hard-deletes a card (from the Archive view), keeping a graph that Revert can re-insert.
    func deleteTask(_ task: KanbanTask) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = task.project else { throw KanbanServiceError.notFound }
        let graph = KanbanRemovedGraph(tasks: [KanbanTaskDTO(task)], subtasks: task.subtasks.map(KanbanSubtaskDTO.init),
                                       incomingDependencies: dependents(of: task).map { [$0.id, task.id] })
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

    /// Schedule to day… (design 01 §7): puts the card on a planner day. The first time it
    /// creates a planner task (title, priority, Critical and notes copied once) and links it;
    /// later it only moves the linked task to the new day, never overwriting planner edits.
    /// Every lookup is done first, then one save; the entry is informational (not undoable).
    @discardableResult
    func schedule(_ task: KanbanTask, on dayKey: String) throws -> TaskItem {
        try RecurrenceMaterializer.checkpoint(context)
        guard let project = task.project else { throw KanbanServiceError.notFound }
        guard WeekMath.date(fromDayKey: dayKey) != nil else { throw KanbanServiceError.invariant("That isn't a day.") }
        // A link counts only if its planner task still exists and isn't a series definition.
        let linked = try task.linkedPlannerTaskID.flatMap { id in
            try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first
        }.flatMap { $0.recurrence == nil || $0.templateID != nil ? $0 : nil }
        let key: String? = dayKey
        let day = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.dayKey == key }))
        let next = (day.filter { $0.id != linked?.id }.map(\.sortIndex).max() ?? -1) + 1
        let label = WeekMath.date(fromDayKey: dayKey)?.formatted(date: .abbreviated, time: .omitted) ?? dayKey
        let item = linked ?? TaskItem(title: task.title, dayKey: dayKey, priority: min(max(task.priority, 0), 2))
        let data = try KanbanActivityPayload(plannerTaskID: item.id, dayKey: dayKey).encoded()

        if let linked {
            linked.markOccurrenceModified()   // moving an occurrence acts on it
            linked.dayKey = dayKey
            linked.customList = nil
            linked.sortIndex = next
            linked.updatedAt = now()
        } else {
            item.isCritical = task.isCritical
            item.notes = task.notes
            item.notesRich = task.notesRich
            item.sortIndex = next
            context.insert(item)
        }
        task.linkedPlannerTaskID = item.id
        try save(project, kind: .scheduled, taskIDs: [task.id], summary: "Scheduled \(task.title) for \(label)", encodedPayload: data, undoable: false)
        return item
    }

    /// Renames a step (recorded on the board).
    func renameSubtask(_ subtask: KanbanSubtask, _ title: String) throws {
        try RecurrenceMaterializer.checkpoint(context)
        guard let task = subtask.task, let project = task.project else { throw KanbanServiceError.notFound }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw KanbanServiceError.invariant("A step needs a title.") }
        guard trimmed != subtask.title else { return }
        let change = KanbanFieldChange(entity: .subtask, id: subtask.id, field: "title", old: .string(subtask.title), new: .string(trimmed))
        let data = try KanbanActivityPayload(changes: [change]).encoded()
        subtask.title = trimmed
        try save(project, kind: .edited, taskIDs: [task.id], summary: "Renamed a step on \(task.title)", encodedPayload: data)
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
        guard activity.seq > project.historyBoundarySeq else {
            throw KanbanServiceError.conflict("That change is from before a restore, so it can't be reverted.")
        }
        let payload = try KanbanActivityPayload.decode(activity.payload)
        try requireNoNewerChanges(to: activity, payload, in: project)
        // Informational entries (a board's creation, a person archive's per-board record,
        // scheduling to the planner) have no board-level inverse.
        let informational = kind == .structure && payload.changes.isEmpty && payload.graph == nil
        guard ![.memberArchived, .scheduled].contains(kind), !informational else {
            throw KanbanServiceError.conflict("That change can't be reverted here.")
        }
        let inverse = try inverse(of: kind, payload, in: project)
        let archivedPeople = Set(try context.fetch(FetchDescriptor<KanbanPerson>()).filter { $0.archivedAt != nil }.map(\.id))
        if let problem = KanbanInvariants(project, archivedPeople: archivedPeople).applying(inverse.kind, inverse.payload).violation {
            throw KanbanServiceError.conflict("Reverting that would leave the board invalid: \(problem).")
        }
        let data = try inverse.payload.encoded()
        inverse.apply()
        let entry = appendActivity(project, kind: inverse.kind, taskIDs: activity.taskIDs, summary: "Reverted: \(activity.summary)", payload: data)
        entry.revertsActivityID = activity.id
        markChain(below: entry, in: project)
        try saveOrUndo()
        if recordAsUserOperation { history?.recordUserOperation(entry.id, project: project.id) }
        return entry
    }

    /// Whether to offer Revert on `activity`: not already reverted, after any restore, and not
    /// an informational entry. (Revert still checks for newer changes when it runs.)
    static func offersRevert(_ activity: KanbanActivity) -> Bool {
        guard activity.revertedByActivityID == nil, let project = activity.project, activity.seq > project.historyBoundarySeq,
              let kind = KanbanActivityKind(rawValue: activity.kindRaw), ![.memberArchived, .scheduled].contains(kind),
              let payload = try? KanbanActivityPayload.decode(activity.payload) else { return false }
        return !(kind == .structure && payload.changes.isEmpty && payload.graph == nil)
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
    func save(_ project: KanbanProject, kind: KanbanActivityKind, taskIDs: [UUID], summary: String,
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

    private func dependents(of task: KanbanTask) -> [KanbanTask] {
        task.project?.tasks.filter { $0.dependsOn.contains { $0.id == task.id } } ?? []
    }

    private func assignedSteps(_ resource: KanbanResource) -> [KanbanSubtask] {
        resource.project?.tasks.flatMap(\.subtasks).filter { $0.assignee?.id == resource.id } ?? []
    }

    private func memberships(of person: KanbanPerson) throws -> [KanbanResource] {
        try context.fetch(FetchDescriptor<KanbanResource>()).filter { $0.person?.id == person.id }
    }

    /// A column's cards, from the cards' own `column` (the inverse array can lag in memory).
    /// The same goes for a membership's steps and a person's memberships, below.
    private func columnCards(_ column: KanbanColumn) -> [KanbanTask] {
        column.project?.tasks.filter { $0.column?.id == column.id } ?? []
    }

    private func isAt(_ placement: KanbanPlacementRecord, _ task: KanbanTask?) -> Bool {
        guard let task else { return false }
        return task.column?.id == placement.columnID && task.resource?.id == placement.resourceID
            && task.sortIndex == placement.sortIndex && task.completedAt == placement.completedAt
    }

    private func applyTransitions(_ transitions: [KanbanTransition], in project: KanbanProject) {
        let tasksByID = Dictionary(project.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let columnsByID = Dictionary(project.columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resourcesByID = Dictionary(project.resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for t in transitions {
            guard let task = tasksByID[t.taskID] else { continue }
            if let column = columnsByID[t.to.columnID] { task.column = column }
            task.resource = t.to.resourceID.flatMap { resourcesByID[$0] }
            task.sortIndex = t.to.sortIndex
            task.completedAt = t.to.completedAt
            task.updatedAt = now()
        }
    }

    /// The moves that send a membership's cards to the bottom of each Unassigned cell.
    private func unassignTransitions(_ resource: KanbanResource) -> [KanbanTransition] {
        guard let project = resource.project else { return [] }
        let assigned = project.tasks.filter { $0.resource?.id == resource.id }
        guard !assigned.isEmpty else { return [] }
        var transitions: [KanbanTransition] = []
        let byColumn = Dictionary(grouping: assigned) { $0.column?.id ?? UUID() }
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
        assignedSteps(resource).map {
            KanbanFieldChange(entity: .subtask, id: $0.id, field: "assignee", old: .uuid(resource.id), new: nil)
        }
    }

    private func resource(for row: KanbanRowKey, in project: KanbanProject) throws -> KanbanResource? {
        guard case let .resource(id) = row else { return nil }
        guard let resource = project.resources.first(where: { $0.id == id && $0.archivedAt == nil }) else {
            throw KanbanServiceError.invariant("That resource isn't on this board.")
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

    private func setArchived(_ tasks: [KanbanTask], archived: Bool) throws {
        try RecurrenceMaterializer.checkpoint(context)
        let project = try sameProject(tasks)
        let affected = tasks.filter { ($0.archivedAt == nil) == archived }
        guard !affected.isEmpty else { return }
        let stamp = archived ? now() : nil
        var changes: [KanbanFieldChange] = [], transitions: [KanbanTransition] = []
        // A card coming back must fit the board as it is now: complete exactly when its
        // column is Done, Unassigned if its membership was archived meanwhile, and at the end
        // of the cell it lands in (its old position may have been reused), in its old order.
        struct Cell: Hashable { let column: UUID?; let resource: UUID? }
        var next: [Cell: Double] = [:]
        let comingBack = Set(affected.map(\.id))
        for task in affected {
            changes.append(KanbanFieldChange(entity: .task, id: task.id, field: "archivedAt",
                                             old: task.archivedAt.map(KanbanValue.date), new: stamp.map(KanbanValue.date)))
        }
        if !archived {
            var maxima: [Cell: Double] = [:]
            for card in project.tasks where !comingBack.contains(card.id) && card.archivedAt == nil {
                let cell = Cell(column: card.column?.id, resource: card.resource?.id)
                maxima[cell] = maxima[cell].map { max($0, card.sortIndex) } ?? card.sortIndex
            }
            next = maxima.mapValues { $0 + 1 }
            for task in affected.sorted(by: { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }) {
                var to = placement(task)
                if task.column?.kind == .done { to.completedAt = task.completedAt ?? now() } else { to.completedAt = nil }
                if let resource = task.resource, resource.archivedAt != nil { to.resourceID = nil }
                let cell = Cell(column: task.column?.id, resource: to.resourceID)
                let position: Double = next[cell] ?? 0
                to.sortIndex = position
                next[cell] = position + 1
                if to != placement(task) { transitions.append(KanbanTransition(taskID: task.id, from: placement(task), to: to)) }
            }
        }
        let data = try KanbanActivityPayload(transitions: transitions, changes: changes).encoded()
        applyTransitions(transitions, in: project)
        affected.forEach { $0.archivedAt = stamp }
        let summary = affected.count == 1 ? "\(archived ? "Archived" : "Restored") \(affected[0].title)"
            : "\(archived ? "Archived" : "Restored") \(affected.count) cards"
        try save(project, kind: archived ? .archived : .restored, taskIDs: affected.map(\.id), summary: summary, encodedPayload: data)
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
        case "complexity": return task.complexity.map(KanbanValue.int)
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
        case "complexity": if case let .int(i)? = v, KanbanComplexity(rawValue: i) != nil { task.complexity = i } else { task.complexity = nil }
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
        case "symbolName": return column.symbolName.map(KanbanValue.string)
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
        case let ("symbolName", .string(s)?): column.symbolName = s
        case ("symbolName", nil): column.symbolName = nil
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
        case "role": return resource.role.map(KanbanValue.string)
        case "assignmentRaw": return .string(resource.assignmentRaw)
        case "allocationPercent": return .int(resource.allocationPercent)
        case "capacityHoursPerWeekOverride": return resource.capacityHoursPerWeekOverride.map(KanbanValue.double)
        case "openTaskTargetOverride": return resource.openTaskTargetOverride.map(KanbanValue.double)
        case "startDate": return resource.startDate.map(KanbanValue.date)
        case "endDate": return resource.endDate.map(KanbanValue.date)
        default: return nil
        }
    }

    private func setResource(_ change: KanbanFieldChange, in project: KanbanProject) {
        guard let resource = project.resources.first(where: { $0.id == change.id }) else { return }
        switch (change.field, change.new) {
        case let ("archivedAt", .date(d)?): resource.archivedAt = d
        case ("archivedAt", nil): resource.archivedAt = nil
        case let ("sortIndex", .double(d)?): resource.sortIndex = d
        case let ("role", .string(v)?): resource.role = v
        case ("role", nil): resource.role = nil
        case let ("assignmentRaw", .string(v)?): resource.assignmentRaw = v
        case let ("allocationPercent", .int(v)?): resource.allocationPercent = v
        case let ("capacityHoursPerWeekOverride", .double(v)?): resource.capacityHoursPerWeekOverride = v
        case ("capacityHoursPerWeekOverride", nil): resource.capacityHoursPerWeekOverride = nil
        case let ("openTaskTargetOverride", .double(v)?): resource.openTaskTargetOverride = v
        case ("openTaskTargetOverride", nil): resource.openTaskTargetOverride = nil
        case let ("startDate", .date(v)?): resource.startDate = v
        case ("startDate", nil): resource.startDate = nil
        case let ("endDate", .date(v)?): resource.endDate = v
        case ("endDate", nil): resource.endDate = nil
        default: break
        }
    }

    private func subtaskValue(_ subtask: KanbanSubtask, _ field: String) -> KanbanValue? {
        switch field {
        case "isDone": return .bool(subtask.isDone)
        case "title": return .string(subtask.title)
        case "completedAt": return subtask.completedAt.map(KanbanValue.date)
        case "assignee": return subtask.assignee.map { .uuid($0.id) }
        default: return nil
        }
    }

    private func setSubtask(_ change: KanbanFieldChange, in project: KanbanProject) {
        guard let subtask = project.tasks.lazy.flatMap(\.subtasks).first(where: { $0.id == change.id }) else { return }
        switch (change.field, change.new) {
        case let ("isDone", .bool(b)?): subtask.isDone = b
        case let ("title", .string(t)?): subtask.title = t
        case let ("completedAt", .date(d)?): subtask.completedAt = d
        case ("completedAt", nil): subtask.completedAt = nil
        case let ("assignee", .uuid(id)?): subtask.assignee = project.resources.first { $0.id == id }
        case ("assignee", nil): subtask.assignee = nil
        default: break
        }
    }

    private static func sameKind(_ a: KanbanValue, _ b: KanbanValue) -> Bool {
        switch (a, b) {
        case (.string, .string), (.int, .int), (.double, .double), (.bool, .bool), (.date, .date), (.uuid, .uuid),
             (.data, .data), (.uuids, .uuids), (.ints, .ints): true
        default: false
        }
    }

    private func projectValue(_ project: KanbanProject, _ field: String) -> KanbanValue? {
        switch field {
        case "name": return .string(project.name)
        case "key": return .string(project.key)
        case "details": return .string(project.details)
        case "colorHex": return .string(project.colorHex)
        case "symbolName": return .string(project.symbolName)
        case "isPinned": return .bool(project.isPinned)
        case "archivedAt": return project.archivedAt.map(KanbanValue.date)
        case "startDay": return project.startDay.map(KanbanValue.string)
        case "endDay": return project.endDay.map(KanbanValue.string)
        case "workWeekDays": return .ints(project.workWeekDays)
        case "hoursPerDay": return .double(project.hoursPerDay)
        case "defaultCapacityHoursPerWeek": return .double(project.defaultCapacityHoursPerWeek)
        case "wipPolicyRaw": return .string(project.wipPolicyRaw)
        case "loadMeasureRaw": return .string(project.loadMeasureRaw)
        case "openTaskTarget": return .double(project.openTaskTarget)
        case "defaultEstimateHours": return .double(project.defaultEstimateHours)
        case "weightedLoad": return .bool(project.weightedLoad)
        case "dueSoonThresholdDays": return .int(project.dueSoonThresholdDays)
        case "suggestDoneWhenSubtasksComplete": return .bool(project.suggestDoneWhenSubtasksComplete)
        default: return nil
        }
    }

    private func setProject(_ change: KanbanFieldChange, in project: KanbanProject) {
        guard change.id == project.id else { return }
        switch (change.field, change.new) {
        case let ("name", .string(v)?): project.name = v
        case let ("key", .string(v)?): project.key = v
        case let ("details", .string(v)?): project.details = v
        case let ("colorHex", .string(v)?): project.colorHex = v
        case let ("symbolName", .string(v)?): project.symbolName = v
        case let ("isPinned", .bool(v)?): project.isPinned = v
        case let ("archivedAt", .date(v)?): project.archivedAt = v
        case let ("startDay", .string(v)?): project.startDay = v
        case ("startDay", nil): project.startDay = nil
        case let ("endDay", .string(v)?): project.endDay = v
        case ("endDay", nil): project.endDay = nil
        case ("archivedAt", nil): project.archivedAt = nil
        case let ("workWeekDays", .ints(v)?): project.workWeekDays = v
        case let ("hoursPerDay", .double(v)?): project.hoursPerDay = v
        case let ("defaultCapacityHoursPerWeek", .double(v)?): project.defaultCapacityHoursPerWeek = v
        case let ("wipPolicyRaw", .string(v)?): project.wipPolicyRaw = v
        case let ("loadMeasureRaw", .string(v)?): project.loadMeasureRaw = v
        case let ("openTaskTarget", .double(v)?): project.openTaskTarget = v
        case let ("defaultEstimateHours", .double(v)?): project.defaultEstimateHours = v
        case let ("weightedLoad", .bool(v)?): project.weightedLoad = v
        case let ("dueSoonThresholdDays", .int(v)?): project.dueSoonThresholdDays = v
        case let ("suggestDoneWhenSubtasksComplete", .bool(v)?): project.suggestDoneWhenSubtasksComplete = v
        default: break
        }
        project.updatedAt = now()
    }

    private func currentValue(_ change: KanbanFieldChange, in project: KanbanProject) -> KanbanValue?? {
        switch change.entity {
        case .task: return task(change.id, in: project).map { taskValue($0, change.field) }
        case .column: return project.columns.first { $0.id == change.id }.map { columnValue($0, change.field) }
        case .resource: return project.resources.first { $0.id == change.id }.map { resourceValue($0, change.field) }
        case .subtask: return project.tasks.lazy.flatMap(\.subtasks).first { $0.id == change.id }.map { subtaskValue($0, change.field) }
        case .project: return change.id == project.id ? .some(projectValue(project, change.field)) : nil
        case .label: return nil
        }
    }

    private func set(_ change: KanbanFieldChange, in project: KanbanProject) {
        switch change.entity {
        case .task: setTask(change, in: project)
        case .column: setColumn(change, in: project)
        case .resource: setResource(change, in: project)
        case .subtask: setSubtask(change, in: project)
        case .project: setProject(change, in: project)
        case .label: break
        }
    }

    // MARK: - Internals: inverses

    struct Inverse {
        var kind: KanbanActivityKind
        var payload: KanbanActivityPayload
        var apply: () -> Void
    }

    /// Down a revert chain from its newest entry, each entry is in effect or not in turn: the
    /// newest is, the one it reverts isn't, the one that reverted isn't… so after undo,
    /// redo and undo again, every entry's `revertedByActivityID` says exactly whether its
    /// effect is in place.
    private func markChain(below top: KanbanActivity, in project: KanbanProject) {
        let byID = Dictionary(project.activities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var node = top, inEffect = true
        top.revertedByActivityID = nil
        while let targetID = node.revertsActivityID, let target = byID[targetID] {
            target.revertedByActivityID = inEffect ? node.id : nil
            inEffect.toggle()
            node = target
        }
    }

    /// Refuses a revert while a newer entry that is still in effect changed something this
    /// entry depends on. Entries in its own revert chain (its inverse, the inverse of that…)
    /// don't count.
    private func requireNoNewerChanges(to activity: KanbanActivity, _ payload: KanbanActivityPayload,
                                       in project: KanbanProject) throws {
        let footprint = Self.footprint(activity, payload)
        let bySeq = Dictionary(project.activities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for later in project.activities where later.seq > activity.seq && later.revertedByActivityID == nil {
            // A later entry that reverts another later entry cancels it: no net change
            // (an undone move, an undone undo …).
            if let reverted = later.revertsActivityID.flatMap({ bySeq[$0] }), reverted.seq > activity.seq { continue }
            // Its revert chain leading back to this entry (this entry's own inverses).
            var link = later.revertsActivityID, inChain = false
            while let id = link {
                if id == activity.id { inChain = true; break }
                link = bySeq[id]?.revertsActivityID
            }
            guard !inChain else { continue }
            guard let laterPayload = try? KanbanActivityPayload.decode(later.payload) else {
                throw KanbanServiceError.conflict("A newer entry can't be read, so this one can't be reverted safely.")
            }
            if Self.overlaps(footprint, Self.writes(later, laterPayload)) {
                throw KanbanServiceError.conflict("“\(later.summary)” changed this afterwards. Revert the newer changes first.")
            }
        }
    }

    /// What an entry touched, per row: the fields it changed ("placement" for moves), or
    /// "*" for a whole row it added or removed. "exists" (footprint only) means it needs the
    /// row to still be there, which only a whole-row change contradicts.
    typealias Touches = [UUID: Set<String>]

    /// Everything an entry's revert depends on.
    private static func footprint(_ activity: KanbanActivity, _ p: KanbanActivityPayload) -> Touches {
        var touches = writes(activity, p)
        func need(_ id: UUID?) { if let id { touches[id, default: []].insert("exists") } }
        for t in p.transitions { need(t.from.columnID); need(t.to.columnID); need(t.from.resourceID); need(t.to.resourceID) }
        for task in p.graph?.tasks ?? [] { need(task.columnId); need(task.resourceId) }
        for change in p.changes {
            for value in [change.old, change.new] { if case let .uuids(list)? = value { list.forEach { need($0) } } }
        }
        return touches
    }

    /// What an entry changed.
    private static func writes(_ activity: KanbanActivity, _ p: KanbanActivityPayload) -> Touches {
        var touches: Touches = [:]
        for t in p.transitions { touches[t.taskID, default: []].insert("placement") }
        for change in p.changes { touches[change.id, default: []].insert(change.field) }
        if let g = p.graph {
            for id in g.columns.map(\.id) + g.resources.map(\.id) + g.labels.map(\.id) + g.tasks.map(\.id) + g.subtasks.map(\.id) {
                touches[id, default: []].insert("*")
            }
            for parent in g.subtasks.compactMap(\.taskId) { touches[parent, default: []].insert("subtasks") }
            for edge in g.incomingDependencies where edge.count == 2 { touches[edge[0], default: []].insert("dependsOn") }
        }
        if let a = p.availability {
            for id in a.timeOff.map(\.id) + a.overrides.map(\.id) { touches[id, default: []].insert("*") }
            for alias in a.aliases { touches[alias.personID, default: []].insert("aliases") }
        }
        return touches
    }

    private static func overlaps(_ footprint: Touches, _ writes: Touches) -> Bool {
        for (id, written) in writes {
            guard let needed = footprint[id] else { continue }
            if written.contains("*") || needed.contains("*") { return true }
            if !needed.subtracting(["exists"]).isDisjoint(with: written) { return true }
        }
        return false
    }

    /// The inverse of an entry, after checking every row still holds the values it left.
    /// Throws `.conflict` (before any mutation) otherwise.
    private func inverse(of kind: KanbanActivityKind, _ payload: KanbanActivityPayload, in project: KanbanProject) throws -> Inverse {
        let ownRows = Set((payload.graph?.columns.map(\.id) ?? []) + (payload.graph?.resources.map(\.id) ?? [])
            + (payload.graph?.tasks.map(\.id) ?? []) + (payload.graph?.subtasks.map(\.id) ?? []))
        for change in payload.changes where !(kind == .deleted && ownRows.contains(change.id)) {
            guard let current = currentValue(change, in: project) else {
                throw KanbanServiceError.conflict("Something this change touched no longer exists.")
            }
            guard current == change.new else {
                throw KanbanServiceError.conflict("This changed again after that entry. Revert the newer changes first.")
            }
        }
        for t in payload.transitions {
            guard isAt(t.to, task(t.taskID, in: project)) else {
                throw KanbanServiceError.conflict("“\(task(t.taskID, in: project)?.title ?? "A card")” moved again after that entry. Revert the newer changes first.")
            }
            guard project.columns.contains(where: { $0.id == t.from.columnID }) || payload.graph?.columns.contains(where: { $0.id == t.from.columnID }) == true else {
                throw KanbanServiceError.conflict("“\(t.from.columnName)” no longer exists.")
            }
        }
        let reversedChanges = payload.changes.map(\.reversed)
        let reversedTransitions = payload.transitions.map(\.reversed)

        switch kind {
        case .moved, .edited, .archived, .restored:
            let inverseKind: KanbanActivityKind = kind == .archived ? .restored : kind == .restored ? .archived : kind
            return Inverse(kind: inverseKind, payload: KanbanActivityPayload(transitions: reversedTransitions, changes: reversedChanges)) {
                applyTransitions(reversedTransitions, in: project)
                reversedChanges.forEach { set($0, in: project) }
            }
        case .structure where payload.graph == nil:
            return Inverse(kind: .structure, payload: KanbanActivityPayload(transitions: reversedTransitions, changes: reversedChanges)) {
                applyTransitions(reversedTransitions, in: project)
                reversedChanges.forEach { set($0, in: project) }
            }
        case .structure, .created, .restoredGraph:
            // What these added (cards, steps, columns, memberships) is removed again.
            return try removal(of: payload.graph ?? KanbanRemovedGraph(), reversedTransitions: reversedTransitions,
                               reversedChanges: reversedChanges, in: project)
        case .deleted:
            return try reinsert(payload, reversedTransitions: reversedTransitions, reversedChanges: reversedChanges, in: project)
        case .availability:
            return try availabilityInverse(payload)
        case .memberArchived, .scheduled:
            throw KanbanServiceError.conflict("That change can't be reverted here.")
        }
    }

    /// Removes rows an entry added (the inverse of a create, an added column or membership,
    /// or a put-back delete), recording them so this removal can be reverted in turn.
    private func removal(of graph: KanbanRemovedGraph, reversedTransitions: [KanbanTransition],
                         reversedChanges: [KanbanFieldChange], in project: KanbanProject) throws -> Inverse {
        let cards = graph.tasks.compactMap { dto in task(dto.id, in: project) }
        let steps = graph.subtasks.compactMap { dto in project.tasks.lazy.flatMap(\.subtasks).first { $0.id == dto.id } }
        let columns = graph.columns.compactMap { dto in project.columns.first { $0.id == dto.id } }
        let memberships = graph.resources.compactMap { dto in project.resources.first { $0.id == dto.id } }
        guard cards.count == graph.tasks.count, steps.count == graph.subtasks.count,
              columns.count == graph.columns.count, memberships.count == graph.resources.count else {
            throw KanbanServiceError.conflict("What that change added no longer exists.")
        }
        let removedCards = Set(cards.map(\.id))
        // Cards leaving the removed columns are the ones the reversed transitions move out.
        let leaving = Set(reversedTransitions.map(\.taskID))
        for column in columns where columnCards(column).contains(where: { !removedCards.contains($0.id) && !leaving.contains($0.id) }) {
            throw KanbanServiceError.conflict("“\(column.name)” has cards now.")
        }
        for membership in memberships where project.tasks.contains(where: { $0.resource?.id == membership.id })
            || project.tasks.flatMap(\.subtasks).contains(where: { $0.assignee?.id == membership.id }) {
            throw KanbanServiceError.conflict("\(membership.displayName) has cards now; archive them instead.")
        }
        // Dependents a put-back graph restored itself (its incoming edges) may stay; others block.
        let restoredEdges = Set(graph.incomingDependencies.compactMap { $0.count == 2 ? "\($0[0])>\($0[1])" : nil })
        for card in cards where dependents(of: card).contains(where: { !removedCards.contains($0.id) && !restoredEdges.contains("\($0.id)>\(card.id)") })
            || card.subtasks.contains(where: { step in !graph.subtasks.contains { $0.id == step.id } }) {
            throw KanbanServiceError.conflict("“\(card.title)” has steps or dependents now; archive it instead.")
        }
        let removed = KanbanRemovedGraph(
            columns: columns.map(KanbanColumnDTO.init), resources: memberships.map(KanbanResourceDTO.init),
            tasks: cards.map(KanbanTaskDTO.init),
            subtasks: (steps + cards.flatMap(\.subtasks)).reduce(into: [KanbanSubtask]()) { all, s in if !all.contains(where: { $0.id == s.id }) { all.append(s) } }
                .map(KanbanSubtaskDTO.init),
            incomingDependencies: cards.flatMap { card in dependents(of: card).filter { !removedCards.contains($0.id) }.map { [$0.id, card.id] } })
        let keptTransitions = reversedTransitions.filter { !removedCards.contains($0.taskID) }
        // Field changes to rows this removes don't apply (and couldn't be checked on redo).
        let removedRows = Set(columns.map(\.id) + memberships.map(\.id) + cards.map(\.id) + steps.map(\.id))
        let keptChanges = reversedChanges.filter { !removedRows.contains($0.id) }
        return Inverse(kind: .deleted, payload: KanbanActivityPayload(transitions: keptTransitions, changes: keptChanges, graph: removed)) {
            applyTransitions(keptTransitions, in: project)
            keptChanges.forEach { set($0, in: project) }
            steps.forEach { context.delete($0) }       // deletions last
            cards.forEach { context.delete($0) }
            columns.forEach { context.delete($0) }
            memberships.forEach { context.delete($0) }
        }
    }

    /// Re-inserts a removed graph (revert of a delete), revalidating every reference first.
    private func reinsert(_ payload: KanbanActivityPayload, reversedTransitions: [KanbanTransition],
                          reversedChanges: [KanbanFieldChange], in project: KanbanProject) throws -> Inverse {
        let graph = payload.graph ?? KanbanRemovedGraph()
        let existingSteps = Set(project.tasks.flatMap(\.subtasks).map(\.id))
        guard graph.tasks.allSatisfy({ dto in !project.tasks.contains { $0.id == dto.id } }),
              graph.columns.allSatisfy({ dto in !project.columns.contains { $0.id == dto.id } }),
              graph.resources.allSatisfy({ dto in !project.resources.contains { $0.id == dto.id } }),
              graph.subtasks.allSatisfy({ !existingSteps.contains($0.id) })
        else { throw KanbanServiceError.conflict("That was already put back.") }
        let columnIDs = Set(project.columns.map(\.id)).union(graph.columns.map(\.id))
        for dto in graph.tasks {
            guard let column = dto.columnId, columnIDs.contains(column) else {
                throw KanbanServiceError.conflict("“\(dto.title)”’s column no longer exists.")
            }
        }
        let people = try context.fetch(FetchDescriptor<KanbanPerson>())
        for dto in graph.resources {
            guard let person = people.first(where: { $0.id == dto.personId }), person.archivedAt == nil
            else { throw KanbanServiceError.conflict("Restore that resource in Resources first.") }
        }
        for dto in graph.subtasks where !(graph.tasks.contains { $0.id == dto.taskId } || project.tasks.contains { $0.id == dto.taskId }) {
            throw KanbanServiceError.conflict("“\(dto.title)”’s card no longer exists.")
        }
        let planner = Set(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.recurrence == nil || $0.templateID != nil }.map(\.id))
        let restored = KanbanActivityPayload(transitions: reversedTransitions, changes: reversedChanges, graph: graph)
        return Inverse(kind: .restoredGraph, payload: restored) {
            var columns = Dictionary(uniqueKeysWithValues: project.columns.map { ($0.id, $0) })
            for dto in graph.columns {
                let column = KanbanColumn(id: dto.id, name: dto.name, kind: KanbanColumnKind(rawValue: dto.kindRaw) ?? .active, sortIndex: dto.sortIndex)
                column.colorHex = dto.colorHex; column.symbolName = dto.symbolName; column.wipLimit = dto.wipLimit
                context.insert(column); column.project = project
                columns[column.id] = column
            }
            for dto in graph.resources {
                let resource = KanbanResource(id: dto.id, person: people.first { $0.id == dto.personId },
                                              assignment: KanbanAssignment(rawValue: dto.assignmentRaw) ?? .fullTime,
                                              allocationPercent: dto.allocationPercent, sortIndex: dto.sortIndex)
                resource.role = dto.role; resource.capacityHoursPerWeekOverride = dto.capacityHoursPerWeekOverride
                resource.openTaskTargetOverride = dto.openTaskTargetOverride; resource.startDate = dto.startDate; resource.endDate = dto.endDate
                resource.archivedAt = dto.archivedAt
                context.insert(resource); resource.project = project
            }
            var inserted: [UUID: KanbanTask] = [:]
            for dto in graph.tasks {
                let task = KanbanTask(id: dto.id, title: dto.title, priority: dto.priority, sortIndex: dto.sortIndex)
                task.notes = dto.notes; task.notesRich = dto.notesRich; task.isCritical = dto.isCritical
                task.dueDate = dto.dueDate; task.startDate = dto.startDate; task.estimateHours = dto.estimateHours
                task.complexity = dto.complexity.flatMap { KanbanComplexity(rawValue: $0)?.rawValue }
                task.jiraURL = dto.jiraURL; task.isBlocked = dto.isBlocked; task.blockedReason = dto.blockedReason
                task.linkedPlannerTaskID = dto.linkedPlannerTaskID.flatMap { planner.contains($0) ? $0 : nil }
                task.createdAt = dto.createdAt; task.updatedAt = dto.updatedAt; task.completedAt = dto.completedAt; task.archivedAt = dto.archivedAt
                context.insert(task)
                task.project = project
                task.column = dto.columnId.flatMap { columns[$0] }
                // A live card only goes back onto an active membership; an archived card keeps its own.
                task.resource = dto.resourceId.flatMap { id in
                    project.resources.first { $0.id == id && ($0.archivedAt == nil || dto.archivedAt != nil) }
                }
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
