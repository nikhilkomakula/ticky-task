import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Revert, undo and redo never break a board or silently drop work (Codex's increment-1
/// review): the newer-change rule, invariant simulation, the restore boundary, the inverse
/// of each kind of entry, and failure injection on every destructive path.
@MainActor
@Suite("Kanban revert safety", .serialized)
struct KanbanRevertSafetyTests {
    struct Board {
        let context: ModelContext, service: KanbanService, history: KanbanHistory
        let project: KanbanProject, ravi: KanbanResource, mia: KanbanResource
        var todo: KanbanColumn { project.orderedColumns[0] }
        var doing: KanbanColumn { project.orderedColumns[1] }
        var done: KanbanColumn { project.orderedColumns.last! }
        func last() -> KanbanActivity { project.activities.max { $0.seq < $1.seq }! }
    }

    private func board(_ context: ModelContext = ModelContext(ModelContainerProvider.makeInMemoryContainer())) throws -> Board {
        let history = KanbanHistory()
        let service = KanbanService(context, history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let ravi = try service.addMembership(try service.createPerson(name: "Ravi", initials: "RV"), to: project)
        let mia = try service.addMembership(try service.createPerson(name: "Mia", initials: "MI"), to: project)
        history.clear()
        return Board(context: context, service: service, history: history, project: project, ravi: ravi, mia: mia)
    }

    private func diskBoard() throws -> (Board, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KanbanRevert-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: dir.appendingPathComponent("TickyTask.store")))
        context.autosaveEnabled = false
        DiscardedContexts.keep(context)   // a failed delete leaves pending changes; never release it
        return (try board(context), dir)
    }

    private func reopen(_ dir: URL) throws -> ModelContext {
        ModelContext(try ModelContainerProvider.makeContainer(at: dir.appendingPathComponent("TickyTask.store")))
    }

    // MARK: - Destructive actions

    @Test("Deleting a column empties it even when the target's WIP limit would block a drag")
    func deleteColumnIgnoresWIP() throws {
        let b = try board()
        b.project.wipPolicy = .block
        try b.service.editColumn(b.done, wipLimit: .some(0))
        let card = try b.service.createTask(in: b.project, title: "Card", column: b.doing)
        try b.service.deleteColumn(b.doing, movingTasksTo: b.done)
        #expect(card.column?.kind == .done)
        #expect(b.project.tasks.allSatisfy { $0.column != nil })
    }

    @Test("Delete, undo, redo, undo: the card comes back, goes again, and its steps never duplicate")
    func deleteUndoRedoUndo() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card")
        let step = try b.service.addSubtask(to: card, title: "Step")
        let id = card.id, stepID = step.id
        b.history.clear()
        try b.service.deleteTask(card)
        try b.service.undo(in: b.project)
        #expect(b.project.tasks.contains { $0.id == id })
        try b.service.redo(in: b.project)
        #expect(!b.project.tasks.contains { $0.id == id }, "redo deletes it again")
        try b.service.undo(in: b.project)
        let steps = try b.context.fetch(FetchDescriptor<KanbanSubtask>()).filter { $0.id == stepID }
        #expect(steps.count == 1, "the step exists exactly once")
    }

    // MARK: - The newer-change rule (Change Log reverts)

    @Test("Reverting a card's creation after it was edited is refused")
    func createThenEditThenRevertCreate() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card")
        let created = b.last()
        try b.service.edit(card, [.title: .string("Edited")])
        #expect(throws: KanbanServiceError.self) { try b.service.revert(created) }
        #expect(b.project.tasks.contains { $0.id == card.id })
    }

    @Test("Undoing a historical Revert makes the original undoable again")
    func revertOfRevert() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Old")
        b.history.clear()
        try b.service.edit(card, [.title: .string("New")])
        let edit = b.last()
        try b.service.revert(edit)                 // a Change Log revert: back to "Old"
        #expect(card.title == "Old")
        try b.service.undo(in: b.project)          // undo the revert: "New" again
        #expect(card.title == "New" && edit.revertedByActivityID == nil)
        try b.service.undo(in: b.project)          // and undo the edit itself
        #expect(card.title == "Old")
    }

    @Test("Undoing a card created before another shifts the other back")
    func createBeforeRecordsSiblings() throws {
        let b = try board()
        let a = try b.service.createTask(in: b.project, title: "A")
        try b.service.move(.cards([a.id], to: .columnHeader(b.doing.id)), in: b.project)
        #expect(a.sortIndex == 0)
        _ = try b.service.createTask(in: b.project, title: "B", column: b.doing, before: a.id)
        #expect(a.sortIndex == 1)
        try b.service.undo(in: b.project)
        #expect(a.sortIndex == 0, "A is back at the top")
        try b.service.undo(in: b.project)
        #expect(a.column?.id == b.todo.id, "and the earlier move undoes cleanly")
    }

    // MARK: - Invariant simulation

    @Test("A revert that would recreate a dependency cycle is refused")
    func revertWouldCreateCycle() throws {
        let b = try board()
        let a = try b.service.createTask(in: b.project, title: "A"), bee = try b.service.createTask(in: b.project, title: "B")
        try b.service.setDependencies(a, [bee])
        try b.service.setDependencies(a, [])
        let removal = b.last()
        try b.service.setDependencies(bee, [a])
        #expect(throws: KanbanServiceError.self) { try b.service.revert(removal) }
        #expect(a.dependsOn.isEmpty && bee.dependsOn.map(\.id) == [a.id])
    }

    @Test("Reverting a membership archive is refused once the person is back on the board")
    func revertArchiveWouldDuplicateMembership() throws {
        let b = try board()
        let mia = try #require(b.mia.person)
        try b.service.archiveMembership(b.mia)
        let archive = b.last()
        _ = try b.service.addMembership(mia, to: b.project)
        #expect(throws: KanbanServiceError.self) { try b.service.revert(archive) }
        #expect(b.project.resources.filter { $0.person?.id == mia.id && $0.archivedAt == nil }.count == 1)
    }

    @Test("Reverting a kind change is refused if it would leave no Done column")
    func revertKindChangeWouldLeaveNoDone() throws {
        let b = try board()
        let extra = try b.service.addColumn(to: b.project, name: "Shipped")
        try b.service.editColumn(extra, kind: .done)
        let kindChange = b.last()
        try b.service.deleteColumn(b.project.orderedColumns.first { $0.name == "Done" }!, movingTasksTo: extra)
        #expect(throws: KanbanServiceError.self) { try b.service.revert(kindChange) }
        #expect(b.project.columns.contains { $0.kind == .done })
    }

    @Test("Reverting a column's addition is refused once it became the backlog")
    func revertAddedBacklog() throws {
        let b = try board()
        let x = try b.service.addColumn(to: b.project, name: "X")
        let added = b.last()
        try b.service.makeBacklog(x)
        #expect(throws: KanbanServiceError.self) { try b.service.revert(added) }
        #expect(b.project.columns.filter { $0.kind == .backlog }.count == 1)
    }

    @Test("Reverting a move into a column that was deleted since is refused")
    func revertMoveToDeletedColumn() throws {
        let b = try board()
        let done = b.done
        let a = try b.service.addColumn(to: b.project, name: "Review", at: 1)
        let card = try b.service.createTask(in: b.project, title: "Card", column: a)
        try b.service.move(.cards([card.id], to: .columnHeader(done.id)), in: b.project)
        let move = b.last()
        try b.service.deleteColumn(a, movingTasksTo: nil)
        #expect(throws: KanbanServiceError.self) { try b.service.revert(move) }
        #expect(card.column?.kind == .done && card.completedAt != nil)
    }

    @Test("Reverting a membership's addition removes it, unless it has cards now")
    func revertAddMembership() throws {
        let b = try board()
        let zoe = try b.service.createPerson(name: "Zoe", initials: "ZO")
        let membership = try b.service.addMembership(zoe, to: b.project)
        let added = b.last()
        let card = try b.service.createTask(in: b.project, title: "Card", row: .resource(membership.id))
        #expect(throws: KanbanServiceError.self) { try b.service.revert(added) }
        try b.service.move(.cards([card.id], to: .rowHeader(.unassigned)), in: b.project)
        try b.service.undo(in: b.project)   // put it back on Zoe…
        try b.service.move(.cards([card.id], to: .rowHeader(.unassigned)), in: b.project)
        _ = card
        let zoeID = membership.id
        b.history.clear()
        let bare = try b.service.createPerson(name: "Ann", initials: "AN")
        try b.service.addMembership(bare, to: b.project)
        try b.service.undo(in: b.project)
        #expect(!b.project.resources.contains { $0.person?.id == bare.id }, "an unused membership is removed")
        #expect(b.project.resources.contains { $0.id == zoeID })
    }

    // MARK: - People

    @Test("A person on no board can be archived and un-archived; memberships-only records only membership changes")
    func personArchiveEdges() throws {
        let b = try board()
        let loner = try b.service.createPerson(name: "Loner", initials: "LO")
        #expect(try b.service.archivePerson(loner) == nil, "no boards, so no group to undo")
        try b.service.unarchivePerson(loner)
        #expect(loner.archivedAt == nil)

        let mia = try #require(b.mia.person)
        let card = try b.service.createTask(in: b.project, title: "Card", row: .resource(b.mia.id))
        let step = try b.service.addSubtask(to: card, title: "Step")
        step.assignee = b.mia
        try b.context.save()
        let miaGroup = try #require(try b.service.archivePerson(mia))
        try b.service.undoPersonArchive(mia, group: miaGroup, membershipsOnly: true)
        let restored = try #require(b.project.activities.filter { $0.kindRaw == "restored" }.max { $0.seq < $1.seq })
        let payload = try KanbanActivityPayload.decode(restored.payload)
        #expect(payload.changes.allSatisfy { $0.entity == .resource } && payload.transitions.isEmpty)
        #expect(step.assignee == nil && card.resource == nil, "cards and steps stay unassigned")
    }

    // MARK: - Restore boundary

    @Test("Entries from before a restore can't be reverted")
    func restoreBoundary() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "A")
        try b.service.edit(card, [.title: .string("B")])
        let snapshot = try BackupStore.makeSnapshot(context: b.context)
        try BackupStore.restore(snapshot, context: b.context)
        let project = try #require(try b.context.fetch(FetchDescriptor<KanbanProject>()).first { $0.key == "PLAT" })
        let edit = try #require(project.activities.first { $0.kindRaw == "edited" })
        #expect(throws: KanbanServiceError.self) { try b.service.revert(edit) }
        #expect(project.tasks.first?.title == "B")
    }

    // MARK: - Failure injection

    @Test("A checkpoint failure changes nothing and keeps the unrelated pending edit")
    func checkpointFailure() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card")
        b.project.details = "pending, unsaved"
        let count = b.project.activities.count
        PersistenceFaults.armed = [.checkpoint]
        defer { PersistenceFaults.armed = [] }
        #expect(throws: (any Error).self) { try b.service.edit(card, [.title: .string("X")]) }
        #expect(card.title == "Card" && b.project.details == "pending, unsaved" && b.project.activities.count == count)
    }

    enum Destructive: String, CaseIterable { case deleteColumn, deleteSubtask, undoCreate }

    @Test("A failed save on a destructive path fails closed and leaves the disk unchanged", arguments: Destructive.allCases)
    func destructiveFailure(_ path: Destructive) throws {
        let (b, dir) = try diskBoard()
        let column = try b.service.addColumn(to: b.project, name: "Review")
        let card = try b.service.createTask(in: b.project, title: "Card", column: column)
        let step = try b.service.addSubtask(to: card, title: "Step")
        let fresh = try b.service.createTask(in: b.project, title: "Fresh")
        let before = try KanbanBackupDTO.snapshot(context: reopen(dir)).deterministicallySorted()
        var restarted = false
        PersistenceRecovery.testHook = { restarted = true }
        defer { PersistenceRecovery.testHook = nil; PersistenceFaults.armed = [] }
        PersistenceFaults.armed = [.transaction]
        switch path {
        case .deleteColumn: #expect(throws: (any Error).self) { try b.service.deleteColumn(column, movingTasksTo: b.todo) }
        case .deleteSubtask: #expect(throws: (any Error).self) { try b.service.deleteSubtask(step) }
        case .undoCreate: #expect(throws: (any Error).self) { try b.service.undo(in: b.project) }   // removes `fresh`
        }
        _ = fresh
        #expect(restarted, "\(path): fails closed")
        #expect(try KanbanBackupDTO.snapshot(context: reopen(dir)).deterministicallySorted() == before, "\(path): the disk is unchanged")
    }

    @Test("A failed cross-board person archive is rolled back on every board")
    func personArchiveFailure() throws {
        let b = try board()
        let mia = try #require(b.mia.person)
        let other = try b.service.createProject(name: "Data", key: "DATA")
        let there = try b.service.addMembership(mia, to: other)
        let card = try b.service.createTask(in: other, title: "There", row: .resource(there.id))
        PersistenceFaults.armed = [.transaction]
        defer { PersistenceFaults.armed = [] }
        #expect(throws: (any Error).self) { try b.service.archivePerson(mia) }
        #expect(mia.archivedAt == nil && b.mia.archivedAt == nil && there.archivedAt == nil && card.resource?.id == there.id)
    }

    @Test("A failed undo leaves the undo stack as it was")
    func failedUndoKeepsHistory() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card")
        try b.service.edit(card, [.title: .string("New")])
        let top = b.history.peekUndo(b.project.id)
        PersistenceFaults.armed = [.transaction]
        defer { PersistenceFaults.armed = [] }
        #expect(throws: (any Error).self) { try b.service.undo(in: b.project) }
        #expect(b.history.peekUndo(b.project.id) == top && !b.history.canRedo(b.project.id) && card.title == "New")
    }

    // MARK: - Round 3 (Codex re-review)

    @Test("Adding a column, ⌘Z, ⇧⌘Z brings the same column back")
    func addColumnUndoRedo() throws {
        let b = try board()
        let column = try b.service.addColumn(to: b.project, name: "Review")
        let id = column.id
        try b.service.undo(in: b.project)
        #expect(!b.project.columns.contains { $0.id == id })
        try b.service.redo(in: b.project)
        #expect(b.project.orderedColumns.map(\.id).contains(id))
        #expect(b.project.orderedColumns.map(\.sortIndex) == [0, 1, 2, 3])
    }

    @Test("Delete a prerequisite, ⌘Z, ⇧⌘Z, ⌘Z: the dependency the undo restored survives each step")
    func incomingDependencyRedo() throws {
        let b = try board()
        let a = try b.service.createTask(in: b.project, title: "A"), dependent = try b.service.createTask(in: b.project, title: "B")
        try b.service.setDependencies(dependent, [a])
        let id = a.id
        b.history.clear()
        try b.service.deleteTask(a)
        try b.service.undo(in: b.project)
        #expect(dependent.dependsOn.map(\.id) == [id])
        try b.service.redo(in: b.project)
        #expect(!b.project.tasks.contains { $0.id == id } && dependent.dependsOn.isEmpty)
        try b.service.undo(in: b.project)
        #expect(dependent.dependsOn.map(\.id) == [id])
    }

    @Test("Reverting a column's kind change is refused once the column holds cards")
    func kindChangeRevertWithCards() throws {
        let b = try board()
        let column = try b.service.addColumn(to: b.project, name: "Shipped")
        try b.service.editColumn(column, kind: .done)
        let kindChange = b.last()
        let card = try b.service.createTask(in: b.project, title: "T", column: column)
        #expect(throws: KanbanServiceError.self) { try b.service.revert(kindChange) }
        #expect(column.kind == .done && card.completedAt != nil)
    }

    @Test("A membership archive can't be reverted while its person is archived")
    func revertMembershipOfArchivedPerson() throws {
        let b = try board()
        let mia = try #require(b.mia.person)
        try b.service.archiveMembership(b.mia)
        let archive = b.last()
        try b.service.archivePerson(mia)
        #expect(throws: KanbanServiceError.self) { try b.service.revert(archive) }
        #expect(b.mia.archivedAt != nil)
    }

    @Test("⌘Z doesn't undo past a person archive that changed the same membership")
    func undoPastPersonArchive() throws {
        let b = try board()
        let zoe = try b.service.createPerson(name: "Zoe", initials: "ZO")
        let membership = try b.service.addMembership(zoe, to: b.project)
        let group = try #require(try b.service.archivePerson(zoe))
        #expect(throws: KanbanServiceError.self) { try b.service.undo(in: b.project) }
        #expect(b.project.resources.contains { $0.id == membership.id })
        try b.service.undoPersonArchive(zoe, group: group)
        #expect(zoe.archivedAt == nil && membership.archivedAt == nil)
    }

    @Test("A plain un-archive can't undo an archive that took someone off their boards")
    func unarchiveVersusGroup() throws {
        let b = try board()
        let zoe = try b.service.createPerson(name: "Zoe", initials: "ZO")
        _ = try b.service.archivePerson(zoe)
        try b.service.unarchivePerson(zoe)
        let membership = try b.service.addMembership(zoe, to: b.project)
        let group = try #require(try b.service.archivePerson(zoe))
        #expect(throws: KanbanServiceError.self) { try b.service.unarchivePerson(zoe) }
        #expect(zoe.archivedAt != nil && membership.archivedAt != nil)
        try b.service.undoPersonArchive(zoe, group: group)
        #expect(zoe.archivedAt == nil && membership.archivedAt == nil)
    }

    // MARK: - Round 4 (Codex)

    @Test("create → edit → ⌘Z → ⇧⌘Z → ⌘Z → ⌘Z removes the card")
    func undoAfterRedoCycle() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "A")
        try b.service.edit(card, [.title: .string("B")])
        try b.service.undo(in: b.project)
        try b.service.redo(in: b.project)
        #expect(card.title == "B")
        try b.service.undo(in: b.project)
        #expect(card.title == "A")
        try b.service.undo(in: b.project)
        #expect(!b.project.tasks.contains { $0.title == "A" }, "the creation is undone")
        try b.service.redo(in: b.project)
        try b.service.redo(in: b.project)
        #expect(b.project.tasks.first?.title == "B", "and both redo again")
    }

    @Test("Restoring a person archive doesn't block undoing an unrelated title edit")
    func titleUndoAfterPersonRestore() throws {
        let b = try board()
        let mia = try #require(b.mia.person)
        let card = try b.service.createTask(in: b.project, title: "Old", row: .resource(b.mia.id))
        let group = try #require(try b.service.archivePerson(mia))
        b.history.clear()
        try b.service.edit(card, [.title: .string("New")])
        try b.service.undoPersonArchive(mia, group: group)
        try b.service.undo(in: b.project)
        #expect(card.title == "Old" && card.resource?.id == b.mia.id, "the edit is undone and the restored assignment kept")
    }

    @Test("Putting back an archived card keeps its archived membership; a live card's goes to Unassigned")
    func archivedCardKeepsArchivedAssignment() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card", row: .resource(b.mia.id))
        try b.service.archiveTask(card)
        card.resource = b.mia   // an archived card keeps its row, as a backup can record it
        try b.service.archiveMembership(b.mia)
        card.resource = b.mia
        try b.context.save()
        let id = card.id
        try b.service.deleteTask(card)
        try b.service.undo(in: b.project)
        let back = try #require(b.project.tasks.first { $0.id == id })
        #expect(back.archivedAt != nil && back.resource?.id == b.mia.id)
    }

    @Test("After branching reverts that net out, the earlier edit can still be reverted")
    func branchingCancellation() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "0")
        try b.service.edit(card, [.title: .string("1")]); let x = b.last()
        try b.service.edit(card, [.title: .string("2")]); let a = b.last()
        let r1 = try b.service.revert(a)          // "1"
        try b.service.revert(r1)                  // "2"
        try b.service.revert(a)                   // "1" again
        #expect(card.title == "1")
        try b.service.revert(x)
        #expect(card.title == "0")
    }

    enum MoreDestructive: String, CaseIterable { case deletePerson, undoAddColumn, undoAddMembership, redoDelete }

    @Test("More destructive paths fail closed with the disk unchanged", arguments: MoreDestructive.allCases)
    func moreDestructiveFailures(_ path: MoreDestructive) throws {
        let (b, dir) = try diskBoard()
        let loner = try b.service.createPerson(name: "Loner", initials: "LO")
        let card = try b.service.createTask(in: b.project, title: "Card")
        b.history.clear()
        switch path {
        case .deletePerson: break
        case .undoAddColumn: _ = try b.service.addColumn(to: b.project, name: "Review")
        case .undoAddMembership: _ = try b.service.addMembership(loner, to: b.project)
        case .redoDelete: try b.service.deleteTask(card); try b.service.undo(in: b.project)
        }
        let before = try KanbanBackupDTO.snapshot(context: reopen(dir)).deterministicallySorted()
        var restarted = false
        PersistenceRecovery.testHook = { restarted = true }
        defer { PersistenceRecovery.testHook = nil; PersistenceFaults.armed = [] }
        PersistenceFaults.armed = [.transaction]
        switch path {
        case .deletePerson: #expect(throws: (any Error).self) { try b.service.deletePerson(loner) }
        case .undoAddColumn, .undoAddMembership: #expect(throws: (any Error).self) { try b.service.undo(in: b.project) }
        case .redoDelete: #expect(throws: (any Error).self) { try b.service.redo(in: b.project) }
        }
        #expect(restarted, "\(path): fails closed")
        #expect(try KanbanBackupDTO.snapshot(context: reopen(dir)).deterministicallySorted() == before, "\(path): disk unchanged")
    }

    // MARK: - Round 5 (Codex)

    @Test("Reverting a move into a column that became Done since is refused")
    func revertMoveIntoNowDoneColumn() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "T", column: b.doing)
        try b.service.move(.cards([card.id], to: .columnHeader(b.todo.id)), in: b.project)
        let move = b.last()
        try b.service.editColumn(b.doing, kind: .done)
        #expect(throws: KanbanServiceError.self) { try b.service.revert(move) }
        #expect(card.column?.id == b.todo.id && card.completedAt == nil)
    }

    @Test("A person's archive can't be undone with someone else's group")
    func groupOwnership() throws {
        let b = try board()
        let mia = try #require(b.mia.person), ravi = try #require(b.ravi.person)
        let miaGroup = try #require(try b.service.archivePerson(mia))
        _ = try b.service.archivePerson(ravi)
        #expect(throws: KanbanServiceError.self) { try b.service.undoPersonArchive(ravi, group: miaGroup) }
        #expect(ravi.archivedAt != nil && mia.archivedAt != nil && b.mia.archivedAt != nil)
    }

    // MARK: - Round 6 (Codex)

    @Test("Bringing an archived card back into a column that became Done: revert is refused, restore completes it")
    func unarchiveIntoNowDoneColumn() throws {
        let b = try board()
        let column = try b.service.addColumn(to: b.project, name: "Review", at: 1)
        let original = try b.service.createTask(in: b.project, title: "T", column: column)
        try b.service.archiveTask(original)
        let archive = b.last()
        let id = original.id
        try b.service.deleteTask(original)
        try b.service.editColumn(column, kind: .done)              // empty now, so allowed
        try b.service.revert(try #require(b.project.activities.first { $0.kindRaw == "deleted" }))
        let card = try #require(b.project.tasks.first { $0.id == id })
        #expect(card.archivedAt != nil && card.column?.id == column.id)
        #expect(throws: KanbanServiceError.self) { try b.service.revert(archive) }
        #expect(card.archivedAt != nil)
        try b.service.restoreTask(card)
        #expect(card.archivedAt == nil && card.completedAt != nil, "restoring completes it in Done")
        try b.service.undo(in: b.project)
        #expect(card.archivedAt != nil && card.completedAt == nil, "and ⌘Z puts it back exactly")
    }

    @Test("Restoring a card whose membership was archived meanwhile brings it back Unassigned")
    func restoreOntoArchivedMembership() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "T", row: .resource(b.mia.id))
        try b.service.archiveTask(card)
        let id = card.id
        try b.service.deleteTask(card)
        try b.service.archiveMembership(b.mia)
        try b.service.revert(try #require(b.project.activities.first { $0.kindRaw == "deleted" }))
        let back = try #require(b.project.tasks.first { $0.id == id })
        try b.service.restoreTask(back)
        #expect(back.archivedAt == nil && back.resource == nil)
        try b.service.edit(back, [.title: .string("New")])
        try b.service.undo(in: b.project)
        #expect(back.title == "T", "later edits still undo")
    }
}
