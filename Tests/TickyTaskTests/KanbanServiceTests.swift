import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// `KanbanService` invariants, the change log, undo/redo stack rules and conflict-checked
/// Revert (design 01 §2.2–2.5), on in-memory stores except where the disk matters.
@MainActor
@Suite("Kanban service", .serialized)
struct KanbanServiceTests {
    struct Board {
        let context: ModelContext
        let service: KanbanService
        let history: KanbanHistory
        let project: KanbanProject
        let ravi: KanbanResource
        let mia: KanbanResource
        var todo: KanbanColumn { project.orderedColumns[0] }
        var doing: KanbanColumn { project.orderedColumns[1] }
        var done: KanbanColumn { project.orderedColumns[2] }
    }

    private func board(_ context: ModelContext = ModelContext(ModelContainerProvider.makeInMemoryContainer())) throws -> Board {
        let history = KanbanHistory()
        let service = KanbanService(context, history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let ravi = try service.addMembership(try service.createPerson(name: "Ravi", initials: "RV"), to: project)
        let mia = try service.addMembership(try service.createPerson(name: "Mia", initials: "MI", employment: .contractor),
                                            to: project, allocationPercent: 50, assignment: .partTime)
        history.clear()
        return Board(context: context, service: service, history: history, project: project, ravi: ravi, mia: mia)
    }

    private func entries(_ b: Board) -> [KanbanActivity] { b.project.activities.sorted { $0.seq < $1.seq } }

    // MARK: - Projects and structure

    @Test("A new board has the template's columns, the default labels, and an informational first entry")
    func createProject() throws {
        let b = try board()
        #expect(b.project.orderedColumns.map(\.name) == ["To Do", "In Progress", "Done"])
        #expect(b.project.orderedColumns.map(\.kind) == [.backlog, .active, .done])
        #expect(b.project.labels.count == 7)
        let first = try #require(entries(b).first)
        #expect(throws: KanbanServiceError.self) { try b.service.revert(first) }
        let software = try b.service.createProject(name: "Apps", key: "APP", template: .software)
        #expect(software.orderedColumns.map(\.name) == ["Backlog", "To Do", "In Progress", "In Review", "Done"])
    }

    @Test("A person is on a board at most once while active, and can't be deleted while on any board")
    func membershipRules() throws {
        let b = try board()
        let ravi = try #require(b.ravi.person)
        #expect(throws: KanbanServiceError.self) { try b.service.addMembership(ravi, to: b.project) }
        #expect(throws: KanbanServiceError.self) { try b.service.deletePerson(ravi) }
        let loner = try b.service.createPerson(name: "Loner", initials: "LO")
        try b.service.deletePerson(loner)
        #expect(try b.context.fetch(FetchDescriptor<KanbanPerson>()).count == 2)
    }

    @Test("The backlog and the last Done column can't be deleted; a populated column needs a target")
    func columnProtections() throws {
        let b = try board()
        #expect(throws: KanbanServiceError.self) { try b.service.deleteColumn(b.todo, movingTasksTo: nil) }
        #expect(throws: KanbanServiceError.self) { try b.service.deleteColumn(b.done, movingTasksTo: nil) }
        let card = try b.service.createTask(in: b.project, title: "A", column: b.doing)
        #expect(throws: KanbanServiceError.self) { try b.service.deleteColumn(b.doing, movingTasksTo: nil) }
        #expect(throws: KanbanServiceError.self) { try b.service.editColumn(b.doing, kind: .done) }
        #expect(card.column?.id == b.doing.id)
        #expect(throws: KanbanServiceError.self) { try b.service.makeBacklog(b.doing) }
    }

    // MARK: - Tasks and moves

    @Test("New cards go to the backlog's Unassigned cell, in order")
    func createTask() throws {
        let b = try board()
        let a = try b.service.createTask(in: b.project, title: "A")
        let c = try b.service.createTask(in: b.project, title: "C")
        let bee = try b.service.createTask(in: b.project, title: "B", before: c.id)
        #expect(a.column?.kind == .backlog && a.resource == nil)
        #expect([a, bee, c].map(\.sortIndex) == [0, 1, 2])
    }

    @Test("A move applies the plan in one save and logs per-card transitions")
    func move() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card")
        let outcome = try b.service.move(.cards([card.id], to: .cell(columnID: b.done.id, row: .resource(b.ravi.id), beforeCardID: nil)), in: b.project)
        #expect(outcome == .ok)
        #expect(card.column?.id == b.done.id && card.resource?.id == b.ravi.id && card.completedAt != nil)
        let entry = try #require(entries(b).last)
        #expect(entry.kindRaw == "moved")
        let payload = try KanbanActivityPayload.decode(entry.payload)
        #expect(payload.transitions.first?.from.columnKind == "backlog" && payload.transitions.first?.to.columnKind == "done")
    }

    @Test("A blocking WIP limit refuses the move and changes nothing")
    func wipBlock() throws {
        let b = try board()
        b.project.wipPolicy = .block
        try b.service.editColumn(b.doing, wipLimit: .some(1))
        let first = try b.service.createTask(in: b.project, title: "1", column: b.doing)
        let second = try b.service.createTask(in: b.project, title: "2")
        let count = entries(b).count
        #expect(throws: KanbanServiceError.wipBlocked([b.doing.id])) {
            try b.service.move(.cards([second.id], to: .columnHeader(b.doing.id)), in: b.project)
        }
        #expect(second.column?.id == b.todo.id && first.column?.id == b.doing.id && entries(b).count == count)
    }

    // MARK: - Undo / redo

    @Test("⌘Z undoes user operations newest first and never its own undo; ⇧⌘Z re-applies; a fresh change clears redo")
    func undoRedoStacks() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card")
        try b.service.move(.cards([card.id], to: .columnHeader(b.doing.id)), in: b.project)
        try b.service.undo(in: b.project)
        #expect(card.column?.id == b.todo.id, "the move is undone")
        try b.service.undo(in: b.project)
        let created = try b.context.fetch(FetchDescriptor<KanbanTask>())
        #expect(created.isEmpty, "the second ⌘Z undoes the creation, not the first undo")
        try b.service.redo(in: b.project)
        let back = try #require(try b.context.fetch(FetchDescriptor<KanbanTask>()).first)
        #expect(back.id == card.id && back.column?.id == b.todo.id, "redo re-creates the same card")
        try b.service.redo(in: b.project)
        #expect(back.column?.id == b.doing.id, "and re-applies the move")
        try b.service.undo(in: b.project)
        _ = try b.service.createTask(in: b.project, title: "Fresh")
        #expect(!b.history.canRedo(b.project.id), "a fresh change clears redo")
    }

    // MARK: - Conflict-checked Revert

    @Test("Reverting an old move after the card moved again is refused before anything changes")
    func staleMoveConflict() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card")
        try b.service.move(.cards([card.id], to: .columnHeader(b.doing.id)), in: b.project)
        let firstMove = try #require(entries(b).last)
        try b.service.move(.cards([card.id], to: .columnHeader(b.done.id)), in: b.project)
        let count = entries(b).count
        #expect(throws: KanbanServiceError.self) { try b.service.revert(firstMove) }
        #expect(card.column?.id == b.done.id && entries(b).count == count && firstMove.revertedByActivityID == nil)
    }

    @Test("A field edit reverts to its old value, unless the field changed again")
    func editRevert() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Old")
        try b.service.edit(card, [.title: .string("New"), .priority: .int(2), .dueDate: .date(Date(timeIntervalSinceReferenceDate: 1))])
        let edit = try #require(entries(b).last)
        try b.service.revert(edit)
        #expect(card.title == "Old" && card.priority == 0 && card.dueDate == nil)
        try b.service.edit(card, [.title: .string("Again")])
        let second = try #require(entries(b).last)
        try b.service.edit(card, [.title: .string("Newer")])
        #expect(throws: KanbanServiceError.self) { try b.service.revert(second) }
        #expect(card.title == "Newer")
    }

    // MARK: - Destructive actions and their reverts

    @Test("Deleting a populated column moves its cards (with completion) and Revert puts them back")
    func deleteColumnAndRevert() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card", column: b.doing, row: .resource(b.mia.id))
        let doingID = b.doing.id, doneID = b.done.id
        try b.service.deleteColumn(b.doing, movingTasksTo: b.done)
        #expect(card.column?.id == doneID && card.completedAt != nil && card.resource?.id == b.mia.id)
        #expect(b.project.columns.count == 2)
        try b.service.revert(try #require(entries(b).last))
        #expect(b.project.orderedColumns.map(\.id).contains(doingID))
        #expect(card.column?.id == doingID && card.completedAt == nil, "the card is back in the restored column")
        #expect(b.project.orderedColumns.map(\.sortIndex) == [0, 1, 2])
    }

    @Test("Deleting a card keeps a graph Revert re-inserts with its steps, labels and dependents")
    func deleteTaskAndRevert() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card", row: .resource(b.ravi.id))
        let dependent = try b.service.createTask(in: b.project, title: "Dependent")
        try b.service.setLabels(card, Array(b.project.labels.prefix(2)))
        try b.service.setDependencies(dependent, [card])
        let step = try b.service.addSubtask(to: card, title: "Step")
        try b.service.setSubtaskDone(step, true)
        let id = card.id
        try b.service.deleteTask(card)
        #expect(dependent.dependsOn.isEmpty)
        try b.service.revert(try #require(entries(b).last))
        let back = try #require(b.project.tasks.first { $0.id == id })
        #expect(back.resource?.id == b.ravi.id && back.labels.count == 2)
        #expect(back.subtasks.map(\.title) == ["Step"] && back.subtasks.first?.isDone == true)
        #expect(dependent.dependsOn.map(\.id) == [id], "the incoming dependency is restored")
    }

    @Test("Archiving a membership unassigns its cards; Revert reassigns them")
    func archiveMembershipAndRevert() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card", column: b.doing, row: .resource(b.mia.id))
        try b.service.archiveMembership(b.mia)
        #expect(card.resource == nil && b.mia.archivedAt != nil)
        try b.service.revert(try #require(entries(b).last))
        #expect(card.resource?.id == b.mia.id && b.mia.archivedAt == nil)
    }

    @Test("Archiving a person unassigns them on every board in one save; Undo archive is atomic and conflict-checked")
    func archivePersonAcrossBoards() throws {
        let b = try board()
        let mia = try #require(b.mia.person)
        let other = try b.service.createProject(name: "Data", key: "DATA")
        let miaOnData = try b.service.addMembership(mia, to: other, allocationPercent: 50)
        let here = try b.service.createTask(in: b.project, title: "Here", row: .resource(b.mia.id))
        let there = try b.service.createTask(in: other, title: "There", row: .resource(miaOnData.id))
        let group = try b.service.archivePerson(mia)
        #expect(here.resource == nil && there.resource == nil && mia.archivedAt != nil)
        #expect(b.project.activities.contains { $0.kindRaw == "memberArchived" } && other.activities.contains { $0.kindRaw == "memberArchived" })
        #expect(throws: KanbanServiceError.self, "a per-board entry has no Revert") {
            try b.service.revert(try #require(b.project.activities.first { $0.kindRaw == "memberArchived" }))
        }

        // A card moved since → refused as a whole …
        try b.service.move(.cards([there.id], to: .columnHeader(other.orderedColumns[1].id)), in: other)
        #expect(throws: KanbanServiceError.self) { try b.service.undoPersonArchive(mia, group: group) }
        #expect(mia.archivedAt != nil && b.mia.archivedAt != nil)
        // … unless only the memberships are restored.
        try b.service.undoPersonArchive(mia, group: group, membershipsOnly: true)
        #expect(mia.archivedAt == nil && b.mia.archivedAt == nil && miaOnData.archivedAt == nil)
        #expect(here.resource == nil, "cards stay Unassigned")
    }

    // MARK: - Dependencies and steps

    @Test("Dependencies refuse self edges, cycles and other boards")
    func dependencyRules() throws {
        let b = try board()
        let a = try b.service.createTask(in: b.project, title: "A"), c = try b.service.createTask(in: b.project, title: "C")
        try b.service.setDependencies(a, [c])
        #expect(throws: KanbanServiceError.self) { try b.service.setDependencies(c, [a]) }
        #expect(throws: KanbanServiceError.self) { try b.service.setDependencies(a, [a]) }
        let other = try b.service.createProject(name: "X", key: "X")
        let foreign = try b.service.createTask(in: other, title: "F")
        #expect(throws: KanbanServiceError.self) { try b.service.setDependencies(a, [foreign]) }
    }

    @Test("Ticking the last step suggests Done (never moves the card); finished steps sink")
    func stepsSuggestDone() throws {
        let b = try board()
        let card = try b.service.createTask(in: b.project, title: "Card", column: b.doing)
        let one = try b.service.addSubtask(to: card, title: "One"), two = try b.service.addSubtask(to: card, title: "Two")
        #expect(try b.service.setSubtaskDone(one, true) == false)
        #expect(KanbanService.orderedSubtasks(card).map(\.title) == ["Two", "One"], "finished steps sink")
        #expect(try b.service.setSubtaskDone(two, true) == true)
        #expect(card.column?.id == b.doing.id)
        b.project.suggestDoneWhenSubtasksComplete = false
        try b.service.setSubtaskDone(two, false)
        #expect(try b.service.setSubtaskDone(two, true) == false, "the suggestion can be turned off")
    }

    // MARK: - Failure handling and persistence

    @Test("A failed save without deletions is undone in place; with deletions it fails closed")
    func failureHandling() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KanbanService-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: dir.appendingPathComponent("TickyTask.store")))
        context.autosaveEnabled = false
        DiscardedContexts.keep(context)
        let b = try board(context)
        let card = try b.service.createTask(in: b.project, title: "Card")

        PersistenceFaults.armed = [.transaction]
        #expect(throws: (any Error).self) { try b.service.move(.cards([card.id], to: .columnHeader(b.doing.id)), in: b.project) }
        #expect(card.column?.id == b.todo.id, "rolled back in place")

        var restarted = false
        PersistenceRecovery.testHook = { restarted = true }
        defer { PersistenceRecovery.testHook = nil; PersistenceFaults.armed = [] }
        PersistenceFaults.armed = [.transaction]
        #expect(throws: (any Error).self) { try b.service.deleteTask(card) }
        #expect(restarted, "a failed delete fails closed")

        let reopened = ModelContext(try ModelContainerProvider.makeContainer(at: dir.appendingPathComponent("TickyTask.store")))
        let onDisk = try reopened.fetch(FetchDescriptor<KanbanTask>())
        #expect(onDisk.map(\.id) == [card.id] && onDisk.first?.column?.kind == .backlog, "the disk keeps the last saved state")
    }

    @Test("Change-log entries are numbered in order and survive a reopen")
    func activitySequence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KanbanService-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("TickyTask.store")
        do {
            let context = ModelContext(try ModelContainerProvider.makeContainer(at: url))
            context.autosaveEnabled = false
            let b = try board(context)
            let card = try b.service.createTask(in: b.project, title: "Card")
            try b.service.move(.cards([card.id], to: .columnHeader(b.doing.id)), in: b.project)
        }
        let reopened = ModelContext(try ModelContainerProvider.makeContainer(at: url))
        let project = try #require(try reopened.fetch(FetchDescriptor<KanbanProject>()).first)
        let seqs = project.activities.map(\.seq).sorted()
        #expect(seqs == Array(1...seqs.count) && project.nextActivitySeq == seqs.count + 1)
    }
}
