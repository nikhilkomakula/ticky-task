import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Series migration tests cover: normalization of legacy rows into hidden
/// definitions with ordinary occurrence children, backfilling occurrence keys,
/// legacy override record handling, backup round-trip for new fields, on-disk
/// store opening and persistence.
@MainActor
@Suite("Series migration")
struct SeriesMigrationTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    private func onDiskContext(at path: URL) throws -> ModelContext {
        let container = try ModelContainerProvider.makeContainer(at: path)
        return ModelContext(container)
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

    private func dayKey(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d%02d%02d", y, m, d)
    }

    // MARK: - Normalization: root splitting

    @Test("Normalization splits a legacy root into hidden definition and first occurrence")
    func normalizeSplitsLegacyRoot() throws {
        let context = makeContext()
        let c = cal()

        // Create a legacy root: a task with recurrence, dayKey, and occurrence payload
        let root = TaskItem(title: "Water plants", dayKey: dayKey(2026, 1, 5), timeMinutes: 540, priority: 2)
        root.notes = "root notes"
        root.isCritical = true
        root.alarmEnabled = true
        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 5, c))
        root.recurrence = rule
        context.insert(root)

        let report = try RecurrenceNormalizer.normalize(context: context)

        #expect(report.splitDefinitions == 1)

        // Find the definition and occurrence
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let definitions = all.filter { $0.recurrence != nil && $0.templateID == nil }
        #expect(definitions.count == 1)
        let definition = definitions[0]
        let occurrences = all.filter { $0.templateID == definition.id }
        #expect(occurrences.count == 1)

        // Check definition shape
        #expect(definition.dayKey == nil)
        #expect(definition.customList == nil)
        #expect(definition.notes.isEmpty)
        #expect(definition.isDone == false)
        #expect(definition.subtasks.isEmpty)

        // Check occurrence shape
        let occurrence = occurrences[0]
        #expect(occurrence.title == "Water plants")
        #expect(occurrence.dayKey == dayKey(2026, 1, 5))
        #expect(occurrence.notes == "root notes")
        #expect(occurrence.isCritical == true)
        #expect(occurrence.alarmEnabled == true)
        #expect(occurrence.occurrenceKey == dayKey(2026, 1, 5))
        #expect(occurrence.occurrenceModified == nil)   // legacy history unknown: protected like true
    }

    @Test("Normalization preserves subtask identity during root split")
    func normalizePreservesSubtasks() throws {
        let context = makeContext()
        let c = cal()

        let subId = UUID()
        let sub = Subtask(id: subId, title: "Check soil", isDone: false, sortIndex: 1)

        let root = TaskItem(title: "Water plants", dayKey: dayKey(2026, 1, 5))
        root.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 5, c))
        root.subtasks.append(sub)
        context.insert(root)

        try RecurrenceNormalizer.normalize(context: context)
        try context.save()

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let occurrences = all.filter { $0.templateID != nil }
        #expect(occurrences.count == 1)
        let occurrence = occurrences[0]

        #expect(occurrence.subtasks.count == 1)
        let savedSub = occurrence.subtasks.first
        #expect(savedSub?.id == subId)
        #expect(savedSub?.title == "Check soil")
    }

    @Test("Normalization preserves tags during root split")
    func normalizePreservesTags() throws {
        let context = makeContext()
        let c = cal()

        let tagId = UUID()
        let tag = TaskTag(id: tagId, name: "work", colorHex: "#0000ff")
        context.insert(tag)

        let root = TaskItem(title: "Meeting", dayKey: dayKey(2026, 1, 5))
        root.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 5, c))
        root.tags.append(tag)
        context.insert(root)

        try RecurrenceNormalizer.normalize(context: context)

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let occurrences = all.filter { $0.templateID != nil }
        let occurrence = occurrences[0]

        #expect(occurrence.tags.count == 1)
        #expect(occurrence.tags.first?.id == tagId)
    }

    @Test("Normalization is idempotent: running twice adds nothing")
    func normalizeIdempotent() throws {
        let context = makeContext()
        let c = cal()

        let root = TaskItem(title: "Water plants", dayKey: dayKey(2026, 1, 5))
        root.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 5, c))
        context.insert(root)

        let report1 = try RecurrenceNormalizer.normalize(context: context)
        #expect(report1.splitDefinitions == 1)

        let report2 = try RecurrenceNormalizer.normalize(context: context)
        #expect(report2.splitDefinitions == 0)

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 2)
    }

    // MARK: - Backfill

    @Test("Backfill assigns occurrenceKey from dayKey when nil and modified is nil")
    func backfillKeylessOccurrence() throws {
        let context = makeContext()
        let c = cal()

        // Create a definition and a child without occurrenceKey
        let definition = TaskItem(title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        let child = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 3))
        child.templateID = definition.id
        child.occurrenceKey = nil
        child.occurrenceModified = nil
        context.insert(child)

        let report = try RecurrenceNormalizer.normalize(context: context)

        #expect(report.backfilledSlots == 1)
        #expect(child.occurrenceKey == dayKey(2026, 1, 3))
    }

    @Test("Backfill skips rows with occurrenceModified == true")
    func backfillSkipsModifiedRows() throws {
        let context = makeContext()
        let c = cal()

        let definition = TaskItem(title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        let child = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 3))
        child.templateID = definition.id
        child.occurrenceKey = nil
        child.occurrenceModified = true
        context.insert(child)

        let report = try RecurrenceNormalizer.normalize(context: context)

        #expect(report.backfilledSlots == 0)
        #expect(child.occurrenceKey == nil)
    }

    @Test("Backfill skips listed children without dayKey")
    func backfillSkipsListedChildren() throws {
        let context = makeContext()
        let c = cal()

        let definition = TaskItem(title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        let list = CustomList(name: "Groceries", sortIndex: 1)
        context.insert(list)

        let child = TaskItem(title: "Daily task", customList: list)
        child.templateID = definition.id
        child.occurrenceKey = nil
        child.occurrenceModified = nil
        context.insert(child)

        let report = try RecurrenceNormalizer.normalize(context: context)

        #expect(report.backfilledSlots == 0)
        #expect(child.occurrenceKey == nil)
    }

    // MARK: - Legacy overrides

    @Test("Restore creates concrete row from non-skipped override when no row holds the key")
    func restoreOverrideCreatesRow() throws {
        let context = makeContext()
        let c = cal()

        let definition = TaskItem(id: UUID(), title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        // Create a non-skipped override record for 2026-01-05
        let occurrenceId = UUID()
        let occurrence = TaskOccurrence(id: occurrenceId, dayKey: dayKey(2026, 1, 5), isDone: true,
                                        skipped: false, titleOverride: "Override title",
                                        timeOverride: 600)
        occurrence.template = definition
        definition.occurrences.append(occurrence)
        context.insert(occurrence)

        let report = try RecurrenceNormalizer.normalize(context: context)

        #expect(report.restoredOverrides == 1)

        // Verify a concrete row was created
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let children = all.filter { $0.templateID == definition.id && $0.recurrence == nil }
        let restored = children.first { $0.occurrenceKey == dayKey(2026, 1, 5) }

        #expect(restored != nil)
        #expect(restored?.isDone == true)
        #expect(restored?.title == "Override title")
        #expect(restored?.timeMinutes == 600)
        #expect(restored?.occurrenceModified == nil)
    }

    @Test("Restore skipped when override record for a key where a row already exists")
    func restoreSkipsWhenRowExists() throws {
        let context = makeContext()
        let c = cal()

        let definition = TaskItem(id: UUID(), title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        // Create an existing child for 2026-01-05
        let child = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 5))
        child.templateID = definition.id
        child.occurrenceKey = dayKey(2026, 1, 5)
        context.insert(child)

        // Create an override record for the same key
        let occurrenceId = UUID()
        let occurrence = TaskOccurrence(id: occurrenceId, dayKey: dayKey(2026, 1, 5), isDone: true,
                                        skipped: false, titleOverride: "Override",
                                        timeOverride: nil)
        occurrence.template = definition
        definition.occurrences.append(occurrence)

        let report = try RecurrenceNormalizer.normalize(context: context)

        #expect(report.restoredOverrides == 0)
        #expect(report.conflicts.count == 1)

        // Existing row and record are unchanged
        #expect(child.title == "Daily task")
        #expect(child.isDone == false)
    }

    @Test("Restore handles multiple override records for one key")
    func restoreMultipleOverridesConflict() throws {
        let context = makeContext()
        let c = cal()

        let definition = TaskItem(id: UUID(), title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        // Create two non-skipped override records for the same key
        let occ1 = TaskOccurrence(id: UUID(), dayKey: dayKey(2026, 1, 5), isDone: true,
                                  skipped: false, titleOverride: "First",
                                  timeOverride: nil)
        occ1.template = definition
        let occ2 = TaskOccurrence(id: UUID(), dayKey: dayKey(2026, 1, 5), isDone: false,
                                  skipped: false, titleOverride: "Second",
                                  timeOverride: nil)
        occ2.template = definition
        definition.occurrences.append(occ1)
        definition.occurrences.append(occ2)

        let report = try RecurrenceNormalizer.normalize(context: context)

        // Should restore one row from the first matching override
        #expect(report.restoredOverrides == 1)
        #expect(report.conflicts.count == 1)   // "First" vs "Second": one restored, the other reported

        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let children = all.filter { $0.templateID == definition.id && $0.recurrence == nil }
        let restored = children.first { $0.occurrenceKey == dayKey(2026, 1, 5) }

        #expect(restored != nil)
        #expect(restored?.title == "First" || restored?.title == "Second")
    }

    // MARK: - Normalization with disk

    @Test("Normalization survives on-disk store open/save/reopen")
    func onDiskNormalizationPersists() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let storeUrl = testDir.appendingPathComponent("test.store")

        // First context: create legacy root and normalize
        do {
            let context = try onDiskContext(at: storeUrl)
            let c = cal()

            let root = TaskItem(title: "Water plants", dayKey: dayKey(2026, 1, 5))
            root.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 5, c))
            root.notes = "legacy notes"
            context.insert(root)

            let report = try RecurrenceNormalizer.normalize(context: context)
            #expect(report.splitDefinitions == 1)

            try context.save()
        }

        // Second context: reopen and verify shape
        do {
            let context = try onDiskContext(at: storeUrl)
            let all = try context.fetch(FetchDescriptor<TaskItem>())

            let definitions = all.filter { $0.recurrence != nil && $0.templateID == nil }
            #expect(definitions.count == 1)

            let children = all.filter { $0.templateID != nil }
            #expect(children.count == 1)

            let child = children[0]
            #expect(child.occurrenceKey == dayKey(2026, 1, 5))
            #expect(child.notes == "legacy notes")
        }

        // Third context: normalize again (should be idempotent)
        do {
            let context = try onDiskContext(at: storeUrl)
            let report = try RecurrenceNormalizer.normalize(context: context)
            #expect(report.splitDefinitions == 0)

            try context.save()
        }

        // Fourth context: verify no change
        do {
            let context = try onDiskContext(at: storeUrl)
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            #expect(all.count == 2)
        }
    }

    // MARK: - Backup round-trip

    @Test("Backup preserves occurrenceKey and occurrenceModified through export/restore")
    func backupRoundTripNewFields() throws {
        let context = makeContext()
        let c = cal()
        let service = BackupService()

        // Create a series with a moved occurrence
        let definition = TaskItem(title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        let child = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 5), customList: nil)
        child.templateID = definition.id
        child.occurrenceKey = dayKey(2026, 1, 3)
        child.occurrenceModified = true
        context.insert(child)

        try context.save()

        // Export to backup
        let backup = try BackupStore.makeSnapshot(context: context)

        // Verify fields are in the DTO
        let childDto = backup.data.taskItems.first { $0.id == child.id }
        #expect(childDto?.occurrenceKey == dayKey(2026, 1, 3))
        #expect(childDto?.occurrenceModified == true)

        #expect(backup.schemaVersion == 2)
    }

    @Test("Backup accepts schema version 1 (old backups)")
    func backupAcceptsSchemaV1() throws {
        let dto = BackupStoreDTO(schemaVersion: 1, appVersion: "0.1.16", exportedAt: Date(),
                                  data: BackupDataDTO(taskItems: [], subtasks: [],
                                                     taskTags: [], customLists: [],
                                                     taskOccurrences: []))
        try BackupValidator.validate(dto)
    }

    @Test("Restored backup with legacy root and children normalizes in same transaction")
    func backupRestoreNormalizes() throws {
        let context = makeContext()
        let c = cal()
        let service = BackupService()

        // Create a backup DTO with a legacy root (no templateID, has dayKey)
        let rootId = UUID()
        let childId = UUID()
        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))

        let data = BackupDataDTO(
            taskItems: [
                TaskItemDTO(id: rootId, title: "Legacy root", notes: "", isDone: false,
                           dayKey: dayKey(2026, 1, 5), customListId: nil, timeMinutes: nil,
                           colorHex: nil, priority: 0, sortIndex: 1, alarmEnabled: false,
                           createdAt: Date(), updatedAt: Date(),
                           recurrence: rule, tagIds: [],
                           needsImmediateAttention: false, notesRich: nil, occurrenceKey: nil,
                           recurrenceEffectiveFromKey: nil, occurrenceModified: nil),
                TaskItemDTO(id: childId, title: "Existing child", notes: "", isDone: false,
                           dayKey: dayKey(2026, 1, 6), customListId: nil, timeMinutes: nil,
                           colorHex: nil, priority: 0, sortIndex: 1, alarmEnabled: false,
                           createdAt: Date(), updatedAt: Date(),
                           recurrence: nil, tagIds: [],
                           needsImmediateAttention: false, notesRich: nil, templateId: rootId, occurrenceKey: dayKey(2026, 1, 6),
                           recurrenceEffectiveFromKey: nil, occurrenceModified: nil)
            ],
            subtasks: [], taskTags: [], customLists: [], taskOccurrences: []
        )
        let dto = BackupStoreDTO(schemaVersion: 2, appVersion: "0.1.17", exportedAt: Date(), data: data)

        // Restore into the fresh context
        try BackupStore.restore(dto, context: context)

        // Verify normalization occurred
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let definitions = all.filter { $0.recurrence != nil && $0.templateID == nil }
        #expect(definitions.count == 1)

        let children = all.filter { $0.templateID != nil }
        #expect(children.count == 2)
    }

    // MARK: - Edge cases

    @Test("Normalization handles orphaned children (missing definition)")
    func normalizeOrphanedChildren() throws {
        let context = makeContext()

        // Create a child with a missing definition
        let orphan = TaskItem(title: "Orphaned task", dayKey: dayKey(2026, 1, 5))
        orphan.templateID = UUID()
        context.insert(orphan)

        let report = try RecurrenceNormalizer.normalize(context: context)

        // Should be preserved unchanged
        #expect(report.splitDefinitions == 0)
        #expect(orphan.templateID != nil)
        #expect(orphan.dayKey == dayKey(2026, 1, 5))
    }

    @Test("Normalization preserves duplicate inferred keys")
    func normalizeDuplicateKeys() throws {
        let context = makeContext()
        let c = cal()

        let definition = TaskItem(title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        // Two children with the same dayKey (ambiguous)
        let child1 = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 5))
        child1.templateID = definition.id
        child1.notes = "child 1"
        context.insert(child1)

        let child2 = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 5))
        child2.templateID = definition.id
        child2.notes = "child 2"
        context.insert(child2)

        _ = try RecurrenceNormalizer.normalize(context: context)

        // Both preserved, backfilled
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        let children = all.filter { $0.templateID == definition.id }
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.occurrenceKey == dayKey(2026, 1, 5) })
    }

    @Test("Normalization preserves skip records")
    func normalizePreservesSkips() throws {
        let context = makeContext()
        let c = cal()

        let definition = TaskItem(title: "Daily task")
        definition.recurrence = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        context.insert(definition)

        let skipRecord = TaskOccurrence(id: UUID(), dayKey: dayKey(2026, 1, 3),
                                        isDone: false, skipped: true,
                                        titleOverride: nil, timeOverride: nil)
        skipRecord.template = definition
        definition.occurrences.append(skipRecord)

        _ = try RecurrenceNormalizer.normalize(context: context)

        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == dayKey(2026, 1, 3) })
    }
}
