import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Exact, on-disk guarantees for Kanban backups (design 01 §7, D8/D11): field-for-field
/// round trips, planner-link repair for imported and kept boards, every validator
/// rejection leaving the disk untouched, and dependency cycles removed before insert.
@MainActor
@Suite("Kanban backup integrity", .serialized)
struct KanbanBackupIntegrityTests {
    private static let fixtureBackup = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/LegacyStores/v0.1.17/backup-plain.tickytask")

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KanbanBackupIntegrity-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func open(_ dir: URL) throws -> ModelContext {
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: dir.appendingPathComponent("TickyTask.store")))
        context.autosaveEnabled = false   // only explicit saves may reach the file reopened below
        return context
    }

    private func kanban(_ context: ModelContext) throws -> KanbanBackupDTO {
        try KanbanBackupDTO.snapshot(context: context).deterministicallySorted()
    }

    struct Board {
        var linkedOK: UUID, linkedDefinition: UUID, linkedMissing: UUID
    }

    /// A board in `context` that exercises every Kanban field, with three planner links:
    /// to a one-off, to a series definition, and to an id that doesn't exist.
    @discardableResult
    private func buildBoard(_ context: ModelContext, plannerOneOff: UUID, plannerDefinition: UUID) throws -> Board {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000.125)
        let alice = KanbanPerson(name: "Alice", initials: "AL", employment: .fte)
        alice.colorHex = "#FF0000"; alice.skills = ["swift", "sql"]; alice.createdAt = t0
        let bob = KanbanPerson(name: "Bob", initials: "BO", employment: .contractor)
        bob.archivedAt = t0
        let project = KanbanProject(name: "Platform", key: "PLAT", sortIndex: 1)
        project.details = "details"; project.isPinned = true; project.archivedAt = nil
        project.workWeekDays = [2, 3, 4]; project.hoursPerDay = 7.5; project.defaultCapacityHoursPerWeek = 30
        project.wipPolicy = .block; project.loadMeasure = .hours; project.openTaskTarget = 4
        project.defaultEstimateHours = 3; project.weightedLoad = true; project.dueSoonThresholdDays = 5
        project.suggestDoneWhenSubtasksComplete = false; project.collapsedRowKeys = ["unassigned"]
        project.boardState = Data([1, 2, 3]); project.nextActivitySeq = 9
        let empty = KanbanProject(name: "Empty", key: "EMP", sortIndex: 2)
        let todo = KanbanColumn(name: "To Do", kind: .backlog, sortIndex: 0)
        let doing = KanbanColumn(name: "Doing", kind: .active, sortIndex: 1)
        doing.wipLimit = 3; doing.colorHex = "#00FF00"
        let done = KanbanColumn(name: "Done", kind: .done, sortIndex: 2)
        let emptyBacklog = KanbanColumn(name: "Backlog", kind: .backlog, sortIndex: 0)
        let emptyDone = KanbanColumn(name: "Done", kind: .done, sortIndex: 1)
        let ali = KanbanResource(person: alice, assignment: .partTime, allocationPercent: 60, sortIndex: 0)
        ali.role = "Lead"; ali.capacityHoursPerWeekOverride = 20; ali.openTaskTargetOverride = 3
        ali.startDate = t0; ali.endDate = t0.addingTimeInterval(86_400 * 30)
        let bobRow = KanbanResource(person: bob, sortIndex: 1)
        bobRow.archivedAt = t0
        let bug = KanbanLabel(name: "Bug", colorHex: "#FF3B30", sortIndex: 0)
        bug.symbolName = "ladybug"
        let feature = KanbanLabel(name: "Feature", sortIndex: 1)

        func task(_ title: String, _ column: KanbanColumn, _ resource: KanbanResource?, link: UUID?) -> KanbanTask {
            let t = KanbanTask(title: title, priority: 2, sortIndex: 0)
            t.column = column; t.resource = resource; t.linkedPlannerTaskID = link
            return t
        }
        let a = task("Linked OK", doing, ali, link: plannerOneOff)
        a.notes = "plain"; a.notesRich = Data([9, 9]); a.isCritical = true; a.dueDate = t0; a.startDate = t0
        a.estimateHours = 2.5; a.jiraURL = "https://jira/browse/PLAT-1"; a.isBlocked = true; a.blockedReason = "waiting"
        a.createdAt = t0; a.updatedAt = t0; a.labels = [bug, feature]
        let b = task("Linked definition", todo, nil, link: plannerDefinition)
        let c = task("Linked missing", done, ali, link: UUID())
        c.completedAt = t0; c.archivedAt = t0
        a.dependsOn = [b, c]; b.dependsOn = [c]
        let sub = KanbanSubtask(title: "step", isDone: true, sortIndex: 1)
        sub.completedAt = t0; sub.assignee = ali; sub.task = a
        let activity = KanbanActivity(seq: 3, at: t0, kind: "moved", taskIDs: [a.id], summary: "moved", payload: Data([7]))
        activity.revertsActivityID = UUID()

        for model in [alice, bob] as [any PersistentModel] { context.insert(model) }
        context.insert(project); context.insert(empty)
        for (col, owner) in [(todo, project), (doing, project), (done, project), (emptyBacklog, empty), (emptyDone, empty)] {
            context.insert(col); col.project = owner
        }
        for r in [ali, bobRow] { context.insert(r); r.project = project }
        for l in [bug, feature] { context.insert(l); l.project = project }
        for t in [a, b, c] { context.insert(t); t.project = project }
        context.insert(sub)
        context.insert(activity); activity.project = project
        try context.save()
        return Board(linkedOK: a.id, linkedDefinition: b.id, linkedMissing: c.id)
    }

    /// A planner one-off and a v0.1.17 series (whose definition is hidden) in `context`.
    private func buildPlanner(_ context: ModelContext) throws -> (oneOff: UUID, definition: UUID) {
        let oneOff = TaskItem(title: "One-off", dayKey: "20261020")
        context.insert(oneOff)
        let seed = TaskItem(title: "Standup", dayKey: "20261019")
        context.insert(seed)
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: RecurrenceRule(frequency: .daily, startDate: Date(timeIntervalSinceReferenceDate: 813_000_000)),
            through: Date(timeIntervalSinceReferenceDate: 813_400_000), context: context)
        try context.save()
        return (oneOff.id, definition.id)
    }

    // MARK: - Exact round trip

    @Test("A board round-trips field for field through a plain or encrypted file into a fresh store",
          arguments: [false, true])
    func exactRoundTrip(encrypted: Bool) throws {
        let source = try tempDir(), target = try tempDir()
        defer { [source, target].forEach { try? FileManager.default.removeItem(at: $0) } }
        let context = try open(source)
        let planner = try buildPlanner(context)
        let board = try buildBoard(context, plannerOneOff: planner.oneOff, plannerDefinition: planner.definition)

        let passphrase = encrypted ? "fixture-passphrase-1" : nil
        let file = try BackupService().makeFile(store: try BackupStore.makeSnapshot(context: context), passphrase: passphrase)
        let decoded = try BackupService().readFile(file, passphrase: passphrase)
        let fresh = try open(target)
        let preview = try BackupStore.preview(decoded, context: fresh)
        #expect(preview.droppedPlannerLinks == 2, "the definition link and the missing link will be cleared")
        try BackupStore.restore(decoded, context: fresh)

        var expected = try #require(decoded.kanban).deterministicallySorted()
        expected.tasks = expected.tasks.map { task in
            var task = task
            if [board.linkedDefinition, board.linkedMissing].contains(task.id) { task.linkedPlannerTaskID = nil }
            return task
        }
        let reopened = try open(target)
        let restored = try kanban(reopened)
        #expect(restored.people == expected.people)
        #expect(restored.projects == expected.projects)
        #expect(restored.columns == expected.columns)
        #expect(restored.resources == expected.resources)
        #expect(restored.labels == expected.labels)
        #expect(restored.tasks == expected.tasks)
        #expect(restored.subtasks == expected.subtasks)
        #expect(restored.activities == expected.activities)
        #expect(restored == expected, "every board field survives except the two invalid links")
        #expect(try BackupStore.makeSnapshot(context: reopened).data == decoded.data, "the planner data is restored exactly")
        let kept = try reopened.fetch(FetchDescriptor<KanbanTask>()).first { $0.id == board.linkedOK }
        #expect(kept?.linkedPlannerTaskID == planner.oneOff, "a link to a planner one-off is kept")
    }

    // MARK: - D11: a pre-Kanban backup keeps boards, and their links are repaired

    @Test("Restoring the real v0.1.17 backup keeps existing boards and repairs their planner links")
    func preKanbanRestoreKeepsBoardsAndRepairsLinks() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try BackupService().readFile(Data(contentsOf: Self.fixtureBackup), passphrase: nil)
        #expect(fixture.kanban == nil, "the v0.1.17 backup has no board section")
        let oneOff = try #require(fixture.data.taskItems.first { $0.recurrence == nil && $0.templateId == nil && $0.dayKey != nil })
        let definition = try #require(fixture.data.taskItems.first { $0.recurrence != nil && $0.templateId == nil })

        let context = try open(dir)
        let board = try buildBoard(context, plannerOneOff: oneOff.id, plannerDefinition: definition.id)
        let before = try kanban(context)
        #expect(try BackupStore.preview(fixture, context: context).droppedPlannerLinks == 2)
        try BackupStore.restore(fixture, context: context)

        let reopened = try open(dir)
        var expected = before
        expected.tasks = expected.tasks.map { task in
            var task = task
            if [board.linkedDefinition, board.linkedMissing].contains(task.id) { task.linkedPlannerTaskID = nil }
            return task
        }
        #expect(try kanban(reopened) == expected, "the board is kept; only its two invalid links are cleared")
        #expect(try reopened.fetchCount(FetchDescriptor<TaskItem>()) == fixture.data.taskItems.count,
                "the planner rows are the backup's")
    }

    // MARK: - Validator rejections never touch the disk

    enum Corruption: String, CaseIterable {
        case danglingPerson, missingPerson, crossProjectColumn, crossProjectResource, crossProjectLabel,
             crossProjectDependency, crossProjectAssignee, twoBacklogColumns, noDoneColumn,
             duplicateActiveMembership, futureVersion, duplicateColumnID, duplicateTaskID, unknownColumnKind
    }

    private func corrupt(_ k: KanbanBackupDTO, _ corruption: Corruption) -> KanbanBackupDTO {
        var k = k
        let platform = k.projects.first { $0.key == "PLAT" }!.id, other = k.projects.first { $0.key == "EMP" }!.id
        let otherColumn = k.columns.first { $0.projectId == other }!.id
        switch corruption {
        case .danglingPerson: k.resources[0].personId = UUID()
        case .missingPerson: k.resources[0].personId = nil
        case .crossProjectColumn:
            let i = k.tasks.firstIndex { $0.projectId == platform }!
            k.tasks[i].columnId = otherColumn
        case .crossProjectResource:
            let used = k.tasks.compactMap(\.resourceId).first!
            let i = k.resources.firstIndex { $0.id == used }!
            k.resources[i].projectId = other
        case .crossProjectLabel:
            k.labels[0].projectId = other
        case .crossProjectDependency:
            var outsider = k.tasks[0]
            outsider.id = UUID(); outsider.projectId = other; outsider.columnId = otherColumn
            outsider.resourceId = nil; outsider.labelIds = []; outsider.dependsOnIds = []
            k.tasks.append(outsider)
            k.tasks[0].dependsOnIds.append(outsider.id)
        case .crossProjectAssignee:
            var stranger = k.resources[0]
            stranger.id = UUID(); stranger.projectId = other
            k.resources.append(stranger)
            k.subtasks[0].assigneeId = stranger.id
        case .twoBacklogColumns:
            let i = k.columns.firstIndex { $0.projectId == platform && $0.kindRaw == "active" }!
            k.columns[i].kindRaw = "backlog"
        case .noDoneColumn:
            for i in k.columns.indices where k.columns[i].projectId == platform && k.columns[i].kindRaw == "done" {
                k.columns[i].kindRaw = "active"
            }
        case .duplicateActiveMembership:
            var twin = k.resources.first { $0.archivedAt == nil }!
            twin.id = UUID()
            k.resources.append(twin)
        case .futureVersion: k.version = KanbanBackupDTO.currentVersion + 1
        case .duplicateColumnID:
            // Another board's column reusing an id this board's cards point at.
            let shared = k.tasks.first { $0.projectId == platform }!.columnId!
            let i = k.columns.firstIndex { $0.projectId == other }!
            k.columns[i].id = shared
        case .duplicateTaskID:
            var twin = k.tasks[0]
            twin.title = "twin"
            k.tasks.append(twin)
        case .unknownColumnKind:
            let i = k.columns.firstIndex { $0.kindRaw == "active" }!
            k.columns[i].kindRaw = "someday"
        }
        return k
    }

    @Test("A corrupt board section is rejected before anything on disk changes", arguments: Corruption.allCases)
    func rejection(_ corruption: Corruption) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = try open(dir)
        let planner = try buildPlanner(context)
        try buildBoard(context, plannerOneOff: planner.oneOff, plannerDefinition: planner.definition)
        let snapshot = try BackupStore.makeSnapshot(context: context)
        let beforeKanban = try kanban(context), beforePlanner = snapshot.data

        var bad = snapshot
        bad.kanban = corrupt(try #require(snapshot.kanban), corruption)
        #expect(throws: (any Error).self, "\(corruption)") { try KanbanBackupValidator.validate(bad.kanban!) }
        #expect(throws: (any Error).self, "\(corruption)") { try BackupStore.restore(bad, context: context) }

        let reopened = try open(dir)
        #expect(try kanban(reopened) == beforeKanban, "\(corruption): the boards on disk are unchanged")
        #expect(try BackupStore.makeSnapshot(context: reopened).data == beforePlanner, "\(corruption): the planner is unchanged")
    }

    // MARK: - Dependency cycles

    @Test("A dependency cycle is broken by dropping exactly one edge, which never reaches the store")
    func cycleEdgesAreRemovedBeforeInsert() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = try open(dir)
        let planner = try buildPlanner(context)
        let board = try buildBoard(context, plannerOneOff: planner.oneOff, plannerDefinition: planner.definition)
        var snapshot = try BackupStore.makeSnapshot(context: context)
        var section = try #require(snapshot.kanban)
        // Close one cycle, b ⇄ c: c (the missing-link task) now also depends on b.
        let c = try #require(section.tasks.firstIndex { $0.id == board.linkedMissing })
        section.tasks[c].dependsOnIds.append(board.linkedDefinition)
        snapshot.kanban = section

        let sanitized = try KanbanBackupValidator.sanitized(section)
        #expect(sanitized.report.droppedDependencyEdges == 1)
        try BackupStore.restore(snapshot, context: context)

        let reopened = try open(dir)
        let tasks = try reopened.fetch(FetchDescriptor<KanbanTask>())
        var edges = 0
        func reachable(_ from: KanbanTask, _ to: UUID, _ seen: inout Set<UUID>) -> Bool {
            for next in from.dependsOn where seen.insert(next.id).inserted {
                if next.id == to || reachable(next, to, &seen) { return true }
            }
            return false
        }
        for task in tasks {
            edges += task.dependsOn.count
            var seen: Set<UUID> = []
            #expect(!reachable(task, task.id, &seen), "\(task.title) is not on a cycle")
        }
        #expect(edges == 3, "3 of the 4 edges are kept")
    }

    // MARK: - Repairs

    @Test("A live card on an archived membership is restored as Unassigned (counted), and moving it is safe")
    func liveCardOnArchivedMembershipIsRepaired() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = try open(dir)
        let planner = try buildPlanner(context)
        try buildBoard(context, plannerOneOff: planner.oneOff, plannerDefinition: planner.definition)
        var snapshot = try BackupStore.makeSnapshot(context: context)
        var section = try #require(snapshot.kanban)
        let archived = try #require(section.resources.first { $0.archivedAt != nil })
        let live = try #require(section.tasks.firstIndex { $0.archivedAt == nil })
        section.tasks[live].resourceId = archived.id
        snapshot.kanban = section
        #expect(try KanbanBackupValidator.sanitized(section).report.unassignedFromArchivedMemberships == 1)

        try BackupStore.restore(snapshot, context: context)
        let reopened = try open(dir)
        let card = try #require(try reopened.fetch(FetchDescriptor<KanbanTask>()).first { $0.id == section.tasks[live].id })
        #expect(card.resource == nil)
        // Even if such a card existed, the snapshot shows it as Unassigned and planning never traps.
        card.resource = try reopened.fetch(FetchDescriptor<KanbanResource>()).first { $0.id == archived.id }
        let project = try #require(card.project)
        let board = BoardSnapshot.make(project: project)
        #expect(board.cards.first { $0.id == card.id }?.row == .unassigned)
        _ = KanbanMoves.plan(.cards([card.id], to: .rowHeader(.unassigned)), in: board, now: Date())
    }

    @Test("A backup whose live card's completion doesn't match its column is repaired on restore")
    func completionMismatchIsRepaired() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = try open(dir)
        let service = KanbanService(context)
        let project = try service.createProject(name: "P", key: "P")
        let done = try #require(project.orderedColumns.last), todo = try #require(project.orderedColumns.first)
        let finished = try service.createTask(in: project, title: "Finished", column: done)
        let unfinished = try service.createTask(in: project, title: "Open", column: todo)
        var snapshot = try BackupStore.makeSnapshot(context: context)
        var section = try #require(snapshot.kanban)
        for i in section.tasks.indices {
            if section.tasks[i].id == finished.id { section.tasks[i].completedAt = nil }
            if section.tasks[i].id == unfinished.id { section.tasks[i].completedAt = Date(timeIntervalSinceReferenceDate: 1) }
        }
        snapshot.kanban = section
        #expect(try KanbanBackupValidator.sanitized(section).report.repairedCompletions == 2)
        try BackupStore.restore(snapshot, context: context)
        let tasks = try open(dir).fetch(FetchDescriptor<KanbanTask>())
        #expect(tasks.first { $0.id == finished.id }?.completedAt != nil)
        #expect(tasks.first { $0.id == unfinished.id }?.completedAt == nil)
    }
}
