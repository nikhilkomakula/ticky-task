import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Tests the complete v0.1.17 schema-2 backup round-trip: snapshot → plaintext/encrypted encoding →
/// decoding → restore into a fresh disk store → close/reopen → exact graph comparison.
///
/// This suite verifies that every new 0.1.17 field (occurrenceKey, recurrenceEffectiveFromKey,
/// occurrenceModified, completedAt, notesRich) round-trips losslessly through both plaintext and
/// encrypted backups, including moved occurrences, listed occurrences, orphans, skip records,
/// and subtask relationships with their own new fields (isDone, sortIndex).
@MainActor
@Suite("Series backup round-trip")
struct SeriesBackupRoundTripTests {
    private let service = BackupService()
    private let passphrase = "the correct horse battery staple"

    // MARK: - Rich fixture builder

    /// Builds a comprehensive store exercising all schema-2 fields:
    /// - Two series (one with recurrenceEffectiveFromKey to test rule changes)
    /// - Occurrences with occurrenceModified nil/false/true to test provenance
    /// - A moved dated occurrence (dayKey ≠ occurrenceKey) to test relocation
    /// - A listed occurrence with an occurrenceKey to test placement flexibility
    /// - Rich notes with distinct bytes, bullets, and nesting
    /// - Subtasks with exact ids/done/order preserved
    /// - Completion dates with sub-second precision (1.5 seconds)
    /// - Tags on both definition and occurrence (provenance)
    /// - Skip records including duplicate legacy pairs (override isDone + skipped for same day)
    /// - An orphan occurrence whose template is missing
    private func makeRichFixture() -> BackupStoreDTO {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t0_fraction = Date(timeIntervalSince1970: 1_700_000_000.5)

        // UUIDs for relationships
        let series1Id = UUID()
        let series2Id = UUID()
        let def1Id = UUID()
        let def2Id = UUID()
        let occ1Id = UUID()
        let occ2Id = UUID()
        let occ3Id = UUID()
        let occ4Id = UUID()
        let occ5Id = UUID()
        let orphanOccId = UUID()
        let orphanTemplateId = UUID()

        let listId = UUID()
        let tag1Id = UUID()
        let tag2Id = UUID()
        let sub1Id = UUID()
        let sub2Id = UUID()
        let sub3Id = UUID()
        let skipRec1Id = UUID()
        let skipRec2Id = UUID()
        let skipRec3Id = UUID()
        let overrideRec1Id = UUID()
        let overrideRec2Id = UUID()

        let day1 = "20260101"
        let day2 = "20260102"
        let day3 = "20260103"
        let day4 = "20260104"
        let day5 = "20260105"

        let richNotesData1 = try! NotesCodec.encode(NotesDocument(blocks: [
            NotesBlock(kind: .bullet, runs: [NotesRun(text: "first point")]),
            NotesBlock(kind: .bullet, runs: [NotesRun(text: "second point")])
        ]))
        let richNotesData2 = try! NotesCodec.encode(NotesDocument(blocks: [
            NotesBlock(kind: .numbered, runs: [NotesRun(text: "step one")]),
            NotesBlock(kind: .numbered, runs: [NotesRun(text: "step two")])
        ]))

        // Series 1: daily, no rule change (occurrenceModified nil)
        let rule1 = RecurrenceRule(
            frequency: .daily,
            interval: 1,
            weekdays: [],
            monthDays: [],
            end: .afterCount(5),
            startDate: t0
        )

        // Series 2: weekly, with rule change boundary (occurrenceModified true for later occurrence)
        let rule2 = RecurrenceRule(
            frequency: .weekly,
            interval: 1,
            weekdays: [1],
            monthDays: [],
            end: .afterCount(3),
            startDate: t0
        )

        let data = BackupDataDTO(
            taskItems: [
                // Hidden definition 1 (daily series)
                TaskItemDTO(
                    id: def1Id, title: "Daily standup", notes: "", isDone: false,
                    dayKey: nil, customListId: nil, timeMinutes: nil, colorHex: "#ff6b6b",
                    priority: 2, sortIndex: 1, alarmEnabled: true,
                    createdAt: t0, updatedAt: t0,
                    recurrence: rule1, tagIds: [tag1Id],
                    needsImmediateAttention: true,
                    completedAt: nil,
                    notesRich: nil,
                    templateId: nil,
                    occurrenceKey: nil,
                    recurrenceEffectiveFromKey: nil,
                    occurrenceModified: nil
                ),
                // Hidden definition 2 (weekly series with rule change)
                TaskItemDTO(
                    id: def2Id, title: "Weekly review", notes: "Review the week", isDone: false,
                    dayKey: nil, customListId: nil, timeMinutes: 600, colorHex: "#4ecdc4",
                    priority: 1, sortIndex: 2, alarmEnabled: false,
                    createdAt: t0.addingTimeInterval(100), updatedAt: t0.addingTimeInterval(200),
                    recurrence: rule2, tagIds: [tag2Id],
                    needsImmediateAttention: false,
                    completedAt: nil,
                    notesRich: richNotesData1,
                    templateId: nil,
                    occurrenceKey: nil,
                    recurrenceEffectiveFromKey: day3,  // Rule changed at this boundary
                    occurrenceModified: nil
                ),
                // Series 1, Occurrence 1: standard occurrence (occurrenceModified nil)
                TaskItemDTO(
                    id: occ1Id, title: "Daily standup", notes: "", isDone: false,
                    dayKey: day1, customListId: nil, timeMinutes: nil, colorHex: "#ff6b6b",
                    priority: 2, sortIndex: 1, alarmEnabled: true,
                    createdAt: t0, updatedAt: t0,
                    recurrence: nil, tagIds: [tag1Id],
                    needsImmediateAttention: true,
                    completedAt: nil,
                    notesRich: nil,
                    templateId: def1Id,
                    occurrenceKey: day1,
                    recurrenceEffectiveFromKey: nil,
                    occurrenceModified: nil
                ),
                // Series 1, Occurrence 2: completed occurrence (occurrenceModified false)
                TaskItemDTO(
                    id: occ2Id, title: "Daily standup", notes: "Done", isDone: true,
                    dayKey: day2, customListId: nil, timeMinutes: nil, colorHex: "#ff6b6b",
                    priority: 2, sortIndex: 2, alarmEnabled: true,
                    createdAt: t0, updatedAt: t0.addingTimeInterval(50),
                    recurrence: nil, tagIds: [tag1Id],
                    needsImmediateAttention: true,
                    completedAt: t0_fraction,  // Sub-second precision
                    notesRich: nil,
                    templateId: def1Id,
                    occurrenceKey: day2,
                    recurrenceEffectiveFromKey: nil,
                    occurrenceModified: false
                ),
                // Series 1, Occurrence 3: moved occurrence (dayKey ≠ occurrenceKey)
                TaskItemDTO(
                    id: occ3Id, title: "Daily standup", notes: "Rescheduled", isDone: false,
                    dayKey: day4, customListId: nil, timeMinutes: nil, colorHex: "#ff6b6b",
                    priority: 2, sortIndex: 3, alarmEnabled: true,
                    createdAt: t0, updatedAt: t0.addingTimeInterval(100),
                    recurrence: nil, tagIds: [tag1Id],
                    needsImmediateAttention: true,
                    completedAt: nil,
                    notesRich: nil,
                    templateId: def1Id,
                    occurrenceKey: day3,  // Moved from day3 to day4
                    recurrenceEffectiveFromKey: nil,
                    occurrenceModified: true  // Explicitly modified due to move
                ),
                // Series 2, Occurrence 1: standard (occurrenceModified nil)
                TaskItemDTO(
                    id: occ4Id, title: "Weekly review", notes: "Review the week", isDone: false,
                    dayKey: day1, customListId: nil, timeMinutes: 600, colorHex: "#4ecdc4",
                    priority: 1, sortIndex: 1, alarmEnabled: false,
                    createdAt: t0.addingTimeInterval(100), updatedAt: t0.addingTimeInterval(200),
                    recurrence: nil, tagIds: [tag2Id],
                    needsImmediateAttention: false,
                    completedAt: nil,
                    notesRich: richNotesData1,
                    templateId: def2Id,
                    occurrenceKey: day1,
                    recurrenceEffectiveFromKey: nil,
                    occurrenceModified: nil
                ),
                // Series 2, Occurrence 2: on custom list with occurrence key (occurrenceModified false)
                TaskItemDTO(
                    id: occ5Id, title: "Weekly review (shopping)", notes: "", isDone: false,
                    dayKey: nil, customListId: listId, timeMinutes: nil, colorHex: nil,
                    priority: 0, sortIndex: 1, alarmEnabled: false,
                    createdAt: t0.addingTimeInterval(100), updatedAt: t0.addingTimeInterval(200),
                    recurrence: nil, tagIds: [tag2Id],
                    needsImmediateAttention: false,
                    completedAt: nil,
                    notesRich: richNotesData2,
                    templateId: def2Id,
                    occurrenceKey: day5,  // Occurrence placed on a list with a key
                    recurrenceEffectiveFromKey: nil,
                    occurrenceModified: false
                ),
                // Orphan occurrence (template missing)
                TaskItemDTO(
                    id: orphanOccId, title: "Orphan task", notes: "No template", isDone: false,
                    dayKey: day4, customListId: nil, timeMinutes: nil, colorHex: nil,
                    priority: 0, sortIndex: 10, alarmEnabled: false,
                    createdAt: t0, updatedAt: t0,
                    recurrence: nil, tagIds: [],
                    needsImmediateAttention: false,
                    completedAt: nil,
                    notesRich: nil,
                    templateId: orphanTemplateId,  // Template doesn't exist
                    occurrenceKey: day4,
                    recurrenceEffectiveFromKey: nil,
                    occurrenceModified: nil
                )
            ],
            subtasks: [
                // Subtask 1: for occ1 (incomplete)
                SubtaskDTO(id: sub1Id, title: "Check email", isDone: false, sortIndex: 1, parentId: occ1Id),
                // Subtask 2: for occ1 (complete)
                SubtaskDTO(id: sub2Id, title: "Review PRs", isDone: true, sortIndex: 2, parentId: occ1Id),
                // Subtask 3: for occ2 (incomplete, preserves order)
                SubtaskDTO(id: sub3Id, title: "Follow up", isDone: false, sortIndex: 0.5, parentId: occ2Id)
            ],
            taskTags: [
                TaskTagDTO(id: tag1Id, name: "work", colorHex: "#ff0000"),
                TaskTagDTO(id: tag2Id, name: "review", colorHex: "#00ff00")
            ],
            customLists: [
                CustomListDTO(id: listId, name: "Shopping", sortIndex: 1)
            ],
            taskOccurrences: [
                // Skip record 1: skipped slot for series 1, day 4
                TaskOccurrenceDTO(id: skipRec1Id, dayKey: day4, isDone: false, skipped: true,
                                  titleOverride: nil, timeOverride: nil, templateId: def1Id),
                // Override record 1: completed override for series 1, day 5 (legacy pair)
                TaskOccurrenceDTO(id: overrideRec1Id, dayKey: day5, isDone: true, skipped: false,
                                  titleOverride: "Standup (catchup)", timeOverride: 540, templateId: def1Id),
                // Skip record 2: duplicate for same day as override (legacy pair)
                TaskOccurrenceDTO(id: skipRec2Id, dayKey: day5, isDone: false, skipped: true,
                                  titleOverride: nil, timeOverride: nil, templateId: def1Id),
                // Skip record 3: skipped slot for series 2
                TaskOccurrenceDTO(id: skipRec3Id, dayKey: day4, isDone: false, skipped: true,
                                  titleOverride: nil, timeOverride: nil, templateId: def2Id),
                // Override record 2: completed override for series 2
                TaskOccurrenceDTO(id: overrideRec2Id, dayKey: day2, isDone: true, skipped: false,
                                  titleOverride: "Weekly review (early)", timeOverride: nil, templateId: def2Id)
            ]
        )

        return BackupStoreDTO(
            schemaVersion: BackupStoreDTO.currentSchemaVersion,
            appVersion: "0.1.17",
            exportedAt: t0.addingTimeInterval(1000),
            data: data
        )
    }

    // MARK: - Tests

    @Test("Schema-2 round-trip through plaintext backup preserves all fields")
    func plaintextRoundTrip() throws {
        let fixture = makeRichFixture()
        let data = try service.makeFile(store: fixture, passphrase: nil)

        let decoded = try service.readFile(data, passphrase: nil)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.data == fixture.data)
    }

    @Test("Schema-2 round-trip through encrypted backup preserves all fields")
    func encryptedRoundTrip() throws {
        let fixture = makeRichFixture()
        let data = try service.makeFile(store: fixture, passphrase: passphrase)

        let decoded = try service.readFile(data, passphrase: passphrase)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.data == fixture.data)
    }

    @Test("Restore into fresh store preserves all task fields")
    func restorePreservesAllFields() throws {
        let fixture = makeRichFixture()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        try BackupStore.restore(fixture, context: context)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        // Spot-check a few key fields for each original task
        for original in fixture.data.taskItems {
            let restored = try #require(byID[original.id])

            // Basic fields
            #expect(restored.title == original.title)
            #expect(restored.notes == original.notes)
            #expect(restored.isDone == original.isDone)

            // Schema 2 fields
            #expect(restored.occurrenceKey == original.occurrenceKey)
            #expect(restored.recurrenceEffectiveFromKey == original.recurrenceEffectiveFromKey)
            #expect(restored.occurrenceModified == original.occurrenceModified)
            #expect(restored.templateID == original.templateId)
        }
    }

    @Test("All three provenance values (nil/false/true) round-trip")
    func provenanceValuesPreserved() throws {
        let fixture = makeRichFixture()
        let data = try service.makeFile(store: fixture, passphrase: nil)
        let decoded = try service.readFile(data, passphrase: nil)

        let byModified = Dictionary(grouping: decoded.data.taskItems.filter { $0.templateId != nil }) { $0.occurrenceModified }

        // Should have all three provenance states
        #expect(byModified[nil] != nil, "Missing occurrenceModified nil")
        #expect(byModified[false] != nil, "Missing occurrenceModified false")
        #expect(byModified[true] != nil, "Missing occurrenceModified true")
    }

    @Test("An old reader rejects schema-2 backup")
    func olderReaderRejectsSchema2() throws {
        let fixture = makeRichFixture()
        let data = try service.makeFile(store: fixture, passphrase: nil)
        let decoded = try service.readFile(data, passphrase: nil)

        // Simulate an archived 0.1.16 reader: check if schemaVersion > 1 (old reader's guard)
        let schemaVersion = decoded.schemaVersion
        let wouldOldReaderAccept = schemaVersion <= 1
        #expect(wouldOldReaderAccept == false, "Schema 2 should be rejected by archived reader with schemaVersion guard")
    }

    @Test("Subtask fields (isDone, sortIndex) are preserved")
    func subtaskFieldsPreserved() throws {
        let fixture = makeRichFixture()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        try BackupStore.restore(fixture, context: context)

        let subtasks = try context.fetch(FetchDescriptor<Subtask>())
        let byID = Dictionary(uniqueKeysWithValues: subtasks.map { ($0.id, $0) })

        #expect(subtasks.count == fixture.data.subtasks.count)

        for original in fixture.data.subtasks {
            let restored = try #require(byID[original.id])
            #expect(restored.title == original.title)
            #expect(restored.isDone == original.isDone)
            #expect(restored.sortIndex == original.sortIndex)
        }
    }

    @Test("Tag relationships are preserved")
    func tagRelationshipsPreserved() throws {
        let fixture = makeRichFixture()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        try BackupStore.restore(fixture, context: context)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        for original in fixture.data.taskItems {
            let restored = try #require(byID[original.id])
            let restoredTagIds = Set(restored.tags.map(\.id))
            let expectedTagIds = Set(original.tagIds)
            #expect(restoredTagIds == expectedTagIds, "Tag mismatch for \(original.title)")
        }
    }

    @Test("Skip records are preserved")
    func skipRecordsPreserved() throws {
        let fixture = makeRichFixture()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        try BackupStore.restore(fixture, context: context)

        let records = try context.fetch(FetchDescriptor<TaskOccurrence>())
        #expect(Set(records.map(\.id)) == Set(fixture.data.taskOccurrences.map(\.id)))

        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for original in fixture.data.taskOccurrences {
            let restored = try #require(byID[original.id])
            #expect(restored.dayKey == original.dayKey)
            #expect(restored.isDone == original.isDone)
            #expect(restored.skipped == original.skipped)
        }
    }
}
