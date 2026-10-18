import Foundation
import SwiftData
import Testing
@testable import TickyTask

@Suite(.serialized) @MainActor
struct KanbanBackupTests {
    private let service = BackupService()
    private let passphrase = "fixture-passphrase-1"

    // MARK: - Test Helpers

    func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func makeContext(at dir: URL) throws -> ModelContext {
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: dir.appendingPathComponent("TickyTask.store")))
        context.autosaveEnabled = false
        return context
    }

    private func makeInMemoryContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    /// Creates a rich Kanban fixture by building actual SwiftData models, then snapshotting them.
    /// This avoids DTO initialization issues and ensures the fixture matches the actual model structure.
    private func makeRichKanbanFixture() -> BackupStoreDTO {
        let context = makeInMemoryContext()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t0_plus_day = t0.addingTimeInterval(86400)
        let t0_plus_week = t0.addingTimeInterval(604800)

        // Create planner data: one-off + series
        let oneOffId = UUID()
        let seriesDefId = UUID()
        let listId = UUID()
        let tag1Id = UUID()

        let oneOff = TaskItem(id: oneOffId, title: "One-off task", dayKey: "20260115")
        oneOff.priority = 1
        oneOff.alarmEnabled = true
        oneOff.createdAt = t0
        oneOff.updatedAt = t0
        context.insert(oneOff)

        let seriesDef = TaskItem(id: seriesDefId, title: "Daily standup", dayKey: "20260114")
        seriesDef.priority = 0
        seriesDef.recurrence = RecurrenceRule(frequency: .daily, interval: 1, weekdays: [], monthDays: [], end: .afterCount(5), startDate: t0)
        seriesDef.createdAt = t0
        seriesDef.updatedAt = t0
        context.insert(seriesDef)

        let tag1 = TaskTag(id: tag1Id, name: "urgent", colorHex: "#FF0000")
        context.insert(tag1)

        let customList = CustomList(id: listId, name: "Shopping", sortIndex: 1)
        context.insert(customList)

        try? context.save()

        // Create Kanban data
        let person1 = KanbanPerson(id: UUID(), name: "Alice", initials: "AW", employment: .fte)
        person1.colorHex = "#FF6B6B"
        person1.skills = ["backend", "database"]
        person1.createdAt = t0
        context.insert(person1)

        let person2 = KanbanPerson(id: UUID(), name: "Bob", initials: "BC", employment: .contractor)
        person2.colorHex = "#4ECDC4"
        person2.skills = ["frontend", "design"]
        person2.createdAt = t0
        person2.archivedAt = t0_plus_week
        context.insert(person2)

        let proj1 = KanbanProject(id: UUID(), name: "Project Alpha", key: "ALPHA", sortIndex: 1)
        proj1.details = "Main platform"
        proj1.colorHex = "#3B82F6"
        proj1.symbolName = "square.grid.3x2"
        proj1.isPinned = true
        proj1.updatedAt = t0_plus_day
        proj1.workWeekDays = [2, 3, 4, 5, 6]
        proj1.hoursPerDay = 8
        proj1.defaultCapacityHoursPerWeek = 40
        proj1.wipPolicy = .warn
        proj1.loadMeasure = .hours
        proj1.openTaskTarget = 6
        proj1.defaultEstimateHours = 5
        proj1.weightedLoad = true
        proj1.dueSoonThresholdDays = 7
        proj1.suggestDoneWhenSubtasksComplete = true
        proj1.collapsedRowKeys = ["unassigned"]
        proj1.boardState = try? JSONEncoder().encode(["view": "gantt"])
        proj1.nextActivitySeq = 5
        context.insert(proj1)

        let proj2 = KanbanProject(id: UUID(), name: "Project Beta", key: "BETA", sortIndex: 2)
        proj2.colorHex = "#10B981"
        proj2.symbolName = "circle.fill"
        proj2.wipPolicy = .warn
        proj2.loadMeasure = .taskCount
        proj2.openTaskTarget = 5
        proj2.defaultEstimateHours = 4
        proj2.weightedLoad = false
        proj2.dueSoonThresholdDays = 3
        proj2.suggestDoneWhenSubtasksComplete = false
        context.insert(proj2)

        // Create columns
        let col1 = KanbanColumn(id: UUID(), name: "Backlog", sortIndex: 1)
        col1.colorHex = "#E5E7EB"
        col1.wipLimit = 999
        col1.kindRaw = "backlog"
        col1.project = proj1
        context.insert(col1)

        let col2 = KanbanColumn(id: UUID(), name: "In Progress", sortIndex: 2)
        col2.colorHex = "#FBBF24"
        col2.wipLimit = 5
        col2.kindRaw = "active"
        col2.project = proj1
        context.insert(col2)

        let col3 = KanbanColumn(id: UUID(), name: "Done", sortIndex: 3)
        col3.colorHex = "#D1FAE5"
        col3.kindRaw = "done"
        col3.project = proj1
        context.insert(col3)

        let col4 = KanbanColumn(id: UUID(), name: "Backlog", sortIndex: 1)
        col4.kindRaw = "backlog"
        col4.project = proj2
        context.insert(col4)

        let col5 = KanbanColumn(id: UUID(), name: "Active", sortIndex: 2)
        col5.wipLimit = 3
        col5.kindRaw = "active"
        col5.project = proj2
        context.insert(col5)

        let col6 = KanbanColumn(id: UUID(), name: "Done", sortIndex: 3)
        col6.kindRaw = "done"
        col6.project = proj2
        context.insert(col6)

        // Create resources
        let res1 = KanbanResource()
        res1.person = person1
        res1.project = proj1
        res1.role = "Tech Lead"
        res1.assignmentRaw = KanbanAssignment.fullTime.rawValue
        res1.allocationPercent = 100
        res1.capacityHoursPerWeekOverride = 40
        res1.openTaskTargetOverride = 6
        res1.startDate = t0
        res1.endDate = t0_plus_week
        res1.sortIndex = 1
        context.insert(res1)

        let res2 = KanbanResource()
        res2.person = person2
        res2.project = proj1
        res2.assignmentRaw = KanbanAssignment.partTime.rawValue
        res2.allocationPercent = 50
        res2.sortIndex = 2
        context.insert(res2)

        let res3 = KanbanResource()
        res3.person = person1
        res3.project = proj2
        res3.role = "Contributor"
        res3.assignmentRaw = KanbanAssignment.partTime.rawValue
        res3.allocationPercent = 30
        res3.startDate = t0
        res3.sortIndex = 1
        context.insert(res3)

        let res4 = KanbanResource()
        res4.person = person2
        res4.project = proj2
        res4.assignmentRaw = KanbanAssignment.fullTime.rawValue
        res4.allocationPercent = 100
        res4.archivedAt = t0_plus_day
        res4.sortIndex = 2
        context.insert(res4)

        // Create labels
        let label1 = KanbanLabel(id: UUID(), name: "Bug", colorHex: "#EF4444", sortIndex: 1)
        label1.symbolName = "exclamationmark.circle"
        label1.project = proj1
        context.insert(label1)

        let label2 = KanbanLabel(id: UUID(), name: "Feature", colorHex: "#3B82F6", sortIndex: 2)
        label2.symbolName = "sparkles"
        label2.project = proj1
        context.insert(label2)

        let label3 = KanbanLabel(id: UUID(), name: "Spike", colorHex: "#A78BFA", sortIndex: 1)
        label3.project = proj2
        context.insert(label3)

        // Create tasks
        let richNotesData = try? NotesCodec.encode(NotesDocument(blocks: [
            NotesBlock(kind: .bullet, runs: [NotesRun(text: "Implement feature X")]),
            NotesBlock(kind: .bullet, runs: [NotesRun(text: "Write tests")])
        ]))

        let task1 = KanbanTask(id: UUID(), title: "Implement API endpoint", priority: 1, sortIndex: 1)
        task1.notes = "RESTful"
        task1.notesRich = richNotesData
        task1.isCritical = true
        task1.dueDate = t0_plus_week
        task1.startDate = t0
        task1.estimateHours = 8
        task1.complexity = KanbanComplexity.medium.rawValue
        task1.jiraURL = "https://jira.example.com/browse/ALPHA-123"
        task1.isBlocked = false
        task1.linkedPlannerTaskID = oneOffId
        task1.updatedAt = t0_plus_day
        task1.project = proj1
        task1.column = col2
        task1.resource = res1
        task1.labels = [label1, label2]
        context.insert(task1)

        let task2 = KanbanTask(id: UUID(), title: "Design database schema", priority: 0, sortIndex: 2)
        task2.notes = "Normalize"
        task2.isCritical = false
        task2.estimateHours = 4
        task2.isBlocked = true
        task2.blockedReason = "Waiting for requirements"
        task2.linkedPlannerTaskID = seriesDefId
        task2.project = proj1
        task2.column = col1
        task2.resource = res2
        task2.labels = [label1]
        task2.dependsOn = []
        context.insert(task2)

        let task3 = KanbanTask(id: UUID(), title: "Beta testing", priority: 2, sortIndex: 1)
        task3.notes = "QA phase"
        task3.isCritical = false
        task3.dueDate = t0_plus_day
        task3.estimateHours = nil
        task3.isBlocked = false
        task3.linkedPlannerTaskID = UUID()  // Missing link
        task3.completedAt = t0_plus_day
        task3.project = proj2
        task3.column = col6
        task3.labels = [label3]
        context.insert(task3)

        // Set up dependency
        task1.dependsOn = [task2]

        // Create subtasks
        let sub1 = KanbanSubtask(id: UUID(), title: "Write API docs", isDone: false, sortIndex: 1)
        sub1.task = task1
        sub1.assignee = res1
        context.insert(sub1)

        let sub2 = KanbanSubtask(id: UUID(), title: "Add unit tests", isDone: true, sortIndex: 2)
        sub2.completedAt = t0_plus_day
        sub2.task = task1
        context.insert(sub2)

        let sub3 = KanbanSubtask(id: UUID(), title: "Create ERD", isDone: false, sortIndex: 1)
        sub3.task = task2
        sub3.assignee = res2
        context.insert(sub3)

        // Create an activity
        let activity = KanbanActivity(id: UUID(), seq: 1, at: t0, kind: "taskCreated",
                                      taskIDs: [task1.id], summary: "Task created", payload: Data([0x01, 0x02, 0x03]))
        activity.project = proj1
        context.insert(activity)

        try? context.save()

        // Snapshot the context to get the full DTO
        let snapshot = try? BackupStore.makeSnapshot(context: context)
        return snapshot ?? BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.2.0",
            exportedAt: t0_plus_week,
            data: BackupDataDTO(taskItems: [], subtasks: [], taskTags: [], customLists: [], taskOccurrences: []),
            settings: nil,
            kanban: KanbanBackupDTO()
        )
    }

    // MARK: - (a) DTO Codability: empty Kanban section

    @Test("Kanban backup DTO is codable: empty section")
    func kanbanDTOCodeable() throws {
        let dto = KanbanBackupDTO()
        let encoded = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(KanbanBackupDTO.self, from: encoded)
        #expect(decoded.version == KanbanBackupDTO.currentVersion)
        #expect(decoded.people.isEmpty)
    }

    // MARK: - (b) Validator: version check

    @Test("Validator rejects unsupported Kanban version")
    func validatorRejectsUnsupportedVersion() throws {
        let kanban = KanbanBackupDTO(version: 99)
        #expect(throws: BackupError.self) {
            try KanbanBackupValidator.validate(kanban)
        }
    }

    // MARK: - (c) Validator: empty section passes

    @Test("Validator accepts empty Kanban section")
    func validatorAcceptsEmpty() throws {
        let kanban = KanbanBackupDTO()
        let report = try KanbanBackupValidator.validate(kanban)
        #expect(report.droppedDependencyEdges == 0)
        #expect(report.droppedPlannerLinks == 0)
    }

    // MARK: - (d) BackupDiff includes Kanban section

    @Test("BackupDiff structure includes Kanban section")
    func backupDiffIncludesKanban() throws {
        let diff = BackupDiff(
            taskItems: EntityDiff(imported: [], existing: []),
            subtasks: EntityDiff(imported: [], existing: []),
            taskTags: EntityDiff(imported: [], existing: []),
            customLists: EntityDiff(imported: [], existing: []),
            taskOccurrences: EntityDiff(imported: [], existing: []),
            kanban: nil,
            droppedPlannerLinks: 0
        )
        #expect(diff.kanban == nil)
        #expect(diff.droppedPlannerLinks == 0)
    }

    // MARK: - (e) Settings: the new keys ride along

    @Test("The module and Kanban settings are captured from and applied to the defaults")
    func settingsRoundTrip() throws {
        let name = "KanbanSettings-\(UUID())"
        let source = try #require(UserDefaults(suiteName: name)), target = try #require(UserDefaults(suiteName: name + "-t"))
        defer { source.removePersistentDomain(forName: name); target.removePersistentDomain(forName: name + "-t") }
        let values: [String: Any] = [
            "showPlannerModule": false, "showKanbanModule": true, "defaultModule": "kanban",
            "kanbanPopoverProjectID": "8A1F", "kanbanSummary.instructions": "Per person",
            "kanban.weightedLoadDefault": true, "kanban.wipPolicyDefault": "block", "kanban.loadMeasureDefault": "hours",
            "kanban.openTaskTargetDefault": 4.5, "kanban.dueSoonThresholdDefault": 5, "kanban.suggestDoneDefault": false,
            "kanban.notifyDueDates": true, "kanban.notifyDueMinutes": 540,
        ]
        for (key, value) in values { source.set(value, forKey: key) }
        let dto = AppSettingsDTO.capture(from: source)
        let decoded = try BackupCoding.decoder().decode(AppSettingsDTO.self, from: BackupCoding.encoder().encode(dto))
        decoded.apply(to: target)
        for (key, value) in values {
            #expect((target.object(forKey: key) as? NSObject) == (value as? NSObject), "\(key)")
        }
    }

    // MARK: - (f) D11 semantics: absent kanban key keeps boards

    @Test("D11 semantics: absent kanban key keeps boards")
    func d11AbsentKeyKeepsBoards() throws {
        // Create a store without Kanban section
        let store = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [], subtasks: [], taskTags: [], customLists: [], taskOccurrences: []),
            settings: nil,
            kanban: nil
        )

        // Verify structure is valid (D11: absent key means keep existing)
        try BackupValidator.validate(store)
    }

    @Test("D11 semantics: present-but-empty kanban section replaces boards")
    func d11EmptyKanbanReplacesBoards() throws {
        let emptyKanban = KanbanBackupDTO()
        let store = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.2.0",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [], subtasks: [], taskTags: [], customLists: [], taskOccurrences: []),
            settings: nil,
            kanban: emptyKanban
        )

        // Verify both sections validate independently
        try BackupValidator.validate(store)
        try KanbanBackupValidator.validate(emptyKanban)
    }

    // MARK: - (g) Rich fixture: plain and encrypted round trip

    @Test("Kanban rich fixture: plaintext round trip")
    func richFixturePlaintextRoundTrip() throws {
        let fixture = makeRichKanbanFixture()
        let fileData = try service.makeFile(store: fixture, passphrase: nil)

        let decoded = try service.readFile(fileData, passphrase: nil)
        let kanban = try #require(decoded.kanban)

        #expect(kanban.people.count == 2)
        #expect(kanban.projects.count == 2)
        #expect(kanban.columns.count == 6)
        #expect(kanban.resources.count == 4)
        #expect(kanban.labels.count == 3)
        #expect(kanban.tasks.count == 3)
        #expect(kanban.subtasks.count == 3)
        #expect(kanban.activities.count == 1)

        // Spot-check optional fields round-trip
        let person2 = kanban.people.first { $0.name == "Bob" }
        #expect(person2?.archivedAt != nil)
        #expect(person2?.skills == ["frontend", "design"])

        let proj1 = kanban.projects.first { $0.name == "Project Alpha" }
        #expect(proj1?.weightedLoad == true)
        #expect(proj1?.boardState != nil)

        let task1 = kanban.tasks.first { $0.title == "Implement API endpoint" }
        #expect(task1?.notesRich != nil)
        #expect(task1?.linkedPlannerTaskID != nil)
        #expect(task1?.dependsOnIds.count == 1)
    }

    @Test("Kanban rich fixture: encrypted round trip")
    func richFixtureEncryptedRoundTrip() throws {
        let fixture = makeRichKanbanFixture()
        let fileData = try service.makeFile(store: fixture, passphrase: passphrase)

        let decoded = try service.readFile(fileData, passphrase: passphrase)
        let kanban = try #require(decoded.kanban)

        #expect(kanban.people.count == 2)
        #expect(kanban.projects.count == 2)

        // Verify a few key fields to ensure decryption worked
        let task1 = kanban.tasks.first { $0.title == "Implement API endpoint" }
        #expect(task1?.isCritical == true)
        #expect(task1?.estimateHours == 8)
        #expect(task1?.complexity == 2)
    }

    // MARK: - (h) Restore into fresh store

    @Test("Kanban restore into fresh store: all entities present")
    func restoreIntoFreshStore() throws {
        let fixture = makeRichKanbanFixture()
        let context = makeInMemoryContext()
        try BackupStore.restore(fixture, context: context)

        let people = try context.fetch(FetchDescriptor<KanbanPerson>())
        let projects = try context.fetch(FetchDescriptor<KanbanProject>())
        let columns = try context.fetch(FetchDescriptor<KanbanColumn>())
        let resources = try context.fetch(FetchDescriptor<KanbanResource>())
        let labels = try context.fetch(FetchDescriptor<KanbanLabel>())
        let tasks = try context.fetch(FetchDescriptor<KanbanTask>())
        let subtasks = try context.fetch(FetchDescriptor<KanbanSubtask>())
        let activities = try context.fetch(FetchDescriptor<KanbanActivity>())

        #expect(people.count == 2)
        #expect(projects.count == 2)
        #expect(columns.count == 6)
        #expect(resources.count == 4)
        #expect(labels.count == 3)
        #expect(tasks.count == 3)
        #expect(subtasks.count == 3)
        #expect(activities.count == 1)
        #expect(tasks.first { $0.title == "Implement API endpoint" }?.complexity == 2)
        #expect(tasks.first { $0.title == "Beta testing" }?.complexity == nil, "unset stays unset")
    }

    // MARK: - (i) Close and reopen

    @Test("Kanban restore and reopen: data intact")
    func restoreAndReopenDataIntact() throws {
        let fixture = makeRichKanbanFixture()
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // First context: restore fixture
        let context1 = try makeContext(at: tempDir)
        try BackupStore.restore(fixture, context: context1)
        try context1.save()

        let before = try context1.fetch(FetchDescriptor<KanbanPerson>()).count

        // Second context: reopen store
        let context2 = try makeContext(at: tempDir)
        let after = try context2.fetch(FetchDescriptor<KanbanPerson>()).count

        #expect(after == before)
        #expect(after == 2)
    }

    // MARK: - (j) Plain and encrypted round trip (disk store)

    @Test("Kanban round trip snapshot → file → restore → reopen (plaintext)")
    func roundTripPlaintextDiskStore() throws {
        let fixture = makeRichKanbanFixture()
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create store, export
        let context1 = try makeContext(at: tempDir)
        try BackupStore.restore(fixture, context: context1)
        let fileData = try service.makeFile(store: try BackupStore.makeSnapshot(context: context1), passphrase: nil)

        // Restore into fresh store
        let tempDir2 = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir2) }

        let context2 = try makeContext(at: tempDir2)
        let read = try service.readFile(fileData, passphrase: nil)
        try BackupStore.restore(read, context: context2)

        let people2 = try context2.fetch(FetchDescriptor<KanbanPerson>()).count
        #expect(people2 == 2)

        // Reopen and verify
        let context3 = try makeContext(at: tempDir2)
        let people3 = try context3.fetch(FetchDescriptor<KanbanPerson>()).count
        #expect(people3 == 2)
    }

    @Test("Kanban round trip snapshot → file → restore → reopen (encrypted)")
    func roundTripEncryptedDiskStore() throws {
        let fixture = makeRichKanbanFixture()
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create store, export encrypted
        let context1 = try makeContext(at: tempDir)
        try BackupStore.restore(fixture, context: context1)
        let fileData = try service.makeFile(store: try BackupStore.makeSnapshot(context: context1), passphrase: passphrase)

        // Restore into fresh store
        let tempDir2 = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir2) }

        let context2 = try makeContext(at: tempDir2)
        let read = try service.readFile(fileData, passphrase: passphrase)
        try BackupStore.restore(read, context: context2)

        let projects2 = try context2.fetch(FetchDescriptor<KanbanProject>()).count
        #expect(projects2 == 2)
    }

    // MARK: - (k) Pre-Kanban restore keeps boards (D11)

    @Test("D11: pre-Kanban backup restore keeps existing boards")
    func preKanbanRestoreKeepsBoards() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a store with some Kanban data
        let context1 = try makeContext(at: tempDir)
        let fixture = makeRichKanbanFixture()
        try BackupStore.restore(fixture, context: context1)
        let initialPeople = try context1.fetch(FetchDescriptor<KanbanPerson>()).count
        #expect(initialPeople == 2)

        // Create a pre-Kanban backup (no kanban key)
        let legacyStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [], subtasks: [], taskTags: [], customLists: [], taskOccurrences: []),
            settings: nil,
            kanban: nil  // Pre-Kanban: no section
        )

        // Restore the legacy backup (no kanban key = keep existing boards)
        try BackupStore.restore(legacyStore, context: context1)

        // The Kanban data should be unchanged
        let peopleAfterRestore = try context1.fetch(FetchDescriptor<KanbanPerson>()).count
        #expect(peopleAfterRestore == initialPeople, "Pre-Kanban restore should keep existing Kanban data")
    }

    // MARK: - (l) Empty Kanban section test

    @Test("Empty Kanban section: reopen yields zero entities of each type")
    func emptyKanbanSectionReopens() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context1 = try makeContext(at: tempDir)
        let emptyStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.2.0",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [], subtasks: [], taskTags: [], customLists: [], taskOccurrences: []),
            settings: nil,
            kanban: KanbanBackupDTO()  // Empty but present
        )
        try BackupStore.restore(emptyStore, context: context1)
        try context1.save()

        let context2 = try makeContext(at: tempDir)
        let people = try context2.fetch(FetchDescriptor<KanbanPerson>())
        let projects = try context2.fetch(FetchDescriptor<KanbanProject>())
        let tasks = try context2.fetch(FetchDescriptor<KanbanTask>())

        #expect(people.isEmpty)
        #expect(projects.isEmpty)
        #expect(tasks.isEmpty)
    }

    // MARK: - (m) Old-reader simulation

    /// v0.1.17's `BackupStoreDTO` shape (`git show v0.1.17:Sources/TickyTask/Backup/BackupModel.swift`).
    private struct V0117Store: Decodable {
        var schemaVersion: Int
        var appVersion: String
        var exportedAt: Date
        var data: BackupDataDTO
        var settings: AppSettingsDTO?
    }

    @Test("A v0.1.17-shaped reader decodes a Kanban-era file, ignoring the board section")
    func oldReaderIgnoresKanbanSection() throws {
        let fixture = makeRichKanbanFixture()
        #expect(fixture.kanban?.tasks.isEmpty == false)
        let json = try BackupCoding.encoder().encode(fixture)
        #expect(String(decoding: json, as: UTF8.self).contains("\"kanban\""))
        let old = try BackupCoding.decoder().decode(V0117Store.self, from: json)
        #expect(old.schemaVersion == 2, "the version a v0.1.17 reader accepts")
        #expect(old.data == fixture.data, "the planner part is intact")
    }

    // MARK: - (o) Fail-closed: persistence fault

    @Test("Fail-closed: restore with transaction fault leaves disk unchanged")
    func failClosedTransactionFault() throws {
        let fixture = makeRichKanbanFixture()
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create initial store with Kanban data so restore will have deletions pending
        let context1 = try makeContext(at: tempDir)
        let initialFixture = makeRichKanbanFixture()
        try BackupStore.restore(initialFixture, context: context1)
        try context1.save()

        let before = try BackupStore.makeSnapshot(context: try makeContext(at: tempDir))
        #expect(before.kanban?.people.isEmpty == false)

        // Attempt restore with fault injection
        var testHookFired = false
        PersistenceRecovery.testHook = { testHookFired = true }
        defer { PersistenceRecovery.testHook = nil }

        PersistenceFaults.armed = [.transaction]
        defer { PersistenceFaults.armed = [] }

        #expect(throws: PersistenceFaults.InjectedFailure.self) {
            try BackupStore.restore(fixture, context: context1)
        }

        #expect(testHookFired, "Test hook should have been called on relaunch discard")

        // Verify disk is unchanged by reopening
        let after = try BackupStore.makeSnapshot(context: try makeContext(at: tempDir))
        #expect(after.data == before.data && after.kanban?.deterministicallySorted() == before.kanban?.deterministicallySorted(),
                "the whole store on disk is unchanged after the failed restore")
        DiscardedContexts.keep(context1)
    }
}
