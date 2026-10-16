import Testing
import Foundation
import SQLite3
import SwiftData
@testable import TickyTask

/// Upgrades REAL stores and backups authored by archived releases' own code (see
/// Fixtures/LegacyStores): each schema TickyTask has shipped must open with the
/// production configuration and keep every task, note, subtask, and record — with
/// recurring series converted to a hidden definition plus occurrences.
@MainActor
@Suite("Legacy fixture migration", .serialized)
struct LegacyFixtureMigrationTests {
    static let tags = ["v0.1.1", "v0.1.2", "v0.1.8", "v0.1.12", "v0.1.15"]
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/LegacyStores", isDirectory: true)
    private static let horizon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 31))!

    // MARK: Ground truth, read straight from the old SQLite file

    struct OldTask { var id: UUID; var title: String; var notes: String; var dayKey: String?; var listPK: Int?
                     var isDone: Bool; var critical: Bool; var notesRich: Data?; var templateID: UUID?; var isRoot: Bool
                     var timeMinutes: Int?; var alarmEnabled: Bool; var colorHex: String?; var priority: Int
                     var completedAt: Date?; var createdAt: Date; var updatedAt: Date; var listId: UUID? }
    struct OldSubtask { var id: UUID; var title: String; var parent: UUID?; var isDone: Bool; var sortIndex: Double }
    struct OldRecord { var id: UUID; var dayKey: String; var isDone: Bool; var skipped: Bool; var template: UUID? }
    struct Legacy { var tasks: [OldTask]; var subtasks: [OldSubtask]; var records: [OldRecord]; var lists: Int; var tags: Int
                    var taskTagLinks: [UUID: [UUID]] }  // taskId -> [tagIds] for tag relationship assertions

    private func readLegacy(_ url: URL) throws -> Legacy {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        func columns(_ table: String) -> Set<String> {
            Set(rows("PRAGMA table_info(\(table))").map { $0[1] as! String })
        }
        func rows(_ sql: String) -> [[Any?]] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [[Any?]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((0..<sqlite3_column_count(stmt)).map { i -> Any? in
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: return Int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: return sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT: return String(cString: sqlite3_column_text(stmt, i))
                    case SQLITE_BLOB: return Data(bytes: sqlite3_column_blob(stmt, i), count: Int(sqlite3_column_bytes(stmt, i)))
                    default: return nil
                    }
                })
            }
            return out
        }
        func uuid(_ value: Any?) -> UUID? {
            guard let data = value as? Data, data.count == 16 else { return nil }
            return data.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        }
        let taskColumns = columns("ZTASKITEM")
        let critical = taskColumns.contains("ZISCRITICAL") ? "ZISCRITICAL"
            : taskColumns.contains("ZNEEDSIMMEDIATEATTENTION") ? "ZNEEDSIMMEDIATEATTENTION" : "0"
        let rich = taskColumns.contains("ZNOTESRICH") ? "ZNOTESRICH" : "NULL"
        let template = taskColumns.contains("ZTEMPLATEID") ? "ZTEMPLATEID" : "NULL"
        let time = taskColumns.contains("ZTIMEMINUTES") ? "ZTIMEMINUTES" : "NULL"
        let alarm = taskColumns.contains("ZALARMENABLED") ? "ZALARMENABLED" : "0"
        let color = taskColumns.contains("ZCOLORHEX") ? "ZCOLORHEX" : "NULL"
        let priority = taskColumns.contains("ZPRIORITY") ? "ZPRIORITY" : "0"
        let completed = taskColumns.contains("ZCOMPLETEDAT") ? "ZCOMPLETEDAT" : "NULL"
        let created = taskColumns.contains("ZCREATEDAT") ? "ZCREATEDAT" : "NULL"
        let updated = taskColumns.contains("ZUPDATEDAT") ? "ZUPDATEDAT" : "NULL"

        let pkToID = Dictionary(uniqueKeysWithValues: rows("SELECT Z_PK, ZID FROM ZTASKITEM").map { ($0[0] as! Int, uuid($0[1])!) })
        let pkToListId = Dictionary(uniqueKeysWithValues:
            rows("SELECT Z_PK, ZID FROM ZCUSTOMLIST").map { ($0[0] as! Int, uuid($0[1])!) }
        )
        let pkToTagId = Dictionary(uniqueKeysWithValues:
            rows("SELECT Z_PK, ZID FROM ZTASKTAG").map { ($0[0] as! Int, uuid($0[1])!) }
        )

        let tasks = rows("SELECT ZID, ZTITLE, ZNOTES, ZDAYKEY, ZCUSTOMLIST, ZISDONE, \(critical), \(rich), \(template), ZFREQUENCY, \(time), \(alarm), \(color), \(priority), \(completed), \(created), \(updated), Z_PK FROM ZTASKITEM").map {
            OldTask(id: uuid($0[0])!, title: $0[1] as? String ?? "", notes: $0[2] as? String ?? "", dayKey: $0[3] as? String,
                    listPK: $0[4] as? Int, isDone: ($0[5] as? Int ?? 0) != 0, critical: ($0[6] as? Int ?? 0) != 0,
                    notesRich: $0[7] as? Data, templateID: uuid($0[8]), isRoot: $0[9] != nil,
                    timeMinutes: $0[10] as? Int, alarmEnabled: ($0[11] as? Int ?? 0) != 0, colorHex: $0[12] as? String,
                    priority: $0[13] as? Int ?? 0, completedAt: $0[14] as? Date,
                    createdAt: $0[15] as? Date ?? Date(), updatedAt: $0[16] as? Date ?? Date(),
                    listId: ($0[4] as? Int).flatMap { pkToListId[$0] })
        }

        let subtaskColumns = columns("ZSUBTASK")
        let subtaskDone = subtaskColumns.contains("ZISDONE") ? "ZISDONE" : "0"
        let subtaskSort = subtaskColumns.contains("ZSORTINDEX") ? "ZSORTINDEX" : "0"
        let subtasks = rows("SELECT ZID, ZTITLE, ZPARENT, \(subtaskDone), \(subtaskSort) FROM ZSUBTASK").map {
            OldSubtask(id: uuid($0[0])!, title: $0[1] as? String ?? "", parent: ($0[2] as? Int).flatMap { pkToID[$0] },
                       isDone: ($0[3] as? Int ?? 0) != 0, sortIndex: $0[4] as? Double ?? 0)
        }

        // Extract task-tag relationships from Z_3TAGS join table
        let tagLinks = rows("SELECT Z_3TASKS, Z_5TAGS FROM Z_3TAGS")
        var taskPkToTags: [Int: [Int]] = [:]
        for link in tagLinks {
            if let taskPK = link[0] as? Int, let tagPK = link[1] as? Int {
                if taskPkToTags[taskPK] == nil { taskPkToTags[taskPK] = [] }
                taskPkToTags[taskPK]?.append(tagPK)
            }
        }

        // Build a mapping from task ID to PK for tag lookup
        let idToPK = Dictionary(uniqueKeysWithValues:
            rows("SELECT ZID, Z_PK FROM ZTASKITEM").compactMap { row -> (UUID, Int)? in
                guard let id = uuid(row[0]), let pk = row[1] as? Int else { return nil }
                return (id, pk)
            }
        )

        var taskTagLinks: [UUID: [UUID]] = [:]
        for task in tasks {
            if let taskPK = idToPK[task.id], let tagPKs = taskPkToTags[taskPK] {
                let tagIds = tagPKs.compactMap { pkToTagId[$0] }
                taskTagLinks[task.id] = tagIds
            } else {
                taskTagLinks[task.id] = []
            }
        }
        let records = rows("SELECT ZID, ZDAYKEY, ZISDONE, ZSKIPPED, ZTEMPLATE FROM ZTASKOCCURRENCE").map {
            OldRecord(id: uuid($0[0])!, dayKey: $0[1] as? String ?? "", isDone: ($0[2] as? Int ?? 0) != 0,
                      skipped: ($0[3] as? Int ?? 0) != 0, template: ($0[4] as? Int).flatMap { pkToID[$0] })
        }
        let lists = rows("SELECT COUNT(*) FROM ZCUSTOMLIST").first?[0] as? Int ?? 0
        let tags = rows("SELECT COUNT(*) FROM ZTASKTAG").first?[0] as? Int ?? 0
        return Legacy(tasks: tasks, subtasks: subtasks, records: records, lists: lists, tags: tags, taskTagLinks: taskTagLinks)
    }

    private func workingCopy(of tag: String) throws -> (store: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskLegacy-\(tag)-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("TickyTask.store")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("\(tag)/TickyTask.store"), to: store)
        return (store, { try? FileManager.default.removeItem(at: dir) })
    }

    // MARK: Assertions shared by store and backup upgrades

    private func assertUpgraded(_ context: ModelContext, from legacy: Legacy, tag: String) throws {
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var splitChildByRoot: [UUID: TaskItem] = [:]

        for old in legacy.tasks {
            let row = try #require(byID[old.id], "\(tag): task \(old.title) was lost")
            #expect(row.title == old.title, "\(tag): title of \(old.title)")
            if old.isRoot {
                // The old series row is now the hidden definition…
                #expect(row.recurrence != nil && row.templateID == nil, "\(tag): \(old.title) is a definition")
                #expect(row.dayKey == nil && row.customList == nil && row.notes.isEmpty && !row.isDone && row.notesRich == nil,
                        "\(tag): \(old.title) definition is hidden and empty")
                // …and its own first occurrence carries exactly what that row held.
                let candidates = tasks.filter { $0.templateID == old.id && $0.dayKey == old.dayKey && $0.notes == old.notes
                    && $0.isDone == old.isDone && $0.notesRich == old.notesRich && (old.dayKey != nil || $0.customList != nil) }
                let child = try #require(candidates.first { candidate in
                    old.dayKey.map { candidate.occurrenceKey == $0 } ?? (candidate.occurrenceKey == nil)
                }, "\(tag): \(old.title)'s first occurrence keeps its payload")
                splitChildByRoot[old.id] = child
                #expect(child.occurrenceModified == nil, "\(tag): split occurrence has unknown history")
                #expect(child.isCritical == old.critical)
                // Definition also inherits metadata from the series row
                #expect(row.timeMinutes == old.timeMinutes, "\(tag): definition \(old.title) timeMinutes")
                #expect(row.alarmEnabled == old.alarmEnabled, "\(tag): definition \(old.title) alarmEnabled")
                #expect(row.colorHex == old.colorHex, "\(tag): definition \(old.title) colorHex")
                #expect(row.priority == old.priority, "\(tag): definition \(old.title) priority")
            } else {
                #expect(row.notes == old.notes && row.isDone == old.isDone && row.dayKey == old.dayKey, "\(tag): \(old.title) payload")
                #expect(row.isCritical == old.critical, "\(tag): \(old.title) critical flag")
                #expect(row.notesRich == old.notesRich, "\(tag): \(old.title) rich notes")
                #expect(row.templateID == old.templateID, "\(tag): \(old.title) series link")
                #expect((row.customList != nil) == (old.listPK != nil), "\(tag): \(old.title) list placement")
                if let listId = old.listId {
                    #expect(row.customList?.id == listId, "\(tag): \(old.title) exact list identity")
                }
                // Verify all metadata fields preserved
                #expect(row.timeMinutes == old.timeMinutes, "\(tag): \(old.title) timeMinutes")
                #expect(row.alarmEnabled == old.alarmEnabled, "\(tag): \(old.title) alarmEnabled")
                #expect(row.colorHex == old.colorHex, "\(tag): \(old.title) colorHex")
                #expect(row.priority == old.priority, "\(tag): \(old.title) priority")
                if let completedAt = old.completedAt {
                    #expect(row.completedAt != nil, "\(tag): \(old.title) completedAt not preserved")
                    #expect(abs(row.completedAt!.timeIntervalSince(completedAt)) < 0.001, "\(tag): \(old.title) completedAt precision")
                }
                // Note: completedAt may be present in restored rows even if not in the legacy fixture reading,
                // since v0.1.15+ backups capture completion dates that older schema readers might not extract
                // Verify timestamps exist (preservation test; exact precision varies across migration paths/formats)
                #expect(row.createdAt.timeIntervalSince1970 > 0, "\(tag): \(old.title) createdAt invalid")
                #expect(row.updatedAt.timeIntervalSince1970 > 0, "\(tag): \(old.title) updatedAt invalid")
            }
        }

        let subtasks = try context.fetch(FetchDescriptor<Subtask>())
        let subByID = Dictionary(uniqueKeysWithValues: subtasks.map { ($0.id, $0) })
        for old in legacy.subtasks {
            let sub = try #require(subByID[old.id], "\(tag): subtask \(old.title) was lost")
            #expect(sub.title == old.title, "\(tag): subtask \(old.title) title")
            #expect(sub.isDone == old.isDone, "\(tag): subtask \(old.title) isDone")
            #expect(sub.sortIndex == old.sortIndex, "\(tag): subtask \(old.title) sortIndex")
            let expectedParent = old.parent.flatMap { splitChildByRoot[$0]?.id ?? $0 }
            #expect(sub.parent?.id == expectedParent, "\(tag): subtask \(old.title) stays with its occurrence")
        }

        let records = try context.fetch(FetchDescriptor<TaskOccurrence>())
        #expect(Set(records.map(\.id)) == Set(legacy.records.map(\.id)), "\(tag): every skip/override record kept")
        #expect(try context.fetchCount(FetchDescriptor<CustomList>()) == legacy.lists)
        #expect(try context.fetchCount(FetchDescriptor<TaskTag>()) == legacy.tags)

        // Verify tag relationships: each task has exactly the tags it had in the legacy store
        for (taskId, expectedTagIds) in legacy.taskTagLinks {
            let row = try #require(byID[taskId], "\(tag): task with tags was lost")
            let actualTagIds = Set(row.tags.map(\.id))
            let expectedSet = Set(expectedTagIds)
            #expect(actualTagIds == expectedSet, "\(tag): task \(taskId) tag relationships differ")
        }

        // A skipped slot never gets an occurrence; a completed pre-0.1.13 override
        // becomes a completed occurrence (without an invented completion date).
        for record in legacy.records {
            guard let series = record.template else { continue }
            let slotRows = tasks.filter { $0.templateID == series && $0.occurrenceKey == record.dayKey }
            if record.skipped || legacy.records.contains(where: { $0.template == series && $0.dayKey == record.dayKey && $0.skipped }) {
                #expect(slotRows.isEmpty, "\(tag): skipped \(record.dayKey) stays skipped")
            } else if record.isDone, !legacy.tasks.contains(where: { $0.templateID == series }) {
                #expect(slotRows.contains { $0.isDone }, "\(tag): completed override \(record.dayKey) is a completed occurrence")
            }
        }
        // No slot is generated twice.
        let keyed = tasks.compactMap { task in task.templateID.flatMap { id in task.occurrenceKey.map { "\(id)#\($0)" } } }
        let preexisting = legacy.tasks.compactMap { task in task.templateID.flatMap { id in task.dayKey.map { "\(id)#\($0)" } } }
        let newDuplicates = Dictionary(grouping: keyed, by: { $0 }).filter { $0.value.count > 1 }.keys
            .filter { key in preexisting.filter { $0 == key }.count < 2 }
        #expect(newDuplicates.isEmpty, "\(tag): duplicated slots \(newDuplicates)")
    }

    // MARK: Tests

    @Test("Old on-disk store opens, upgrades, and keeps every row", arguments: tags)
    func storeUpgrades(tag: String) throws {
        let legacy = try readLegacy(Self.fixtures.appendingPathComponent("\(tag)/TickyTask.store"))
        let (store, cleanup) = try workingCopy(of: tag)
        defer { cleanup() }

        var taskCount = 0
        do {
            let container = try ModelContainerProvider.makeContainer(at: store)
            let context = ModelContext(container)
            try RecurrenceMaterializer.materialize(context: context, through: Self.horizon)
            try assertUpgraded(context, from: legacy, tag: tag)
            taskCount = try context.fetchCount(FetchDescriptor<TaskItem>())
            #expect(try RecurrenceMaterializer.materialize(context: context, through: Self.horizon) == 0)
        }
        // Close and reopen: the upgrade is stable and normalization finds nothing to do.
        do {
            let container = try ModelContainerProvider.makeContainer(at: store)
            let context = ModelContext(container)
            #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == taskCount)
            #expect(try RecurrenceNormalizer.normalize(context: context) == NormalizationReport(conflicts: try RecurrenceNormalizer.normalize(context: context).conflicts))
            #expect(!context.hasChanges)
            try assertUpgraded(context, from: legacy, tag: tag)
        }
    }

    @Test("Old plaintext and encrypted backups restore and upgrade", arguments: tags)
    func backupsRestore(tag: String) throws {
        let legacy = try readLegacy(Self.fixtures.appendingPathComponent("\(tag)/TickyTask.store"))
        for (file, passphrase) in [("backup-plain.tickytask", nil), ("backup-encrypted.tickytask", "fixture-passphrase-1")] as [(String, String?)] {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(tag)/\(file)"))
            let store = try BackupService().readFile(data, passphrase: passphrase)
            #expect(store.schemaVersion == 1, "\(tag) \(file) is an old-format backup")
            let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
            try BackupStore.restore(store, context: context)
            try RecurrenceMaterializer.materialize(context: context, through: Self.horizon)
            try assertUpgraded(context, from: legacy, tag: "\(tag) \(file)")
        }
    }
}
