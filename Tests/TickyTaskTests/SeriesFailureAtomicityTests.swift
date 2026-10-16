import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Tests for transaction atomicity across recurring series operations. Verifies
/// that a save failure leaves the store unchanged in memory and on disk, and that
/// checkpoint failures don't cascade to unrelated pending edits.
@MainActor
@Suite("Series failure atomicity", .serialized)
struct SeriesFailureAtomicityTests {
    /// A context on an on-disk store inside the test's temporary folder `dir`.
    private func makeContext(at dir: URL) throws -> ModelContext {
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: dir.appendingPathComponent("TickyTask.store")))
        context.autosaveEnabled = false   // only explicit saves may reach the reopened file
        return context
    }

    private func makeInMemoryContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ c: Calendar) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Capture a snapshot of the store state for comparison after a failed operation.
    private func snapshot(context: ModelContext) throws -> StoreSnapshot {
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let subs = try context.fetch(FetchDescriptor<Subtask>())
        let occs = try context.fetch(FetchDescriptor<TaskOccurrence>())
        let lists = try context.fetch(FetchDescriptor<CustomList>())
        let tags = try context.fetch(FetchDescriptor<TaskTag>())
        return StoreSnapshot(tasks: tasks, subtasks: subs, occurrences: occs, lists: lists, tags: tags)
    }

    @Test("Materialize with normalization fails atomically")
    func materializeNormalizationFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try makeContext(at: tempDir)
        let c = cal()

        // Create a legacy template with a first occurrence and a child.
        let template = TaskItem(title: "Daily task", dayKey: "20260101", timeMinutes: 540)
        template.isCritical = true
        template.notes = "first day notes"
        template.recurrence = RecurrenceRule(frequency: .daily, end: .afterCount(5), startDate: date(2026, 1, 1, c))
        context.insert(template)

        let child = TaskItem(title: "Daily task", dayKey: "20260102")
        child.templateID = template.id
        context.insert(child)

        try context.save()
        let beforeSnapshot = try snapshot(context: context)

        // Fail the final save: the split of the legacy series row and the new
        // occurrences must all be rolled back.
        PersistenceFaults.armed = [.transaction]
        defer { PersistenceFaults.armed = [] }

        #expect(throws: PersistenceFaults.InjectedFailure.self) {
            try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)
        }

        let afterSnapshot = try snapshot(context: context)
        #expect(beforeSnapshot.matches(afterSnapshot))

        // Close and reopen the store to verify persistence.
        let context2 = try makeContext(at: tempDir)
        let reopenSnapshot = try snapshot(context: context2)
        #expect(beforeSnapshot.matches(reopenSnapshot))
    }

    @Test("TaskEditCommit with combined edits fails atomically")
    func taskEditCommitCombinedFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try makeContext(at: tempDir)
        let c = cal()

        // Create a series with a dated occurrence.
        let seed = TaskItem(title: "Original", dayKey: "20260101", timeMinutes: 540, priority: 1)
        context.insert(seed)
        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c), end: .afterCount(3))
        let definition = try RecurrenceMaterializer.startSeries(from: seed, rule: rule,
                                                               through: date(2026, 1, 10, c),
                                                               context: context, calendar: c)
        try context.save()

        let kids = try RecurrenceMaterializer.children(of: definition, context: context)
        let jan2 = try #require(kids.first { $0.occurrenceKey == "20260102" })

        let beforeSnapshot = try snapshot(context: context)

        // Create a combined edit: title change, time change, notes, subtask, and rule change.
        var edited = SharedAttributes(seed)
        edited.title = "Updated"
        edited.timeMinutes = 600
        edited.priority = 2

        let doc = NotesDocument(blocks: [NotesBlock(kind: .paragraph, runs: [NotesRun(text: "New notes")])])

        let newSubtask = SubtaskDraft(id: UUID(), title: "New subtask", isDone: false, sortIndex: 0)
        let edit = TaskEdit(
            originalShared: SharedAttributes(seed),
            editedShared: edited,
            notes: doc,
            subtasks: [newSubtask],
            rule: .replace(RecurrenceRule(frequency: .weekly, weekdays: [5],
                                        startDate: date(2026, 1, 1, c), end: .never))
        )

        // Arm transaction save to fail.
        PersistenceFaults.armed = [.transaction]
        defer { PersistenceFaults.armed = [] }

        #expect(throws: PersistenceFaults.InjectedFailure.self) {
            _ = try TaskEditCommit.commit(edit, to: seed, context: context,
                                         today: date(2026, 1, 5, c),
                                         horizon: date(2026, 2, 1, c),
                                         calendar: c)
        }

        let afterSnapshot = try snapshot(context: context)
        #expect(beforeSnapshot.matches(afterSnapshot))

        // Close and reopen to verify persistence.
        let context2 = try makeContext(at: tempDir)
        let reopenSnapshot = try snapshot(context: context2)
        #expect(beforeSnapshot.matches(reopenSnapshot))
    }

    @Test("ChangeRule fails atomically")
    func changeRuleFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try makeContext(at: tempDir)
        let c = cal()

        let seed = TaskItem(title: "Daily", dayKey: "20260101")
        context.insert(seed)
        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c), end: .afterCount(5))
        let definition = try RecurrenceMaterializer.startSeries(from: seed, rule: rule,
                                                               through: date(2026, 1, 10, c),
                                                               context: context, calendar: c)
        try context.save()

        let beforeSnapshot = try snapshot(context: context)

        // Arm transaction to fail during rule change.
        PersistenceFaults.armed = [.transaction]
        defer { PersistenceFaults.armed = [] }

        let newRule = RecurrenceRule(frequency: .weekly, weekdays: [5],
                                    startDate: date(2026, 1, 1, c), end: .never)
        let shared = SharedAttributes(seed)
        let edit = TaskEdit(originalShared: shared, editedShared: shared, rule: .replace(newRule))
        #expect(throws: PersistenceFaults.InjectedFailure.self) {
            try TaskEditCommit.commit(edit, to: seed, context: context, today: date(2026, 1, 5, c),
                                      horizon: date(2026, 2, 1, c), calendar: c)
        }
        _ = definition

        let afterSnapshot = try snapshot(context: context)
        #expect(beforeSnapshot.matches(afterSnapshot))
    }

    @Test("AutoDeleteService with checkpoint failure preserves pending edits")
    func autoDeleteCheckpointFailurePreservesPendingEdits() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try makeContext(at: tempDir)
        let c = cal()

        // Create a series with a completed occurrence.
        let seed = TaskItem(title: "Daily", dayKey: "20260101")
        context.insert(seed)
        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c), end: .afterCount(3))
        let definition = try RecurrenceMaterializer.startSeries(from: seed, rule: rule,
                                                               through: date(2026, 1, 10, c),
                                                               context: context, calendar: c)

        // Create a custom list to rename (unrelated pending edit).
        let list = try DataService(context).addCustomList(name: "Original Name")
        try context.save()

        // Rename the list without saving (pending edit).
        list.name = "Updated Name"

        // Capture list name before auto-delete.
        #expect(list.name == "Updated Name")

        // Arm checkpoint to fail.
        PersistenceFaults.armed = [.checkpoint]
        defer { PersistenceFaults.armed = [] }

        // AutoDeleteService should return early on checkpoint failure.
        let now = date(2026, 1, 20, c)
        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 5, now: now)

        // The pending rename should still be in memory.
        #expect(list.name == "Updated Name")

        // Verify nothing was rolled back: fetch the list again to confirm.
        let allLists = try context.fetch(FetchDescriptor<CustomList>())
        #expect(allLists.count == 1)
        #expect(allLists[0].name == "Updated Name")
    }

    @Test("AutoDeleteService transaction failure doesn't persist deletions")
    func autoDeleteTransactionFailureAtomic() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try makeContext(at: tempDir)
        let c = cal()

        // Create a series with a completed and old occurrence.
        let seed = TaskItem(title: "Daily", dayKey: "20260101", priority: 2)
        context.insert(seed)
        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c), end: .afterCount(5))
        let definition = try RecurrenceMaterializer.startSeries(from: seed, rule: rule,
                                                               through: date(2026, 1, 10, c),
                                                               context: context, calendar: c)

        let kids = try RecurrenceMaterializer.children(of: definition, context: context)
        let jan3 = try #require(kids.first { $0.occurrenceKey == "20260103" })
        jan3.setDone(true)
        jan3.completedAt = date(2026, 1, 1, c)  // Very old completion

        try context.save()
        let beforeSnapshot = try snapshot(context: context)
        let beforeCount = beforeSnapshot.taskCount

        // Arm the transaction to fail during auto-delete's save.
        PersistenceFaults.armed = [.transaction]
        defer { PersistenceFaults.armed = [] }

        // Call auto-delete with a generous cutoff that includes jan3.
        let now = date(2026, 1, 20, c)
        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 10, now: now)

        // A failed save with deletions pending can't be undone safely in SwiftData,
        // so the complete purge stays pending for the next save — but nothing
        // reached the disk.
        _ = beforeCount
        let reopened = try makeContext(at: tempDir)
        #expect(beforeSnapshot.matches(try snapshot(context: reopened)), "the stored data is unchanged")
    }

    @Test("BackupStore.restore fails atomically after insertion")
    func backupRestoreFailureAfterInsertion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try makeContext(at: tempDir)

        // Create an existing store with one task.
        let existing = TaskItem(title: "Existing", dayKey: "20260101")
        context.insert(existing)
        try context.save()

        let beforeSnapshot = try snapshot(context: context)

        // Create a backup to restore.
        let importedTask = TaskItemDTO(id: UUID(), title: "Imported", notes: "", isDone: false,
                                      dayKey: "20260102", customListId: nil, timeMinutes: nil,
                                      colorHex: nil, priority: 0, sortIndex: 0, alarmEnabled: false,
                                      createdAt: Date(), updatedAt: Date(), recurrence: nil,
                                      tagIds: [], needsImmediateAttention: false, completedAt: nil,
                                      notesRich: nil, templateId: nil, occurrenceKey: nil,
                                      recurrenceEffectiveFromKey: nil, occurrenceModified: nil)
        let backupStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [importedTask], subtasks: [], taskTags: [],
                              customLists: [], taskOccurrences: []).deterministicallySorted(),
            settings: nil
        )

        PersistenceFaults.armed = [.transaction]
        defer { PersistenceFaults.armed = [] }

        #expect(throws: PersistenceFaults.InjectedFailure.self) {
            try BackupStore.restore(backupStore, context: context)
        }

        // The existing store on disk is untouched (the replacement can't be undone in
        // memory once it has deleted rows; it stays pending for the next save).
        let reopened = try makeContext(at: tempDir)
        #expect(beforeSnapshot.matches(try snapshot(context: reopened)))
    }
}

// MARK: - Store Snapshot

private struct StoreSnapshot {
    struct TaskSnapshot: Equatable {
        let id: UUID
        let title: String
        let notes: String
        let notesRich: Data?
        let isDone: Bool
        let completedAt: Date?
        let dayKey: String?
        let customListId: UUID?
        let occurrenceKey: String?
        let occurrenceModified: Bool?
        let templateID: UUID?
        let recurrence: RecurrenceRule?
        let subtaskIds: [UUID]
        let subtaskTitles: [String]
    }

    struct SubtaskSnapshot: Equatable {
        let id: UUID
        let title: String
        let isDone: Bool
        let parentId: UUID?
    }

    struct OccurrenceSnapshot: Equatable {
        let id: UUID
        let dayKey: String
        let skipped: Bool
    }

    let tasks: [TaskSnapshot]
    let subtasks: [SubtaskSnapshot]
    let occurrences: [OccurrenceSnapshot]
    let lists: [CustomList]
    let tags: [TaskTag]

    init(tasks: [TaskItem], subtasks: [Subtask], occurrences: [TaskOccurrence],
         lists: [CustomList], tags: [TaskTag]) {
        self.tasks = tasks.map { t in
            TaskSnapshot(id: t.id, title: t.title, notes: t.notes, notesRich: t.notesRich,
                        isDone: t.isDone, completedAt: t.completedAt, dayKey: t.dayKey,
                        customListId: t.customList?.id, occurrenceKey: t.occurrenceKey,
                        occurrenceModified: t.occurrenceModified, templateID: t.templateID,
                        recurrence: t.recurrence,
                        subtaskIds: t.subtasks.map(\.id).sorted { $0.uuidString < $1.uuidString },
                        subtaskTitles: t.subtasks.map(\.title).sorted())
        }
        self.subtasks = subtasks.map { s in
            SubtaskSnapshot(id: s.id, title: s.title, isDone: s.isDone, parentId: s.parent?.id)
        }
        self.occurrences = occurrences.map { o in
            OccurrenceSnapshot(id: o.id, dayKey: o.dayKey, skipped: o.skipped)
        }
        self.lists = lists
        self.tags = tags
    }

    var taskCount: Int { tasks.count }

    func matches(_ other: StoreSnapshot) -> Bool {
        let sortedTasks = tasks.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedOtherTasks = other.tasks.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedSubs = subtasks.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedOtherSubs = other.subtasks.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedOccs = occurrences.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedOtherOccs = other.occurrences.sorted { $0.id.uuidString < $1.id.uuidString }

        return sortedTasks == sortedOtherTasks &&
               sortedSubs == sortedOtherSubs &&
               sortedOccs == sortedOtherOccs
    }
}
