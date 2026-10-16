import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Tests for day key validation in WeekMath and BackupValidator. Ensures that
/// invalid civil dates and malformed keys are rejected, and that imports of
/// backups with such keys fail atomically without corrupting the store.
@MainActor
@Suite("Day key validation", .serialized)
struct DayKeyValidationTests {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func makeInMemoryContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    /// A context on an on-disk store inside the test's temporary folder `dir`.
    private func makeContext(at dir: URL) throws -> ModelContext {
        ModelContext(try ModelContainerProvider.makeContainer(at: dir.appendingPathComponent("TickyTask.store")))
    }

    // MARK: - WeekMath.date(fromDayKey:) validation

    @Test("WeekMath rejects non-leap February 29")
    func rejectNonLeapFebruary29() {
        let c = cal()
        // 2026 is not a leap year
        #expect(WeekMath.date(fromDayKey: "20260229", calendar: c) == nil)
        // 2000 is a leap year
        #expect(WeekMath.date(fromDayKey: "20000229", calendar: c) != nil)
        // 2100 is not a leap year (divisible by 100 but not 400)
        #expect(WeekMath.date(fromDayKey: "21000229", calendar: c) == nil)
        // 2400 is a leap year (divisible by 400)
        #expect(WeekMath.date(fromDayKey: "24000229", calendar: c) != nil)
    }

    @Test("WeekMath rejects February 31")
    func rejectFebruary31() {
        let c = cal()
        #expect(WeekMath.date(fromDayKey: "20260231", calendar: c) == nil)
        #expect(WeekMath.date(fromDayKey: "20000231", calendar: c) == nil)
    }

    @Test("WeekMath rejects April 31 and similar")
    func rejectInvalidDaysOfMonth() {
        let c = cal()
        #expect(WeekMath.date(fromDayKey: "20260431", calendar: c) == nil)  // April 31
        #expect(WeekMath.date(fromDayKey: "20260631", calendar: c) == nil)  // June 31
        #expect(WeekMath.date(fromDayKey: "20260931", calendar: c) == nil)  // September 31
        #expect(WeekMath.date(fromDayKey: "20261131", calendar: c) == nil)  // November 31
    }

    @Test("WeekMath rejects month 13 and beyond")
    func rejectInvalidMonths() {
        let c = cal()
        #expect(WeekMath.date(fromDayKey: "20261301", calendar: c) == nil)
        #expect(WeekMath.date(fromDayKey: "20261401", calendar: c) == nil)
        #expect(WeekMath.date(fromDayKey: "20269901", calendar: c) == nil)
    }

    @Test("WeekMath rejects month 00 and day 00")
    func rejectZeroComponents() {
        let c = cal()
        #expect(WeekMath.date(fromDayKey: "20260001", calendar: c) == nil)  // Month 00
        #expect(WeekMath.date(fromDayKey: "20260100", calendar: c) == nil)  // Day 00
        #expect(WeekMath.date(fromDayKey: "20260000", calendar: c) == nil)  // Both
    }

    @Test("WeekMath rejects malformed keys")
    func rejectMalformedKeys() {
        let c = cal()
        // Too short
        #expect(WeekMath.date(fromDayKey: "2026021", calendar: c) == nil)
        // Non-ASCII digits (full-width)
        #expect(WeekMath.date(fromDayKey: "２０２６０１０１", calendar: c) == nil)
        // Non-numeric
        #expect(WeekMath.date(fromDayKey: "2026-01-01", calendar: c) == nil)
        #expect(WeekMath.date(fromDayKey: "2026/1/1", calendar: c) == nil)
        #expect(WeekMath.date(fromDayKey: "Jan12026", calendar: c) == nil)
        // Too long
        #expect(WeekMath.date(fromDayKey: "202601010", calendar: c) == nil)
        // Empty
        #expect(WeekMath.date(fromDayKey: "", calendar: c) == nil)
    }

    @Test("WeekMath accepts valid leap February 29")
    func acceptLeapFebruary29() {
        let c = cal()
        #expect(WeekMath.date(fromDayKey: "20000229", calendar: c) != nil)
        #expect(WeekMath.date(fromDayKey: "20040229", calendar: c) != nil)
        #expect(WeekMath.date(fromDayKey: "20240229", calendar: c) != nil)
    }

    @Test("WeekMath accepts valid December 31")
    func acceptDecember31() {
        let c = cal()
        #expect(WeekMath.date(fromDayKey: "20261231", calendar: c) != nil)
        #expect(WeekMath.date(fromDayKey: "20250131", calendar: c) != nil)
    }

    // MARK: - BackupValidator rejection of invalid keys

    @Test("BackupValidator rejects backup with invalid occurrenceKey")
    func backupValidatorRejectsInvalidOccurrenceKey() {
        let c = cal()

        let invalidTask = TaskItemDTO(
            id: UUID(), title: "Task", notes: "", isDone: false, dayKey: "20260101",
            customListId: nil, timeMinutes: nil, colorHex: nil, priority: 0, sortIndex: 0,
            alarmEnabled: false, createdAt: Date(), updatedAt: Date(),
            recurrence: nil, tagIds: [], needsImmediateAttention: false, completedAt: nil,
            notesRich: nil, templateId: UUID(), occurrenceKey: "20260231",  // Invalid: Feb 31
            recurrenceEffectiveFromKey: nil, occurrenceModified: nil
        )

        let backupStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [invalidTask], subtasks: [], taskTags: [],
                              customLists: [], taskOccurrences: []).deterministicallySorted(),
            settings: nil
        )

        do {
            try BackupValidator.validate(backupStore)
            #expect(Bool(false), "Should have thrown BackupError")
        } catch is BackupError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test("BackupValidator rejects backup with invalid recurrenceEffectiveFromKey")
    func backupValidatorRejectsInvalidRecurrenceEffectiveFromKey() {
        let c = cal()

        let definition = TaskItemDTO(
            id: UUID(), title: "Series", notes: "", isDone: false, dayKey: nil,
            customListId: nil, timeMinutes: nil, colorHex: nil, priority: 0, sortIndex: 0,
            alarmEnabled: false, createdAt: Date(), updatedAt: Date(),
            recurrence: RecurrenceRule(frequency: .daily, startDate: Date(), end: .never),
            tagIds: [], needsImmediateAttention: false, completedAt: nil, notesRich: nil,
            templateId: nil, occurrenceKey: nil, recurrenceEffectiveFromKey: "20261301",  // Invalid: month 13
            occurrenceModified: nil
        )

        let backupStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [definition], subtasks: [], taskTags: [],
                              customLists: [], taskOccurrences: []).deterministicallySorted(),
            settings: nil
        )

        do {
            try BackupValidator.validate(backupStore)
            #expect(Bool(false), "Should have thrown BackupError")
        } catch is BackupError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test("BackupValidator rejects task with both recurrence and templateId")
    func backupValidatorRejectsHybridRow() {
        let templateId = UUID()

        let hybrid = TaskItemDTO(
            id: UUID(), title: "Hybrid", notes: "", isDone: false, dayKey: "20260101",
            customListId: nil, timeMinutes: nil, colorHex: nil, priority: 0, sortIndex: 0,
            alarmEnabled: false, createdAt: Date(), updatedAt: Date(),
            recurrence: RecurrenceRule(frequency: .daily, startDate: Date(), end: .never),
            tagIds: [], needsImmediateAttention: false, completedAt: nil, notesRich: nil,
            templateId: templateId, occurrenceKey: nil, recurrenceEffectiveFromKey: nil,
            occurrenceModified: nil
        )

        let backupStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [hybrid], subtasks: [], taskTags: [],
                              customLists: [], taskOccurrences: []).deterministicallySorted(),
            settings: nil
        )

        do {
            try BackupValidator.validate(backupStore)
            #expect(Bool(false), "Should have thrown BackupError")
        } catch is BackupError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test("BackupValidator rejects templateId pointing to hybrid row")
    func backupValidatorRejectsTemplateLinkingHybrid() {
        let templateId = UUID()

        let hybrid = TaskItemDTO(
            id: templateId, title: "Hybrid", notes: "", isDone: false, dayKey: "20260101",
            customListId: nil, timeMinutes: nil, colorHex: nil, priority: 0, sortIndex: 0,
            alarmEnabled: false, createdAt: Date(), updatedAt: Date(),
            recurrence: RecurrenceRule(frequency: .daily, startDate: Date(), end: .never),
            tagIds: [], needsImmediateAttention: false, completedAt: nil, notesRich: nil,
            templateId: nil, occurrenceKey: nil, recurrenceEffectiveFromKey: nil,
            occurrenceModified: nil
        )

        let occurrence = TaskItemDTO(
            id: UUID(), title: "Occurrence", notes: "", isDone: false, dayKey: "20260102",
            customListId: nil, timeMinutes: nil, colorHex: nil, priority: 0, sortIndex: 0,
            alarmEnabled: false, createdAt: Date(), updatedAt: Date(),
            recurrence: nil, tagIds: [], needsImmediateAttention: false, completedAt: nil,
            notesRich: nil, templateId: templateId, occurrenceKey: nil,
            recurrenceEffectiveFromKey: nil, occurrenceModified: nil
        )

        let backupStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [hybrid, occurrence], subtasks: [], taskTags: [],
                              customLists: [], taskOccurrences: []).deterministicallySorted(),
            settings: nil
        )

        do {
            try BackupValidator.validate(backupStore)
            #expect(Bool(false), "Should have thrown BackupError")
        } catch is BackupError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test("BackupValidator accepts orphan templateId (missing target)")
    func backupValidatorAcceptsOrphanTemplateId() throws {
        let missingTemplateId = UUID()

        let orphan = TaskItemDTO(
            id: UUID(), title: "Orphan", notes: "", isDone: false, dayKey: "20260101",
            customListId: nil, timeMinutes: nil, colorHex: nil, priority: 0, sortIndex: 0,
            alarmEnabled: false, createdAt: Date(), updatedAt: Date(),
            recurrence: nil, tagIds: [], needsImmediateAttention: false, completedAt: nil,
            notesRich: nil, templateId: missingTemplateId, occurrenceKey: nil,
            recurrenceEffectiveFromKey: nil, occurrenceModified: nil
        )

        let backupStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [orphan], subtasks: [], taskTags: [],
                              customLists: [], taskOccurrences: []).deterministicallySorted(),
            settings: nil
        )

        // Should not throw
        try BackupValidator.validate(backupStore)
    }

    // MARK: - Restore atomicity with invalid keys

    @Test("Restore of backup with invalid occurrenceKey fails and leaves store unchanged")
    func restoreInvalidOccurrenceKeyAtomic() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try makeContext(at: tempDir)

        // Create an existing task in the store.
        let existing = TaskItem(title: "Existing", dayKey: "20260101")
        context.insert(existing)
        try context.save()

        // Capture the store state before attempting restore.
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let beforeCount = tasks.count
        let beforeTitle = tasks.first?.title

        // Create a backup with an invalid occurrenceKey.
        let invalidTask = TaskItemDTO(
            id: UUID(), title: "Invalid", notes: "", isDone: false, dayKey: "20260102",
            customListId: nil, timeMinutes: nil, colorHex: nil, priority: 0, sortIndex: 0,
            alarmEnabled: false, createdAt: Date(), updatedAt: Date(),
            recurrence: nil, tagIds: [], needsImmediateAttention: false, completedAt: nil,
            notesRich: nil, templateId: UUID(), occurrenceKey: "20260229",  // Non-leap February 29
            recurrenceEffectiveFromKey: nil, occurrenceModified: nil
        )

        let backupStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [invalidTask], subtasks: [], taskTags: [],
                              customLists: [], taskOccurrences: []).deterministicallySorted(),
            settings: nil
        )

        // Attempt restore and verify it fails.
        do {
            try BackupStore.restore(backupStore, context: context)
            #expect(Bool(false), "Should have thrown BackupError")
        } catch is BackupError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }

        // Verify the store is unchanged.
        let afterTasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(afterTasks.count == beforeCount)
        #expect(afterTasks.first?.title == beforeTitle)
    }

    @Test("Restore of backup with invalid recurrenceEffectiveFromKey fails and leaves store unchanged")
    func restoreInvalidRecurrenceEffectiveFromKeyAtomic() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try makeContext(at: tempDir)

        // Create an existing task in the store.
        let existing = TaskItem(title: "Existing", dayKey: "20260101")
        context.insert(existing)
        try context.save()

        // Capture the store state.
        let beforeTasks = try context.fetch(FetchDescriptor<TaskItem>()).map(\.title)

        // Create a backup with an invalid recurrenceEffectiveFromKey.
        let invalidDefinition = TaskItemDTO(
            id: UUID(), title: "Invalid Series", notes: "", isDone: false, dayKey: nil,
            customListId: nil, timeMinutes: nil, colorHex: nil, priority: 0, sortIndex: 0,
            alarmEnabled: false, createdAt: Date(), updatedAt: Date(),
            recurrence: RecurrenceRule(frequency: .daily, startDate: Date(), end: .never),
            tagIds: [], needsImmediateAttention: false, completedAt: nil, notesRich: nil,
            templateId: nil, occurrenceKey: nil, recurrenceEffectiveFromKey: "20261301",  // Invalid: month 13
            occurrenceModified: nil
        )

        let backupStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [invalidDefinition], subtasks: [], taskTags: [],
                              customLists: [], taskOccurrences: []).deterministicallySorted(),
            settings: nil
        )

        // Attempt restore.
        do {
            try BackupStore.restore(backupStore, context: context)
            #expect(Bool(false), "Should have thrown BackupError")
        } catch is BackupError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }

        // Verify the store is unchanged.
        let afterTasks = try context.fetch(FetchDescriptor<TaskItem>()).map(\.title)
        #expect(Set(afterTasks) == Set(beforeTasks))
    }

    @Test("Restore of backup with both recurrence and templateId fails and leaves store unchanged")
    func restoreHybridRowAtomic() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try makeContext(at: tempDir)

        // Create an existing task.
        let existing = TaskItem(title: "Existing", dayKey: "20260101")
        context.insert(existing)
        try context.save()

        let beforeTasks = try context.fetch(FetchDescriptor<TaskItem>()).map(\.title)

        // Create a backup with a hybrid row (both recurrence and templateId).
        let templateId = UUID()
        let hybrid = TaskItemDTO(
            id: UUID(), title: "Hybrid", notes: "", isDone: false, dayKey: "20260101",
            customListId: nil, timeMinutes: nil, colorHex: nil, priority: 0, sortIndex: 0,
            alarmEnabled: false, createdAt: Date(), updatedAt: Date(),
            recurrence: RecurrenceRule(frequency: .daily, startDate: Date(), end: .never),
            tagIds: [], needsImmediateAttention: false, completedAt: nil, notesRich: nil,
            templateId: templateId, occurrenceKey: nil, recurrenceEffectiveFromKey: nil,
            occurrenceModified: nil
        )

        let backupStore = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [hybrid], subtasks: [], taskTags: [],
                              customLists: [], taskOccurrences: []).deterministicallySorted(),
            settings: nil
        )

        // Attempt restore.
        do {
            try BackupStore.restore(backupStore, context: context)
            #expect(Bool(false), "Should have thrown BackupError")
        } catch is BackupError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }

        // Verify the store is unchanged.
        let afterTasks = try context.fetch(FetchDescriptor<TaskItem>()).map(\.title)
        #expect(Set(afterTasks) == Set(beforeTasks))
    }
}

