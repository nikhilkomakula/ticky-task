import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// The section-I acceptance cases, each checked against an exact snapshot of every
/// stored row (tasks, subtasks, skip records, lists, tags) — so "nothing else
/// changed" is proven, not sampled. On-disk cases release and reopen the container.
@MainActor
@Suite("Series sign-off", .serialized)
struct SeriesSignoffTests {
    // MARK: - Exact store snapshot

    struct TaskRow: Equatable {
        var title: String, notes: String, notesRich: Data?, isDone: Bool, completedAt: Int64?
        var dayKey: String?, listID: UUID?, timeMinutes: Int?, colorHex: String?, priority: Int
        var sortIndex: Double, alarmEnabled: Bool, isCritical: Bool, createdAt: Int64, updatedAt: Int64
        var recurrence: RecurrenceRule?, templateID: UUID?, occurrenceKey: String?
        var effectiveFrom: String?, modified: Bool?, tagIDs: Set<UUID>
    }
    struct Graph: Equatable {
        var tasks: [UUID: TaskRow] = [:]
        var subtasks: [UUID: String] = [:]
        var records: [UUID: String] = [:]
        var lists: [UUID: String] = [:]
        var tags: [UUID: String] = [:]
    }

    /// Milliseconds: the backup format's date precision.
    private func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSinceReferenceDate * 1000).rounded()) }

    private func graph(_ context: ModelContext) throws -> Graph {
        var g = Graph()
        for t in try context.fetch(FetchDescriptor<TaskItem>()) {
            g.tasks[t.id] = TaskRow(title: t.title, notes: t.notes, notesRich: t.notesRich, isDone: t.isDone,
                                    completedAt: t.completedAt.map(ms), dayKey: t.dayKey, listID: t.customList?.id,
                                    timeMinutes: t.timeMinutes, colorHex: t.colorHex, priority: t.priority,
                                    sortIndex: t.sortIndex, alarmEnabled: t.alarmEnabled, isCritical: t.isCritical,
                                    createdAt: ms(t.createdAt), updatedAt: ms(t.updatedAt), recurrence: t.recurrence,
                                    templateID: t.templateID, occurrenceKey: t.occurrenceKey,
                                    effectiveFrom: t.recurrenceEffectiveFromKey, modified: t.occurrenceModified,
                                    tagIDs: Set(t.tags.map(\.id)))
        }
        for s in try context.fetch(FetchDescriptor<Subtask>()) {
            g.subtasks[s.id] = "\(s.title)|\(s.isDone)|\(s.sortIndex)|\(s.parent?.id.uuidString ?? "-")"
        }
        for r in try context.fetch(FetchDescriptor<TaskOccurrence>()) {
            g.records[r.id] = "\(r.dayKey)|\(r.skipped)|\(r.isDone)|\(r.titleOverride ?? "-")|\(r.template?.id.uuidString ?? "-")"
        }
        for l in try context.fetch(FetchDescriptor<CustomList>()) { g.lists[l.id] = "\(l.name)|\(l.sortIndex)" }
        for t in try context.fetch(FetchDescriptor<TaskTag>()) { g.tags[t.id] = t.name }
        return g
    }

    // MARK: - Fixtures

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ m: Int, _ d: Int, _ y: Int = 2026) -> Date {
        cal().date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func key(_ m: Int, _ d: Int, _ y: Int = 2026) -> String { WeekMath.dayKey(for: date(m, d, y), calendar: cal()) }

    private func diskDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func open(_ dir: URL) throws -> ModelContext {
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: dir.appendingPathComponent("TickyTask.store")))
        // Contexts autosave by default; these tests reopen the same file through a
        // second container, so only explicit saves may reach it.
        context.autosaveEnabled = false
        return context
    }

    struct Fixture {
        var definition: TaskItem, other: TaskItem, oneOff: TaskItem, list: CustomList
        var byKey: [String: TaskItem]
    }

    /// A daily "Standup" from Jan 1 (a Thursday) generated through Jan 20 — today is
    /// Jan 5 — with distinct work on several occurrences: notes, rich notes, a
    /// subtask, a completion, one moved to another day and one moved into a list;
    /// plus an unrelated weekly series, a same-title one-off, and a tag.
    private func fixture(_ context: ModelContext) throws -> Fixture {
        let c = cal()
        let tag = TaskTag(name: "work")
        context.insert(tag)
        let list = CustomList(name: "Inbox", sortIndex: 1)
        context.insert(list)
        let seed = TaskItem(title: "Standup", dayKey: key(1, 1), timeMinutes: 540, priority: 1, alarmEnabled: true)
        seed.tags = [tag]
        context.insert(seed)
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: RecurrenceRule(frequency: .daily, startDate: date(1, 1)),
            through: date(1, 20), context: context, calendar: c)
        let otherSeed = TaskItem(title: "Weekly", dayKey: key(1, 2))
        context.insert(otherSeed)
        let other = try RecurrenceMaterializer.startSeries(
            from: otherSeed, rule: RecurrenceRule(frequency: .weekly, weekdays: [6], startDate: date(1, 2)),
            through: date(1, 31), context: context, calendar: c)
        let oneOff = TaskItem(title: "Standup", dayKey: key(1, 7))
        context.insert(oneOff)
        try context.save()

        var byKey = Dictionary(uniqueKeysWithValues: try RecurrenceMaterializer.children(of: definition, context: context)
            .map { ($0.occurrenceKey!, $0) })
        byKey[key(1, 3)]!.notes = "jan3 notes"
        byKey[key(1, 3)]!.markOccurrenceModified()
        byKey[key(1, 4)]!.setDone(true, at: date(1, 4))
        byKey[key(1, 7)]!.notesRich = try NotesCodec.encode(NotesDocument(blocks: [NotesBlock(kind: .paragraph, runs: [NotesRun(text: "jan7 rich")])]))
        byKey[key(1, 7)]!.notes = "jan7 rich"
        byKey[key(1, 7)]!.subtasks = [Subtask(title: "prep", isDone: true, sortIndex: 2), Subtask(title: "slides", sortIndex: 1)]
        byKey[key(1, 7)]!.markOccurrenceModified()
        try context.save()
        let service = DataService(context)
        try service.dropTask(byKey[key(1, 9)]!.id, into: .day(key(1, 10)), before: nil,
                             siblings: try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == key(1, 10) })
        try service.dropTask(byKey[key(1, 11)]!.id, into: .customList(list), before: nil, siblings: list.tasks)
        return Fixture(definition: definition, other: other, oneOff: oneOff, list: list, byKey: byKey)
    }

    // MARK: - 1. Failure atomicity, on disk, for every destructive transaction

    enum Operation: String, CaseIterable {
        case combinedEdit, ruleChangeFetchFails, move, deleteOccurrence, deleteSeries, deleteList, autoDelete, restore, materializeLegacy
    }

    @Test("A failed transaction leaves the exact graph, in memory and after reopening", arguments: Operation.allCases)
    func failureAtomicity(_ operation: Operation) throws {
        let dir = try diskDir()
        let c = cal()
        let before: Graph
        var restarted = false
        PersistenceRecovery.testHook = { restarted = true }
        defer {
            PersistenceRecovery.testHook = nil
            // A discarded context stays alive, so its store file must too.
            if !restarted { try? FileManager.default.removeItem(at: dir) }
        }
        do {
            let context = try open(dir)
            // The app quits instead of saving this context's change; here it's kept
            // alive (releasing a container with unsaved changes crashes SwiftData).
            DiscardedContexts.keep(context)
            let f = try fixture(context)
            if operation == .materializeLegacy {
                // A pre-0.1.17 series row (rule + day + its own work) awaiting its split.
                let legacy = TaskItem(title: "Legacy", dayKey: key(1, 6), recurrence: RecurrenceRule(frequency: .daily, startDate: date(1, 6)))
                legacy.notes = "legacy first-day notes"
                legacy.subtasks = [Subtask(title: "legacy sub")]
                context.insert(legacy)
            }
            try context.save()
            before = try graph(context)
            let backup = try BackupStore.makeSnapshot(context: context)
            PersistenceFaults.armed = operation == .ruleChangeFetchFails ? [.seriesFetch] : [.transaction]
            defer { PersistenceFaults.armed = [] }

            let jan7 = f.byKey[key(1, 7)]!
            var threw = true
            switch operation {
            case .combinedEdit, .ruleChangeFetchFails:
                var edited = SharedAttributes(jan7)
                edited.title = "Renamed"
                edited.timeMinutes = 600
                var subtasks = SubtaskDraft.drafts(of: jan7)
                subtasks.removeFirst()
                subtasks.append(SubtaskDraft(id: UUID(), title: "new", isDone: false, sortIndex: 9))
                let edit = TaskEdit(originalShared: SharedAttributes(jan7), editedShared: edited,
                                    notes: NotesDocument(blocks: [NotesBlock(kind: .paragraph, runs: [NotesRun(text: "changed")])]),
                                    subtasks: subtasks,
                                    rule: .replace(RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(1, 1))))
                #expect(throws: (any Error).self) {
                    try TaskEditCommit.commit(edit, to: jan7, context: context, today: date(1, 5), horizon: date(1, 31), calendar: c)
                }
            case .move:
                #expect(throws: (any Error).self) {
                    try DataService(context).dropTask(jan7.id, into: .day(key(1, 12)), before: nil, siblings: [])
                }
            case .deleteOccurrence:
                #expect(throws: (any Error).self) { try RecurrenceMaterializer.deleteOccurrence(jan7, context: context) }
            case .deleteSeries:
                #expect(throws: (any Error).self) { try RecurrenceMaterializer.deleteSeries(jan7, context: context) }
            case .deleteList:
                #expect(throws: (any Error).self) { try DataService(context).delete(f.list) }
            case .autoDelete:
                threw = false   // it logs and keeps going; nothing may change
                AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 1, now: date(1, 20))
            case .restore:
                var data = backup.data
                data.taskItems.removeAll { $0.id == f.oneOff.id }   // so the restore really changes something
                let legacyBackup = BackupStoreDTO(schemaVersion: 1, appVersion: "0.1.15", exportedAt: Date(), data: data)
                #expect(throws: (any Error).self) { try BackupStore.restore(legacyBackup, context: context) }
            case .materializeLegacy:
                #expect(throws: (any Error).self) {
                    try RecurrenceMaterializer.materialize(context: context, through: date(1, 31), calendar: c)
                }
            }
            _ = threw
            #expect(PersistenceFaults.armed.isEmpty, "\(operation): the injected failure was reached")
            let live = try graph(context)
            switch operation {
            case .ruleChangeFetchFails, .move, .materializeLegacy:
                // Nothing was deleted, so the transaction was undone in place.
                #expect(live == before, "\(operation): the live objects show the saved state")
                #expect(!restarted, "\(operation): undone in place, no restart")
            case .combinedEdit, .deleteOccurrence, .deleteSeries, .deleteList, .autoDelete, .restore:
                // Deletions pending, which SwiftData can't undo: the app restarts
                // without saving, and nothing may save this context before it does.
                #expect(restarted, "\(operation): the app restarts to discard the change")
                #expect(!context.autosaveEnabled, "\(operation): autosave can't commit it meanwhile")
            }
        }
        let reopened = try open(dir)
        #expect(try graph(reopened) == before, "\(operation): nothing reached the disk")
    }

    // MARK: - 2. Schema-2 backup: disk → backup → disk, exactly

    @Test("A new-format backup restores the exact graph into a fresh on-disk store", arguments: [false, true])
    func backupRoundTrip(encrypted: Bool) throws {
        let source = try diskDir(), target = try diskDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let c = cal()
        let original: Graph
        let file: Data
        do {
            let context = try open(source)
            let f = try fixture(context)
            // A changed rule (effective boundary), a skip, an orphan, and an override+skip pair.
            try RecurrenceMaterializer.changeRule(of: f.other, to: RecurrenceRule(frequency: .daily, startDate: date(1, 2)),
                                                  today: date(1, 5), through: date(1, 31), context: context, calendar: c)
            try context.save()
            try RecurrenceMaterializer.deleteOccurrence(f.byKey[key(1, 12)]!, context: context)
            // Beyond the generated range (Jan 20): the skip must win when it is generated.
            f.definition.occurrences.append(TaskOccurrence(dayKey: key(1, 25), isDone: true))
            f.definition.occurrences.append(TaskOccurrence(dayKey: key(1, 25), skipped: true))
            let orphan = TaskItem(title: "Orphan", dayKey: key(1, 8))
            orphan.templateID = UUID()
            orphan.occurrenceKey = key(1, 8)
            orphan.occurrenceModified = false
            context.insert(orphan)
            try context.save()
            original = try graph(context)
            #expect(Set(original.tasks.values.map(\.modified)) == [nil, false, true])
            let snapshot = try BackupStore.makeSnapshot(context: context)
            #expect(snapshot.schemaVersion == 2)
            file = try BackupService().makeFile(store: snapshot, passphrase: encrypted ? "round-trip-passphrase" : nil)
        }
        do {
            let store = try BackupService().readFile(file, passphrase: encrypted ? "round-trip-passphrase" : nil)
            let context = try open(target)
            try BackupStore.restore(store, context: context)
        }
        let restored = try open(target)
        let restoredGraph = try graph(restored)
        #expect(restoredGraph.subtasks == original.subtasks && restoredGraph.records == original.records)
        #expect(restoredGraph.lists == original.lists && restoredGraph.tags == original.tags)
        for (id, row) in original.tasks {
            #expect(restoredGraph.tasks[id] == row, "task \(row.title) \(row.occurrenceKey ?? "-") round-trips exactly")
        }
        #expect(restoredGraph.tasks.count == original.tasks.count)

        // Generating again honours skips, boundaries, and slots — nothing duplicates.
        try RecurrenceMaterializer.materialize(context: restored, through: date(3, 31), calendar: c)
        let rows = try restored.fetch(FetchDescriptor<TaskItem>())
        let slots = rows.compactMap { r in r.templateID.flatMap { id in r.occurrenceKey.map { "\(id)#\($0)" } } }
        #expect(Set(slots).count == slots.count, "no slot twice")
        let standupKeys = Set(rows.filter { $0.templateID == restoredGraph.tasks.first { $0.value.title == "Standup" && $0.value.recurrence != nil }?.key }
            .compactMap(\.occurrenceKey))
        #expect(!standupKeys.contains(key(1, 12)) && !standupKeys.contains(key(1, 25)), "skipped slots stay skipped")
        #expect(standupKeys.contains(key(1, 26)), "the series still generates around them")
        let weeklyID = try #require(restoredGraph.tasks.first { $0.value.title == "Weekly" && $0.value.recurrence != nil }?.key)
        let weeklyKeys = Set(rows.filter { $0.templateID == weeklyID }.compactMap(\.occurrenceKey))
        #expect(!weeklyKeys.contains(key(1, 3)) && !weeklyKeys.contains(key(1, 5)), "the new rule never fills the past")
        #expect(weeklyKeys.contains(key(1, 6)) && weeklyKeys.contains(key(3, 31)))
    }

    // MARK: - 3. Every shared field from every kind of occurrence

    enum Field: String, CaseIterable { case title, time, alarm, priority, critical, color, tags }
    enum Source: String, CaseIterable { case first, later, past, done, moved, listed }

    @Test("A shared field edited from any occurrence reaches the whole series and nothing else",
          arguments: Field.allCases, Source.allCases)
    func sharedFieldMatrix(_ field: Field, _ source: Source) throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let f = try fixture(context)
        let extraTag = TaskTag(name: "extra")
        context.insert(extraTag)
        try context.save()
        let row: TaskItem = switch source {
        case .first: f.byKey[key(1, 1)]!
        case .later: f.byKey[key(1, 15)]!
        case .past: f.byKey[key(1, 3)]!
        case .done: f.byKey[key(1, 4)]!
        case .moved: f.byKey[key(1, 9)]!     // sits on Jan 10
        case .listed: f.byKey[key(1, 11)]!   // sits in Inbox
        }
        let before = try graph(context)
        var edited = SharedAttributes(row)
        switch field {
        case .title: edited.title = "Daily sync"
        case .time: edited.timeMinutes = 615
        case .alarm: edited.alarmEnabled = false
        case .priority: edited.priority = 2
        case .critical: edited.isCritical = true
        case .color: edited.colorHex = "#00ff00"
        case .tags: edited.tagIDs = [extraTag.id]
        }
        try TaskEditCommit.commit(TaskEdit(originalShared: SharedAttributes(row), editedShared: edited), to: row,
                                  context: context, today: date(1, 5), horizon: date(1, 31), calendar: cal())
        let after = try graph(context)
        let series = Set([f.definition.id] + (try RecurrenceMaterializer.children(of: f.definition, context: context)).map(\.id))
        for (id, old) in before.tasks {
            var expected = old
            if series.contains(id) {
                switch field {
                case .title: expected.title = "Daily sync"
                case .time: expected.timeMinutes = 615
                case .alarm: expected.alarmEnabled = false
                case .priority: expected.priority = 2
                case .critical: expected.isCritical = true
                case .color: expected.colorHex = "#00ff00"
                case .tags: expected.tagIDs = [extraTag.id]
                }
                expected.updatedAt = after.tasks[id]!.updatedAt   // stamped only because the value changed
                #expect(after.tasks[id]!.updatedAt != old.updatedAt || expected == old)
            }
            #expect(after.tasks[id] == expected, "\(field) from \(source): \(old.title) \(old.occurrenceKey ?? "-")")
        }
        #expect(after.subtasks == before.subtasks && after.records == before.records)
    }

    // MARK: - 4. Provenance decides what a rule change may remove

    @Test("Only untouched, generated, unmatched future occurrences are removed by a rule change",
          arguments: [Bool?.none, false, true], ["past", "today", "future"])
    func provenanceMatrix(_ modified: Bool?, _ when: String) throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let f = try fixture(context)
        // Jan 1 is a Thursday: the weekly rule keeps Thursdays (Jan 8, 15) and drops other days.
        let unmatched = f.byKey[when == "past" ? key(1, 2) : when == "today" ? key(1, 5) : key(1, 6)]!
        let matched = f.byKey[when == "past" ? key(1, 1) : when == "today" ? key(1, 1) : key(1, 8)]!
        for row in [unmatched, matched] where row.occurrenceKey != key(1, 1) { row.occurrenceModified = modified }
        try context.save()
        let ids = (unmatched.id, matched.id)
        try RecurrenceMaterializer.changeRule(of: f.definition, to: RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(1, 1)),
                                              today: date(1, 5), through: date(1, 31), context: context, calendar: cal())
        try context.save()
        let alive = Set(try context.fetch(FetchDescriptor<TaskItem>()).map(\.id))
        let removable = modified == false && when == "future"
        #expect(alive.contains(ids.0) == !removable, "unmatched \(when) occurrence with provenance \(String(describing: modified))")
        #expect(alive.contains(ids.1), "a matched occurrence is always kept in place")
    }

    @Test("Sticky provenance protects an unmatched future occurrence", arguments: ["reopen", "clearedNotes", "movedBack", "reordered"])
    func stickyProvenance(_ action: String) throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let f = try fixture(context)
        let row = f.byKey[key(1, 6)]!   // future, not a Thursday
        let service = DataService(context)
        switch action {
        case "reopen": row.setDone(true); row.setDone(false)
        case "clearedNotes":
            let draft = SharedAttributes(row)
            try TaskEditCommit.commit(TaskEdit(originalShared: draft, editedShared: draft,
                                               notes: NotesDocument(blocks: [NotesBlock(kind: .paragraph, runs: [NotesRun(text: "x")])])),
                                      to: row, context: context, horizon: date(1, 31))
            try TaskEditCommit.commit(TaskEdit(originalShared: draft, editedShared: draft, notes: NotesDocument(blocks: [])),
                                      to: row, context: context, horizon: date(1, 31))
            row.notesRich = nil   // as empty as a generated row
            row.notes = ""
        case "movedBack":
            try service.dropTask(row.id, into: .day(key(1, 7)), before: nil, siblings: [])
            try service.dropTask(row.id, into: .day(key(1, 6)), before: nil, siblings: [])
        default:
            let day = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == key(1, 6) }
            try service.dropTask(row.id, into: .day(key(1, 6)), before: day.first { $0.id != row.id }?.id, siblings: day)
        }
        try context.save()
        let id = row.id
        #expect(row.occurrenceModified == true && row.occurrenceKey == key(1, 6))
        for rule in [RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(1, 1)),
                     RecurrenceRule(frequency: .daily, end: .until(date(1, 5)), startDate: date(1, 1))] {
            try RecurrenceMaterializer.changeRule(of: f.definition, to: rule, today: date(1, 5), through: date(1, 31),
                                                  context: context, calendar: cal())
            try context.save()
            #expect(try context.fetch(FetchDescriptor<TaskItem>()).contains { $0.id == id }, "\(action): kept by \(rule.frequency)")
        }
    }

    @Test("A rule change that excludes the opened occurrence keeps it when the same Done adds its first subtask",
          arguments: ["weekly", "stop"])
    func subtaskWithRuleChangeKeepsOccurrence(_ change: String) throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let f = try fixture(context)
        let row = f.byKey[key(1, 6)]!   // future, untouched, not a Thursday
        #expect(row.occurrenceModified == false && row.subtasks.isEmpty)
        let id = row.id
        let rule = change == "weekly" ? RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(1, 1))
                                      : RecurrenceRule(frequency: .daily, end: .until(date(1, 5)), startDate: date(1, 1))
        let shared = SharedAttributes(row)
        try TaskEditCommit.commit(TaskEdit(originalShared: shared, editedShared: shared,
                                           subtasks: [SubtaskDraft(id: UUID(), title: "agenda", isDone: false, sortIndex: 1)],
                                           rule: .replace(rule)),
                                  to: row, context: context, today: date(1, 5), horizon: date(1, 31), calendar: cal())
        let kept = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == id }, "the opened occurrence is kept")
        #expect(kept.subtasks.map(\.title) == ["agenda"] && kept.occurrenceModified == true)
    }

    // MARK: - 5. Offline catch-up and far-future reconciliation (exact sets)

    @Test("After days away, the old rule catches up through today and the new one starts tomorrow")
    func offlineCatchUp() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let c = cal()
        let seed = TaskItem(title: "Daily", dayKey: key(1, 1))
        context.insert(seed)
        let definition = try RecurrenceMaterializer.startSeries(from: seed, rule: RecurrenceRule(frequency: .daily, startDate: date(1, 1)),
                                                                through: date(1, 5), context: context, calendar: c)
        try context.save()
        let early = Dictionary(uniqueKeysWithValues: try RecurrenceMaterializer.children(of: definition, context: context)
            .map { ($0.occurrenceKey!, $0.id) })

        // The app was closed Jan 6–20: nothing generated. Today is Jan 20.
        try RecurrenceMaterializer.changeRule(of: definition, to: RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(1, 1)),
                                              today: date(1, 20), through: date(1, 31), context: context, calendar: c)
        try context.save()
        let now = Dictionary(uniqueKeysWithValues: try RecurrenceMaterializer.children(of: definition, context: context)
            .map { ($0.occurrenceKey!, $0.id) })
        let owed = Set((1...20).map { key(1, $0) })
        let thursdays = Set(RecurrenceEngine.occurrenceDayKeys(for: RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(1, 1)),
                                                               from: date(1, 21), through: date(3, 21), calendar: c))   // today + 60
        #expect(Set(now.keys) == owed.union(thursdays), "exact: every day through today, then Thursdays")
        for (slot, id) in early { #expect(now[slot] == id, "\(slot) kept its identity") }
    }

    @Test("A rule change re-plans far-future occurrences already generated, keeping matching ones")
    func farFutureReconciliation() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let c = cal()
        let seed = TaskItem(title: "Daily", dayKey: key(1, 1))
        context.insert(seed)
        let definition = try RecurrenceMaterializer.startSeries(from: seed, rule: RecurrenceRule(frequency: .daily, startDate: date(1, 1)),
                                                                through: date(7, 31), context: context, calendar: c)
        try context.save()
        let worked = try #require(try RecurrenceMaterializer.children(of: definition, context: context).first { $0.occurrenceKey == key(7, 1) })
        worked.notes = "July plan"
        worked.markOccurrenceModified()
        try context.save()
        let before = Dictionary(uniqueKeysWithValues: try RecurrenceMaterializer.children(of: definition, context: context)
            .map { ($0.occurrenceKey!, $0.id) })

        // Edited near today, asking only for the next weeks: the whole generated range is reconciled.
        let weekly = RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(1, 1))
        try RecurrenceMaterializer.changeRule(of: definition, to: weekly, today: date(1, 5), through: date(1, 20), context: context, calendar: c)
        try context.save()
        try RecurrenceMaterializer.materialize(context: context, through: date(7, 31), calendar: c)   // revisiting July
        let after = Dictionary(uniqueKeysWithValues: try RecurrenceMaterializer.children(of: definition, context: context)
            .map { ($0.occurrenceKey!, $0.id) })
        let thursdays = Set(RecurrenceEngine.occurrenceDayKeys(for: weekly, from: date(1, 6), through: date(7, 31), calendar: c))
        let history = Set((1...5).map { key(1, $0) })
        #expect(Set(after.keys) == history.union(thursdays).union([key(7, 1)]), "exact far-future contents")
        for slot in thursdays { #expect(after[slot] == before[slot], "matching \(slot) kept its identity") }
        #expect(after[key(7, 1)] == worked.id, "worked-on July occurrence kept")
    }

    // MARK: - 6. Purges and list deletion never resurrect — through restore, generation, reopen

    @Test("Purged and list-deleted occurrences stay gone through restore, generation, and reopening")
    func noResurrection() throws {
        let dir = try diskDir(), restoredDir = try diskDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: restoredDir) }
        let c = cal()
        var gone: Set<UUID> = [], goneSlots: Set<String> = [], survivors: [UUID: TaskRow] = [:]
        let file: Data
        do {
            let context = try open(dir)
            let f = try fixture(context)
            let purgeSlots = [key(1, 1), key(1, 15), key(1, 9), key(1, 11)]   // first, later, moved, listed
            for slot in purgeSlots { f.byKey[slot]!.setDone(true, at: date(1, 1)) }
            let laterList = CustomList(name: "Later", sortIndex: 2)
            context.insert(laterList)
            try context.save()
            try DataService(context).dropTask(f.byKey[key(1, 16)]!.id, into: .customList(laterList), before: nil, siblings: [])
            let weekly = try #require(try RecurrenceMaterializer.children(of: f.other, context: context).first { $0.occurrenceKey == key(1, 9) })
            try DataService(context).dropTask(weekly.id, into: .customList(laterList), before: nil, siblings: laterList.tasks)
            let listOneOff = TaskItem(title: "list one-off", customList: laterList)
            context.insert(listOneOff)
            try context.save()
            gone = Set(purgeSlots.map { f.byKey[$0]!.id } + [f.byKey[key(1, 16)]!.id, weekly.id, listOneOff.id])
            goneSlots = Set(purgeSlots.map { "\(f.definition.id)#\($0)" } + ["\(f.definition.id)#\(key(1, 16))", "\(f.other.id)#\(key(1, 9))"])

            AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 3, now: date(1, 20))
            try DataService(context).delete(laterList)
            let g = try graph(context)
            #expect(gone.isDisjoint(with: g.tasks.keys), "exactly the purged and list-deleted rows are gone")
            survivors = g.tasks.filter { $0.value.notes == "jan3 notes" || $0.value.notes == "jan7 rich" || $0.key == f.oneOff.id }
            #expect(survivors.count == 3)
            file = try BackupService().makeFile(store: try BackupStore.makeSnapshot(context: context), passphrase: nil)
        }
        func check(_ context: ModelContext, _ stage: String) throws {
            try RecurrenceMaterializer.materialize(context: context, through: date(2, 28), calendar: c)
            let g = try graph(context)
            #expect(gone.isDisjoint(with: g.tasks.keys), "\(stage): no purged row back")
            let slots = Set(g.tasks.values.compactMap { r in r.templateID.flatMap { id in r.occurrenceKey.map { "\(id)#\($0)" } } })
            #expect(goneSlots.isDisjoint(with: slots), "\(stage): no deleted slot regenerated")
            for (id, row) in survivors { #expect(g.tasks[id] == row, "\(stage): survivor \(row.title) untouched") }
        }
        try check(try open(dir), "reopened")
        do {
            let context = try open(restoredDir)
            try BackupStore.restore(try BackupService().readFile(file, passphrase: nil), context: context)
            try check(context, "restored")
        }
        try check(try open(restoredDir), "restored and reopened")
    }

    // MARK: - 7. Reminders follow moves, series-wide time/alarm edits, and purges exactly

    final class PendingClient: NotificationScheduling {
        var pending: [String: TaskReminder] = [:]
        func isAuthorized() async -> Bool { true }
        func pendingIdentifiers() async -> [String] { Array(pending.keys) }
        func remove(_ identifiers: [String]) { identifiers.forEach { pending.removeValue(forKey: $0) } }
        func add(_ reminder: TaskReminder) async throws { pending[reminder.identifier] = reminder }
    }

    @Test("Reminder requests match the store exactly after moves, shared time/alarm edits, and purges")
    func reminderLifecycle() async throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let f = try fixture(context)
        let now = date(1, 5)
        let client = PendingClient()
        func matches() async throws -> Bool {
            await NotificationService.syncTaskReminders(context: context, client: client, now: now)
            let planned = ReminderPlanner.reminders(for: try context.fetch(FetchDescriptor<TaskItem>()), now: now)
            return Dictionary(uniqueKeysWithValues: planned.map { ($0.identifier, $0) }) == client.pending
        }
        #expect(try await matches())
        let jan6 = f.byKey[key(1, 6)]!
        let id = ReminderPlanner.identifierPrefix + jan6.id.uuidString

        try DataService(context).dropTask(jan6.id, into: .day(key(1, 12)), before: nil, siblings: [])
        #expect(try await matches())
        #expect(client.pending[id]?.fireDate.day == 12, "a dated move reschedules")

        var later = SharedAttributes(jan6)
        later.timeMinutes = 600
        try TaskEditCommit.commit(TaskEdit(originalShared: SharedAttributes(jan6), editedShared: later), to: jan6,
                                  context: context, horizon: date(1, 31))
        #expect(try await matches())
        let standupHours = Set(client.pending.values.filter { $0.title == "Standup" }.map(\.fireDate.hour))
        #expect(standupHours == [10], "the series-wide time reached every reminder")

        var silent = SharedAttributes(jan6)
        silent.alarmEnabled = false
        try TaskEditCommit.commit(TaskEdit(originalShared: SharedAttributes(jan6), editedShared: silent), to: jan6,
                                  context: context, horizon: date(1, 31))
        #expect(try await matches())
        #expect(!client.pending.values.contains { $0.title == "Standup" }, "turning the series' alarm off cancels them all")

        f.oneOff.timeMinutes = 480
        f.oneOff.alarmEnabled = true
        f.byKey[key(1, 8)]!.setDone(true, at: date(1, 1))
        try context.save()
        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 2, now: now)
        #expect(try await matches(), "after a purge")
        #expect(client.pending[ReminderPlanner.identifierPrefix + f.oneOff.id.uuidString] != nil)
    }
}

/// Contexts whose failed change the app would discard by quitting; kept alive for the
/// rest of the run, because releasing a container with unsaved changes crashes SwiftData.
@MainActor
enum DiscardedContexts {
    private static var all: [ModelContext] = []
    static func keep(_ context: ModelContext) { all.append(context) }
}
