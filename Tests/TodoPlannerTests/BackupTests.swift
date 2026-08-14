import Testing
import Foundation
import SwiftData
@testable import TodoPlanner

@Suite("Backup export/import")
struct BackupTests {
    private let service = BackupService()
    private let passphrase = "correct horse battery staple"

    // A fixture exercising every field: a recurring day-task with notes, time,
    // color, alarm, a tag, a subtask, and an occurrence override, plus a
    // completed custom-list task. All timestamps are whole seconds so ISO-8601
    // round-trips exactly.
    private func makeFixture(schemaVersion: Int = BackupStoreDTO.currentSchemaVersion) -> BackupStoreDTO {
        let listId = UUID(), tagId = UUID(), dayTaskId = UUID(), listTaskId = UUID()
        let subId = UUID(), occId = UUID()
        let day = WeekMath.dayKey(for: Date())
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let recurrence = RecurrenceRule(
            frequency: .customWeekdays, interval: 2, weekdays: [2, 4, 6],
            monthDays: [], end: .afterCount(10), startDate: t0
        )

        let data = BackupDataDTO(
            taskItems: [
                TaskItemDTO(id: dayTaskId, title: "Review PR", notes: "**bold** notes",
                            isDone: false, dayKey: day, customListId: nil, timeMinutes: 600,
                            colorHex: "#ff0000", priority: 3, sortIndex: 1, alarmEnabled: true,
                            createdAt: t0, updatedAt: t0.addingTimeInterval(100),
                            recurrence: recurrence, tagIds: [tagId]),
                TaskItemDTO(id: listTaskId, title: "Buy milk", notes: "", isDone: true,
                            dayKey: nil, customListId: listId, timeMinutes: nil, colorHex: nil,
                            priority: 0, sortIndex: 2, alarmEnabled: false,
                            createdAt: t0.addingTimeInterval(200), updatedAt: t0.addingTimeInterval(300),
                            recurrence: nil, tagIds: [])
            ],
            subtasks: [SubtaskDTO(id: subId, title: "Read the doc", isDone: false, sortIndex: 1, parentId: dayTaskId)],
            taskTags: [TaskTagDTO(id: tagId, name: "work", colorHex: "#0000ff")],
            customLists: [CustomListDTO(id: listId, name: "Groceries", sortIndex: 1)],
            taskOccurrences: [TaskOccurrenceDTO(id: occId, dayKey: day, isDone: true, skipped: false,
                                                titleOverride: "Review PR (today)", timeOverride: 540,
                                                templateId: dayTaskId)]
        )
        return BackupStoreDTO(schemaVersion: schemaVersion, appVersion: "1.0",
                              exportedAt: t0.addingTimeInterval(400), data: data)
    }

    private func emptyStore() -> BackupStoreDTO {
        BackupStoreDTO(schemaVersion: 1, appVersion: "1.0",
                       exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                       data: BackupDataDTO(taskItems: [], subtasks: [], taskTags: [],
                                           customLists: [], taskOccurrences: []))
    }

    // MARK: Pure codec

    @Test("Plaintext round-trip preserves every field")
    func plaintextRoundTrip() throws {
        let fixture = makeFixture()
        let data = try service.makeFile(store: fixture, passphrase: nil)
        #expect(service.isEncrypted(data) == false)
        #expect(try service.readFile(data, passphrase: nil) == fixture)
    }

    @Test("Plaintext backup is human-readable JSON (not base64)")
    func plaintextIsReadable() throws {
        let data = try service.makeFile(store: makeFixture(), passphrase: nil)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"Review PR\""))
        #expect(text.contains("\"Groceries\""))
    }

    @Test("Encrypted round-trip preserves every field")
    func encryptedRoundTrip() throws {
        let fixture = makeFixture()
        let data = try service.makeFile(store: fixture, passphrase: passphrase)
        #expect(service.isEncrypted(data) == true)
        // The plaintext title must not appear in an encrypted file.
        #expect(!String(decoding: data, as: UTF8.self).contains("Review PR"))
        #expect(try service.readFile(data, passphrase: passphrase) == fixture)
    }

    @Test("Empty store round-trips")
    func emptyRoundTrip() throws {
        let store = emptyStore()
        #expect(try service.readFile(service.makeFile(store: store, passphrase: nil), passphrase: nil) == store)
    }

    @Test("Wrong passphrase is rejected")
    func wrongPassphrase() throws {
        let data = try service.makeFile(store: makeFixture(), passphrase: passphrase)
        #expect(throws: BackupError.wrongPassphrase) {
            try service.readFile(data, passphrase: "totally the wrong one")
        }
    }

    @Test("Encrypted file with no passphrase is rejected")
    func missingPassphrase() throws {
        let data = try service.makeFile(store: makeFixture(), passphrase: passphrase)
        #expect(throws: BackupError.missingPassphrase) {
            try service.readFile(data, passphrase: nil)
        }
    }

    @Test("Tampered ciphertext fails authentication")
    func tamperDetection() throws {
        let data = try service.makeFile(store: makeFixture(), passphrase: passphrase)
        var file = try BackupCoding.decoder().decode(BackupFile.self, from: data)
        file.crypto!.ciphertext[0] ^= 0xFF
        let tampered = try BackupCoding.encoder().encode(file)
        // Can't distinguish tamper from wrong key cryptographically — assert it
        // throws, not the specific case.
        #expect(throws: BackupError.self) { try service.readFile(tampered, passphrase: passphrase) }
    }

    @Test("A newer schema version is rejected")
    func newerSchemaRejected() throws {
        let data = try service.makeFile(store: makeFixture(schemaVersion: 999), passphrase: nil)
        #expect(throws: BackupError.unsupportedSchema(found: 999, supported: BackupStoreDTO.currentSchemaVersion)) {
            try service.readFile(data, passphrase: nil)
        }
    }

    @Test("Short passphrase is rejected on export")
    func shortPassphraseRejected() {
        #expect(throws: BackupError.self) {
            try service.makeFile(store: makeFixture(), passphrase: "short")
        }
    }

    @Test("Garbage bytes are reported as corrupt")
    func corruptRejected() {
        #expect(throws: BackupError.corruptPayload) {
            try service.readFile(Data("not a backup".utf8), passphrase: nil)
        }
    }

    // MARK: Validator

    @Test("A dangling relationship reference is rejected")
    func danglingReferenceRejected() {
        var store = makeFixture()
        store.data.subtasks = [SubtaskDTO(id: UUID(), title: "orphan", isDone: false, sortIndex: 1, parentId: UUID())]
        #expect(throws: BackupError.self) { try BackupValidator.validate(store) }
    }

    @Test("A task on both a day and a list is rejected")
    func dayAndListRejected() {
        var store = makeFixture()
        let listId = store.data.customLists[0].id
        store.data.taskItems[0].customListId = listId  // already has a dayKey
        #expect(throws: BackupError.self) { try BackupValidator.validate(store) }
    }

    @Test("A malicious iteration count is rejected, not executed")
    func maliciousIterationsRejected() throws {
        let data = try service.makeFile(store: makeFixture(), passphrase: passphrase)
        var file = try BackupCoding.decoder().decode(BackupFile.self, from: data)

        file.crypto!.iterations = -1   // would trap UInt32(...) without the guard
        let negative = try BackupCoding.encoder().encode(file)
        #expect(throws: BackupError.corruptPayload) { try service.readFile(negative, passphrase: passphrase) }

        file.crypto!.iterations = Int.max   // CPU denial-of-service without the cap
        let huge = try BackupCoding.encoder().encode(file)
        #expect(throws: BackupError.corruptPayload) { try service.readFile(huge, passphrase: passphrase) }
    }

    @Test("Fractional-second timestamps round-trip losslessly")
    func fractionalDateRoundTrip() throws {
        let precise = Date(timeIntervalSince1970: 1_700_000_000.5)
        var store = makeFixture()
        store.exportedAt = precise
        store.data.taskItems[0].createdAt = precise
        store.data.taskItems[0].updatedAt = precise
        store.data.taskItems[0].recurrence = RecurrenceRule(
            frequency: .weekly, interval: 1, weekdays: [2], monthDays: [],
            end: .until(precise), startDate: precise
        )
        let decoded = try service.readFile(try service.makeFile(store: store, passphrase: nil), passphrase: nil)
        #expect(decoded == store)
        #expect(decoded.data.taskItems[0].createdAt == precise)
    }

    @Test("An out-of-range occurrence time override is rejected")
    func occurrenceTimeOverrideRejected() {
        var store = makeFixture()
        store.data.taskOccurrences[0].timeOverride = 5000
        #expect(throws: BackupError.self) { try BackupValidator.validate(store) }
    }

    @Test("Duplicate tag ids on a task are rejected")
    func duplicateTagsRejected() {
        var store = makeFixture()
        let tagId = store.data.taskTags[0].id
        store.data.taskItems[0].tagIds = [tagId, tagId]
        #expect(throws: BackupError.self) { try BackupValidator.validate(store) }
    }

    @Test("A non-positive recurrence count is rejected")
    func nonPositiveRecurrenceCountRejected() {
        var store = makeFixture()
        store.data.taskItems[0].recurrence = RecurrenceRule(
            frequency: .daily, interval: 1, weekdays: [], monthDays: [],
            end: .afterCount(0), startDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(throws: BackupError.self) { try BackupValidator.validate(store) }
    }

    @Test("Custom-weekday recurrence with no weekdays is rejected")
    func emptyCustomWeekdaysRejected() {
        var store = makeFixture()
        store.data.taskItems[0].recurrence = RecurrenceRule(
            frequency: .customWeekdays, interval: 1, weekdays: [], monthDays: [],
            end: .never, startDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(throws: BackupError.self) { try BackupValidator.validate(store) }
    }

    @Test("Days-of-month recurrence with no days is rejected")
    func emptyDaysOfMonthRejected() {
        var store = makeFixture()
        store.data.taskItems[0].recurrence = RecurrenceRule(
            frequency: .daysOfMonth, interval: 1, weekdays: [], monthDays: [],
            end: .never, startDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(throws: BackupError.self) { try BackupValidator.validate(store) }
    }

    @Test("Two occurrences for the same template+day are rejected")
    func duplicateOccurrenceRejected() {
        var store = makeFixture()
        let existing = store.data.taskOccurrences[0]
        store.data.taskOccurrences.append(
            TaskOccurrenceDTO(id: UUID(), dayKey: existing.dayKey, isDone: false, skipped: false,
                              titleOverride: nil, timeOverride: nil, templateId: existing.templateId)
        )
        #expect(throws: BackupError.self) { try BackupValidator.validate(store) }
    }

    @Test("Decoder accepts both whole-second and fractional ISO-8601 dates")
    func decoderAcceptsBothDateForms() throws {
        struct Wrap: Codable { let d: Date }
        let decoder = BackupCoding.decoder()
        let whole = try decoder.decode(Wrap.self, from: Data(#"{"d":"2023-11-14T22:13:20Z"}"#.utf8))
        let fractional = try decoder.decode(Wrap.self, from: Data(#"{"d":"2023-11-14T22:13:20.500Z"}"#.utf8))
        #expect(whole.d == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(fractional.d == Date(timeIntervalSince1970: 1_700_000_000.5))
    }

    @Test("Import size limit fails closed on unknown size")
    func sizeLimitFailsClosed() {
        #expect(BackupCoordinator.exceedsSizeLimit(nil) == true)                 // metadata failure → refuse
        #expect(BackupCoordinator.exceedsSizeLimit(BackupCoordinator.maxImportBytes + 1) == true)
        #expect(BackupCoordinator.exceedsSizeLimit(1_024) == false)
    }
}

@MainActor
@Suite("Backup restore")
struct BackupRestoreTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    private func fixture() -> BackupStoreDTO { BackupTests().makeFixtureForRestore() }

    @Test("Restore replaces the store and rebuilds every relationship")
    func restoreRebuildsGraph() throws {
        let context = makeContext()
        let stale = TaskItem(title: "stale", dayKey: WeekMath.dayKey(for: Date()))
        context.insert(stale)
        try context.save()

        try BackupStore.restore(fixture(), context: context)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 2)
        #expect(!tasks.contains { $0.title == "stale" })

        let dayTask = try #require(tasks.first { $0.dayKey != nil })
        #expect(dayTask.tags.count == 1)
        #expect(dayTask.tags.first?.name == "work")
        #expect(dayTask.subtasks.count == 1)
        #expect(dayTask.occurrences.count == 1)
        #expect(dayTask.recurrence?.frequency == .customWeekdays)

        let listTask = try #require(tasks.first { $0.customList != nil })
        #expect(listTask.customList?.name == "Groceries")
        #expect(listTask.isDone == true)

        #expect(try context.fetch(FetchDescriptor<CustomList>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<TaskTag>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Subtask>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<TaskOccurrence>()).count == 1)
    }

    @Test("An invalid backup throws and leaves the existing store intact")
    func invalidBackupIsAtomic() throws {
        let context = makeContext()
        let keep = TaskItem(title: "keep me", dayKey: WeekMath.dayKey(for: Date()))
        context.insert(keep)
        try context.save()

        var bad = fixture()
        bad.data.subtasks = [SubtaskDTO(id: UUID(), title: "orphan", isDone: false, sortIndex: 1, parentId: UUID())]

        #expect(throws: BackupError.self) { try BackupStore.restore(bad, context: context) }

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.contains { $0.title == "keep me" })
    }

    @Test("Round-trip through live models via snapshot + restore is lossless")
    func modelRoundTrip() throws {
        let context = makeContext()
        try BackupStore.restore(fixture(), context: context)

        let snapshot = try BackupStore.makeSnapshot(context: context)
        let data = try BackupService().makeFile(store: snapshot, passphrase: nil)
        let decoded = try BackupService().readFile(data, passphrase: nil)
        #expect(decoded.data == snapshot.data)
    }

    @Test("Diff preview counts adds and removes")
    func diffPreview() throws {
        let context = makeContext()
        let stale = TaskItem(title: "stale", dayKey: WeekMath.dayKey(for: Date()))
        context.insert(stale)
        try context.save()

        let diff = try BackupStore.preview(fixture(), context: context)
        #expect(diff.taskItems.added == 2)
        #expect(diff.taskItems.removed == 1)
        #expect(diff.customLists.added == 1)
    }
}

// Expose the fixture builder to the restore suite without duplicating it.
extension BackupTests {
    func makeFixtureForRestore() -> BackupStoreDTO { makeFixture() }
}
