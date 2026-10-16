import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Series lifecycle under the hidden-definition model: moves, deletions, normalization,
/// and integrations with auto-delete, carry-forward, search, and weekly summary.
@MainActor
@Suite("Series lifecycle")
struct SeriesLifecycleTests {
    private func makeContext() -> ModelContext {
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

    private func dayKey(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d%02d%02d", y, m, d)
    }

    /// Start a daily series on 2026-01-01 through the given date.
    @discardableResult
    private func startDaily(_ context: ModelContext, _ c: Calendar, end: RecurrenceEnd = .never,
                            through horizon: (Int, Int, Int) = (2026, 1, 10)) throws -> (seed: TaskItem, definition: TaskItem) {
        let seed = TaskItem(title: "Water plants", dayKey: dayKey(2026, 1, 1), timeMinutes: 540, priority: 2, alarmEnabled: true)
        seed.isCritical = true
        seed.notes = "seed notes"
        context.insert(seed)
        let rule = RecurrenceRule(frequency: .daily, end: end, startDate: date(2026, 1, 1, c))
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: rule, through: date(horizon.0, horizon.1, horizon.2, c), context: context, calendar: c)
        try context.save()
        return (seed, definition)
    }

    private func occurrences(of definition: TaskItem, _ context: ModelContext) throws -> [TaskItem] {
        try RecurrenceMaterializer.children(of: definition, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }
    }

    private func allTasks(_ context: ModelContext) throws -> [TaskItem] {
        try context.fetch(FetchDescriptor<TaskItem>()).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - Section 1: Moves via DataService.dropTask

    @Test("Move from day to day preserves occurrence ID, key, notes, subtasks, and completion")
    func movePreservesPayload() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })
        jan3.notes = "jan3 notes"
        let sub = Subtask(title: "Check soil")
        jan3.subtasks.append(sub)
        sub.parent = jan3
        jan3.setDone(true)
        try context.save()

        let jan3ID = jan3.id
        let subID = sub.id
        let jan4Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 4) }
        try DataService(context).dropTask(jan3ID, into: .day(dayKey(2026, 1, 4)), before: nil, siblings: jan4Tasks)

        let moved = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == jan3ID })
        #expect(moved.occurrenceKey == dayKey(2026, 1, 3))
        #expect(moved.dayKey == dayKey(2026, 1, 4))
        #expect(moved.notes == "jan3 notes")
        #expect(moved.isDone)
        #expect(moved.subtasks.count == 1)
        #expect(moved.subtasks.first?.id == subID)
        #expect(moved.occurrenceModified == true)
    }

    @Test("Move date→date→list→date: source slot never regenerates")
    func moveMultipleTimes() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c, through: (2026, 1, 31))
        var jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })
        let jan3ID = jan3.id

        // Move: Jan 3 → Jan 5
        var jan5Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(jan3ID, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: jan5Tasks)
        jan3 = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == jan3ID })
        #expect(jan3.occurrenceKey == dayKey(2026, 1, 3) && jan3.dayKey == dayKey(2026, 1, 5))

        // Move: Jan 5 → list
        let list = try DataService(context).addCustomList(name: "Inbox")
        try DataService(context).dropTask(jan3ID, into: .customList(list), before: nil, siblings: list.tasks)
        jan3 = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == jan3ID })
        #expect(jan3.occurrenceKey == dayKey(2026, 1, 3) && jan3.customList?.id == list.id && jan3.dayKey == nil)

        // Move: list → Jan 7
        let jan7Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 7) }
        try DataService(context).dropTask(jan3ID, into: .day(dayKey(2026, 1, 7)), before: nil, siblings: jan7Tasks)
        jan3 = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == jan3ID })
        #expect(jan3.occurrenceKey == dayKey(2026, 1, 3) && jan3.dayKey == dayKey(2026, 1, 7) && jan3.customList == nil)

        // Materialize: Jan 3 is not regenerated; Jan 5 and original Jan 3 natural occurrence are both gone
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)
        let kids = try occurrences(of: definition, context)
        #expect(!kids.contains { $0.occurrenceKey == dayKey(2026, 1, 3) && $0.dayKey == dayKey(2026, 1, 3) })
        #expect(!kids.contains { $0.occurrenceKey == dayKey(2026, 1, 5) })
    }

    @Test("Move back to its own slot: the occurrence keeps its natural location")
    func moveBackToOriginalSlot() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })
        let jan3ID = jan3.id

        var jan5Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(jan3ID, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: jan5Tasks)

        let jan3Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 3) }
        try DataService(context).dropTask(jan3ID, into: .day(dayKey(2026, 1, 3)), before: nil, siblings: jan3Tasks)

        let back = try #require(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == jan3ID }.first)
        #expect(back.dayKey == dayKey(2026, 1, 3) && back.occurrenceKey == dayKey(2026, 1, 3))
    }

    @Test("Reorder within same day: occurrence remains, sortIndex updates, no slot regeneration")
    func reorderWithinDay() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan2 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 2) })
        let jan2ID = jan2.id
        jan2.notes = "jan2 work"
        try context.save()

        let jan2Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 2) }
        try DataService(context).dropTask(jan2ID, into: .day(dayKey(2026, 1, 2)), before: nil, siblings: jan2Tasks)

        let reordered = try #require(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == jan2ID }.first)
        #expect(reordered.dayKey == dayKey(2026, 1, 2) && reordered.occurrenceKey == dayKey(2026, 1, 2))
        #expect(reordered.notes == "jan2 work")
        #expect(reordered.occurrenceModified == true)
    }

    @Test("Two slots onto one day: both exist as separate rows")
    func moveMultipleSlotsOntoDay() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })
        let jan4 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 4) })

        // Move Jan 3 → Jan 5
        var jan5Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(jan3.id, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: jan5Tasks)

        // Move Jan 4 → Jan 5
        jan5Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(jan4.id, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: jan5Tasks)

        let jan5All = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        #expect(jan5All.contains { $0.occurrenceKey == dayKey(2026, 1, 3) })
        #expect(jan5All.contains { $0.occurrenceKey == dayKey(2026, 1, 4) })
        #expect(jan5All.count == 3)   // 2 moved + Jan 5's own

        // Materialize: both maintain their occurrence keys; Jan 5 original is still generated
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)
        let kids = try occurrences(of: definition, context)
        #expect(kids.filter { $0.dayKey == dayKey(2026, 1, 5) }.count == 3)
        #expect(kids.contains { $0.occurrenceKey == dayKey(2026, 1, 5) })
    }

    @Test("Destination's own natural occurrence is still generated independently")
    func moveDoesNotSuppressDestinationSlot() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })

        var jan5Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(jan3.id, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: jan5Tasks)

        let jan5All = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        let hasNatural = jan5All.contains { $0.occurrenceKey == dayKey(2026, 1, 5) }
        #expect(hasNatural)
    }

    @Test("Moved occurrence's siblings' provenance unchanged by move")
    func siblingProvenanceUnchanged() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })
        let jan4 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 4) })

        let jan4Original = jan4.occurrenceModified
        var jan5Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(jan3.id, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: jan5Tasks)

        let jan4After = try #require(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == jan4.id }.first)
        #expect(jan4After.occurrenceModified == jan4Original)
    }

    @Test("Legacy keyless dated row: backfilled on first move")
    func legacyKeylessBackfilled() throws {
        let context = makeContext()
        let c = cal()
        // Create a legacy root with a day, no rule, no key
        let legacy = TaskItem(title: "Legacy", dayKey: dayKey(2026, 1, 1))
        legacy.occurrenceKey = nil
        legacy.occurrenceModified = nil
        context.insert(legacy)
        try context.save()

        // Move it
        let destinations = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(legacy.id, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: destinations)

        let moved = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == legacy.id })
        #expect(moved.occurrenceKey == dayKey(2026, 1, 1))
        #expect(moved.dayKey == dayKey(2026, 1, 5))
        #expect(moved.occurrenceModified == true)
    }

    // MARK: - Section 2: Deleting moved occurrences

    @Test("Delete a moved dated occurrence: skip the original slot, not the current location")
    func deleteMovedDatedSkipsOriginal() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })
        let jan3ID = jan3.id

        var jan5Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(jan3ID, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: jan5Tasks)

        let movedToDelete = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == jan3ID })
        try RecurrenceMaterializer.deleteOccurrence(movedToDelete, context: context)

        let kids = try occurrences(of: definition, context)
        #expect(!kids.contains { $0.occurrenceKey == dayKey(2026, 1, 3) })
        #expect(kids.contains { $0.occurrenceKey == dayKey(2026, 1, 5) })
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == dayKey(2026, 1, 3) })
    }

    @Test("Delete a moved listed occurrence: skip its original slot")
    func deleteMovedListedSkipsOriginal() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })
        let jan3ID = jan3.id

        let list = try DataService(context).addCustomList(name: "Inbox")
        try DataService(context).dropTask(jan3ID, into: .customList(list), before: nil, siblings: [])

        let movedToDelete = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == jan3ID })
        try RecurrenceMaterializer.deleteOccurrence(movedToDelete, context: context)

        let kids = try occurrences(of: definition, context)
        #expect(!kids.contains { $0.occurrenceKey == dayKey(2026, 1, 3) })
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == dayKey(2026, 1, 3) })
    }

    @Test("Destination's natural occurrence untouched after moved occurrence deleted and re-materialized")
    func destinationOccurrenceUntouchedAfterDelete() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c, through: (2026, 1, 31))
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })
        let jan3ID = jan3.id

        // Jan 5's natural occurrence exists; move Jan 3 there
        let jan5Natural = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 5) })
        jan5Natural.notes = "jan5 notes"
        let jan5NaturalID = jan5Natural.id
        try context.save()

        var jan5Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(jan3ID, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: jan5Tasks)

        // Delete the moved Jan 3
        let moved = try #require(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == jan3ID }.first)
        try RecurrenceMaterializer.deleteOccurrence(moved, context: context)

        // Re-materialize
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)

        // Verify Jan 5's natural occurrence is still there with its work
        let jan5Final = try #require(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == jan5NaturalID }.first)
        #expect(jan5Final.notes == "jan5 notes")
        #expect(jan5Final.occurrenceKey == dayKey(2026, 1, 5))
    }

    // MARK: - Section 3: Deleting first occurrence with various next states

    @Test("Delete first occurrence when next is open: next stays with its work")
    func deleteFirstWhenNextOpen() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c)
        let next = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 2) })
        next.notes = "next work"
        let nextID = next.id
        try context.save()

        try RecurrenceMaterializer.deleteOccurrence(seed, context: context)

        let kept = try #require(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == nextID }.first)
        #expect(kept.notes == "next work")
        #expect(kept.occurrenceKey == dayKey(2026, 1, 2))
        #expect(try occurrences(of: definition, context).count >= 1)
    }

    @Test("Delete first occurrence when next is skipped: next stays skipped")
    func deleteFirstWhenNextSkipped() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c)
        let next = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 2) })

        try RecurrenceMaterializer.deleteOccurrence(next, context: context)
        try context.save()

        try RecurrenceMaterializer.deleteOccurrence(seed, context: context)

        let kids = try occurrences(of: definition, context)
        #expect(!kids.contains { $0.occurrenceKey == dayKey(2026, 1, 2) })
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == dayKey(2026, 1, 2) })
    }

    @Test("Delete first occurrence when next is done: next stays done")
    func deleteFirstWhenNextDone() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c)
        let next = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 2) })
        next.setDone(true)
        let nextID = next.id
        try context.save()

        try RecurrenceMaterializer.deleteOccurrence(seed, context: context)

        let kept = try #require(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == nextID }.first)
        #expect(kept.isDone)
        #expect(kept.occurrenceKey == dayKey(2026, 1, 2))
    }

    @Test("Delete first occurrence when next is moved: next stays moved with its slot preserved")
    func deleteFirstWhenNextMoved() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c)
        let next = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 2) })
        let nextID = next.id

        var jan5Tasks = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == dayKey(2026, 1, 5) }
        try DataService(context).dropTask(nextID, into: .day(dayKey(2026, 1, 5)), before: nil, siblings: jan5Tasks)

        try RecurrenceMaterializer.deleteOccurrence(seed, context: context)

        let kept = try #require(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == nextID }.first)
        #expect(kept.occurrenceKey == dayKey(2026, 1, 2) && kept.dayKey == dayKey(2026, 1, 5))
    }

    @Test("Delete first occurrence when next is absent (deleted): series not deleted")
    func deleteFirstWhenNextAbsent() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c)
        let next = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 2) })
        let nextID = next.id
        try RecurrenceMaterializer.deleteOccurrence(next, context: context)
        try context.save()

        try RecurrenceMaterializer.deleteOccurrence(seed, context: context)

        #expect(try RecurrenceMaterializer.definition(for: definition, context: context) != nil)
        #expect(definition.recurrence != nil)
    }

    // MARK: - Section 4: Last/only/sparse occurrence deletion

    @Test("Delete the only occurrence: series kept, slot skipped")
    func deleteOnlyOccurrence() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c, end: .afterCount(1))
        let seedID = seed.id

        try RecurrenceMaterializer.deleteOccurrence(seed, context: context)

        #expect(try RecurrenceMaterializer.definition(for: definition, context: context) != nil)
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == dayKey(2026, 1, 1) })
        #expect(!(try occurrences(of: definition, context)).contains { $0.id == seedID })
    }

    @Test("Delete all remaining slots when sparse: no implicit series deletion")
    func deleteAllRemainingSparse() throws {
        let context = makeContext()
        let c = cal()
        let seed = TaskItem(title: "Review", dayKey: dayKey(2026, 1, 1))
        context.insert(seed)
        let rule = RecurrenceRule(frequency: .weekly, weekdays: [5], end: .afterCount(2),
                                  startDate: date(2026, 1, 1, c))
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: rule, through: date(2026, 2, 28, c), context: context, calendar: c)
        try context.save()

        // Should be Jan 1, Jan 8
        let kids = try occurrences(of: definition, context)
        #expect(kids.count == 2)
        for kid in kids {
            try RecurrenceMaterializer.deleteOccurrence(kid, context: context)
        }

        #expect(try RecurrenceMaterializer.definition(for: definition, context: context) != nil)
    }

    @Test("Feb 29 yearly series across leap-century gap: deletion doesn't trigger false regeneration")
    func deleteLeapYearlyAcrossCentury() throws {
        let context = makeContext()
        let c = cal()
        let seed = TaskItem(title: "Leap day", dayKey: dayKey(2024, 2, 29))
        context.insert(seed)
        let rule = RecurrenceRule(frequency: .yearly, end: .afterCount(10),
                                  startDate: date(2024, 2, 29, c))
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: rule, through: date(2104, 2, 28, c), context: context, calendar: c)
        try context.save()

        let kids = try occurrences(of: definition, context)
        #expect(kids.count > 0)
        if let first = kids.first {
            let firstID = first.id
            try RecurrenceMaterializer.deleteOccurrence(first, context: context)
            #expect(!(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == firstID }.isEmpty))
            #expect(try RecurrenceMaterializer.definition(for: definition, context: context) != nil)
        }
    }

    @Test("Delete a legacy keyless row: deletes only it, no skip record, no series deletion")
    func deleteKeylessLegacyRow() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        // Insert a legacy row with templateID but no key
        let legacy = TaskItem(title: "Water plants")
        legacy.notes = "legacy"
        legacy.templateID = definition.id
        legacy.occurrenceKey = nil
        legacy.occurrenceModified = nil
        context.insert(legacy)
        try context.save()

        try RecurrenceMaterializer.deleteOccurrence(legacy, context: context)

        #expect(!(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == legacy.id }.isEmpty))
        #expect(!definition.occurrences.contains { $0.skipped && $0.dayKey == nil })
        #expect(try RecurrenceMaterializer.definition(for: definition, context: context) != nil)
    }

    @Test("Deleting a definition directly throws notAnOccurrence")
    func deleteDefinitionThrows() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)

        #expect(throws: RecurrenceMaterializer.LifecycleError.notAnOccurrence) {
            try RecurrenceMaterializer.deleteOccurrence(definition, context: context)
        }
    }

    // MARK: - Section 5: Whole-series deletion

    @Test("Delete series removes definition, every linked occurrence in any location, and skip records")
    func deleteSeriesRemovesAll() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c, end: .afterCount(5), through: (2026, 1, 31))
        let list = try DataService(context).addCustomList(name: "Inbox")
        let jan2 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 2) })
        try DataService(context).dropTask(jan2.id, into: .customList(list), before: nil, siblings: [])

        let definitionID = definition.id
        try RecurrenceMaterializer.deleteSeries(seed, context: context)

        #expect((try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == definitionID }.isEmpty))
        #expect((try context.fetch(FetchDescriptor<TaskOccurrence>()).isEmpty))
    }

    @Test("Unrelated same-title task and series are left untouched")
    func deleteSeriesLeavesUnrelated() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c)
        let unrelated = TaskItem(title: "Water plants", dayKey: dayKey(2026, 1, 1))
        context.insert(unrelated)
        try context.save()

        try RecurrenceMaterializer.deleteSeries(seed, context: context)

        let remaining = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(remaining.contains { $0.id == unrelated.id })
        #expect(!remaining.contains { $0.id == definition.id })
    }

    @Test("Delete orphaned occurrence (template missing): deletes only it")
    func deleteOrphanedOccurrence() throws {
        let context = makeContext()
        let c = cal()
        // Create a real series first so we have proper relationships
        let (_, definition) = try startDaily(context, c, end: .afterCount(3))
        let orphan = TaskItem(title: "Orphaned", dayKey: dayKey(2026, 1, 15))
        orphan.templateID = UUID()   // No matching definition
        orphan.occurrenceKey = dayKey(2026, 1, 15)
        context.insert(orphan)
        try context.save()

        try RecurrenceMaterializer.deleteOccurrence(orphan, context: context)

        let remaining = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(!remaining.contains { $0.id == orphan.id })
        #expect(remaining.contains { $0.id == definition.id })
    }

    // MARK: - Section 6: Custom-list deletion

    @Test("Delete list holding series occurrences: skip records written, series continues elsewhere")
    func deleteListWithSeriesOccurrences() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c, through: (2026, 1, 15))
        let list = try DataService(context).addCustomList(name: "Inbox")
        let jan4 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 4) })
        let jan5 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 5) })
        try DataService(context).dropTask(jan4.id, into: .customList(list), before: nil, siblings: [])
        try DataService(context).dropTask(jan5.id, into: .customList(list), before: nil, siblings: list.tasks)

        try DataService(context).delete(list)

        // Occurrences should be skipped; definition should remain
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == dayKey(2026, 1, 4) })
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == dayKey(2026, 1, 5) })
        #expect(try RecurrenceMaterializer.definition(for: definition, context: context) != nil)

        // No orphans; series continues
        let allTasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(allTasks.contains { $0.id == definition.id })
    }

    @Test("Delete list with mixed tasks: only series occurrences skipped")
    func deleteListWithMixedTasks() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let list = try DataService(context).addCustomList(name: "Inbox")
        let oneOff = TaskItem(title: "One-off", customList: list)
        context.insert(oneOff)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 3) })
        try DataService(context).dropTask(jan3.id, into: .customList(list), before: nil, siblings: [])
        try context.save()

        try DataService(context).delete(list)

        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == dayKey(2026, 1, 3) })
    }

    // MARK: - Section 7: AutoDeleteService.purgeCompleted

    @Test("Auto-delete purges completed series occurrence and skips its slot")
    func autoDeletePurgesCompletedOccurrence() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan2 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 2) })
        jan2.setDone(true, at: date(2026, 1, 2, c))
        try context.save()

        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 7, now: date(2026, 1, 20, c))

        let remaining = try occurrences(of: definition, context)
        #expect(!remaining.contains { $0.occurrenceKey == dayKey(2026, 1, 2) })
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == dayKey(2026, 1, 2) })
    }

    @Test("Auto-delete never purges definitions")
    func autoDeleteNeverPurgesDefinition() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)

        // Artificially mark definition as done (shouldn't happen, but let's test safety)
        definition.setDone(true, at: date(2026, 1, 1, c))
        try context.save()

        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 0, now: date(2026, 2, 1, c))

        #expect(try RecurrenceMaterializer.definition(for: definition, context: context) != nil)
    }

    @Test("Auto-delete skips keyless legacy completed occurrences")
    func autoDeleteSkipsKeylessLegacy() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let legacy = TaskItem(title: "Water plants")
        legacy.templateID = definition.id
        legacy.occurrenceKey = nil
        legacy.occurrenceModified = nil
        legacy.setDone(true, at: date(2026, 1, 1, c))
        context.insert(legacy)
        try context.save()

        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 0, now: date(2026, 2, 1, c))

        #expect(!(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == legacy.id }.isEmpty))
    }

    // MARK: - Section 8: Carry-forward

    @Test("Carry-forward excludes active series occurrences")
    func carryForwardExcludesActiveSeries() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan1 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 1) })

        let moved = try BehaviorService.carryForwardIncomplete(
            context: context, targetKey: dayKey(2026, 1, 10))
        #expect(moved == 0)
        let afterCarry = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == jan1.id }
        #expect(afterCarry.first?.dayKey == dayKey(2026, 1, 1))
    }

    @Test("Carry-forward excludes definitions")
    func carryForwardExcludesDefinitions() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)

        let moved = try BehaviorService.carryForwardIncomplete(
            context: context, targetKey: dayKey(2026, 1, 10))
        #expect(moved == 0)
    }

    @Test("Carry-forward moves unrelated non-recurring incomplete tasks only")
    func carryForwardMovesNonRecurring() throws {
        let context = makeContext()
        let c = cal()
        let oneOff = TaskItem(title: "One-off", dayKey: dayKey(2026, 1, 1))
        context.insert(oneOff)
        try context.save()

        let moved = try BehaviorService.carryForwardIncomplete(
            context: context, targetKey: dayKey(2026, 1, 10))
        #expect(moved == 1)
        let carried = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == oneOff.id }
        #expect(carried.first?.dayKey == dayKey(2026, 1, 10))
    }

    // MARK: - Section 9: Search

    @Test("Search excludes definitions, includes occurrences by day/list")
    func searchExcludesDefinitions() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c, through: (2026, 1, 31))

        let results = TaskSearch.rank(try allTasks(context).filter { $0.dayKey != nil || $0.customList != nil }, query: "Water")
        #expect(!results.contains { $0.id == definition.id })
        #expect(results.contains { $0.templateID == definition.id })
    }

    @Test("Unique note tokens match only their occurrence in a series")
    func searchOccurrenceNotesUnique() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan1 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 1) })
        let jan2 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == dayKey(2026, 1, 2) })

        jan1.notes = "unique_for_jan1"
        jan2.notes = "unique_for_jan2"
        try context.save()

        let resultsJan1 = TaskSearch.rank(try allTasks(context).filter { $0.dayKey != nil || $0.customList != nil },
                                          query: "unique_for_jan1")
        let resultsJan2 = TaskSearch.rank(try allTasks(context).filter { $0.dayKey != nil || $0.customList != nil },
                                          query: "unique_for_jan2")

        #expect(resultsJan1.contains { $0.id == jan1.id } && !resultsJan1.contains { $0.id == jan2.id })
        #expect(resultsJan2.contains { $0.id == jan2.id } && !resultsJan2.contains { $0.id == jan1.id })
    }

    // MARK: - Section 10: Weekly Summary

    @Test("Weekly Summary groups occurrences by definition UUID")
    func summaryGroupsByDefinitionId() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c, through: (2026, 1, 31))
        let kids = try occurrences(of: definition, context)

        let snapshots = kids.map { SummaryTaskSnapshot($0) }
        let keys = Set(snapshots.compactMap(\.seriesID))
        #expect(keys.count == 1)
        #expect(keys.contains(definition.id))
    }

    @Test("Definition excluded from week selection (has no dayKey)")
    func summaryExcludesDefinition() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)

        let allSnapshots = try allTasks(context).map { SummaryTaskSnapshot($0) }
        let weekFiltered = allSnapshots.filter { $0.dayKey != "" }
        #expect(!weekFiltered.contains { $0.id == definition.id })
    }

    @Test("Unrelated series with same title get different keys")
    func summaryDifferentSeriesSameTitle() throws {
        let context = makeContext()
        let c = cal()
        let (_, def1) = try startDaily(context, c, through: (2026, 1, 31))

        // Create another daily series with same title, different definition
        let seed2 = TaskItem(title: "Water plants", dayKey: dayKey(2026, 2, 1), timeMinutes: 600)
        context.insert(seed2)
        let def2 = try RecurrenceMaterializer.startSeries(
            from: seed2, rule: RecurrenceRule(frequency: .daily, startDate: date(2026, 2, 1, c)),
            through: date(2026, 2, 28, c), context: context, calendar: c)
        try context.save()

        let snap1 = SummaryTaskSnapshot(def1)
        let snap2 = SummaryTaskSnapshot(def2)
        #expect(snap1.seriesID != snap2.seriesID)
    }

    // MARK: - Section 11: Normalization interplay

    @Test("Materialize on a store with legacy root splits it before generating")
    func normalizationBeforeMaterialize() throws {
        let context = makeContext()
        let c = cal()
        // Create a legacy root with recurrence and dayKey (pre-v0.1.17 shape)
        let root = TaskItem(title: "Legacy series", dayKey: dayKey(2026, 1, 1), recurrence:
            RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c)))
        root.notes = "root notes"
        let sub = Subtask(title: "Root sub")
        root.subtasks.append(sub)
        context.insert(root)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)

        let allTasks = try context.fetch(FetchDescriptor<TaskItem>())
        let definitions = allTasks.filter { $0.recurrence != nil }
        let occurrences = allTasks.filter { $0.templateID != nil }

        #expect(definitions.count == 1)
        #expect(definitions.first?.dayKey == nil)
        #expect(definitions.first?.notes.isEmpty == true)
        #expect(occurrences.count >= 1)
        let firstOccurrence = occurrences.first { $0.occurrenceKey == dayKey(2026, 1, 1) }
        #expect(firstOccurrence?.notes == "root notes")
    }

    @Test("Normalize twice idempotently, with no added duplicate first occurrence")
    func normalizationIdempotent() throws {
        let context = makeContext()
        let c = cal()
        let root = TaskItem(title: "Legacy", dayKey: dayKey(2026, 1, 1),
                           recurrence: RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c)))
        context.insert(root)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)
        let firstPass = try context.fetch(FetchDescriptor<TaskItem>())
        let countFirst = firstPass.count

        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)
        let secondPass = try context.fetch(FetchDescriptor<TaskItem>())
        let countSecond = secondPass.count

        #expect(countFirst == countSecond)
    }
}
