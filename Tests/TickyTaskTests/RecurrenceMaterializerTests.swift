import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// The series lifecycle on the hidden-definition model: every visible occurrence
/// (the first included) is a child row with a stable slot; the definition owns the
/// rule, the shared attributes, and the skip records.
@MainActor
@Suite("RecurrenceMaterializer")
struct RecurrenceMaterializerTests {
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

    /// A dated one-off on 2026-01-01 turned into a daily series through `horizon`.
    @discardableResult
    private func startDaily(_ context: ModelContext, _ c: Calendar, end: RecurrenceEnd = .never,
                            through horizon: (Int, Int, Int) = (2026, 1, 10)) throws -> (seed: TaskItem, definition: TaskItem) {
        let seed = TaskItem(title: "Water plants", dayKey: "20260101", timeMinutes: 540, priority: 2, alarmEnabled: true)
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

    @Test("Starting a series keeps the seed as the first occurrence and hides the definition")
    func startSeriesShape() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c, end: .afterCount(5), through: (2026, 1, 31))

        #expect(definition.recurrence != nil && definition.templateID == nil)
        #expect(definition.dayKey == nil && definition.customList == nil)
        #expect(definition.notes.isEmpty && definition.subtasks.isEmpty && !definition.isDone)
        #expect(seed.templateID == definition.id && seed.recurrence == nil)
        #expect(seed.occurrenceKey == "20260101" && seed.occurrenceModified == true)
        #expect(seed.notes == "seed notes")
        let kids = try occurrences(of: definition, context)
        #expect(kids.map { $0.occurrenceKey ?? "" } == ["20260101", "20260102", "20260103", "20260104", "20260105"])
        let generated = try #require(kids.first { $0.occurrenceKey == "20260102" })
        #expect(generated.title == "Water plants" && generated.timeMinutes == 540 && generated.priority == 2)
        #expect(generated.isCritical && generated.alarmEnabled)
        #expect(generated.notes.isEmpty && generated.notesRich == nil && generated.subtasks.isEmpty)
        #expect(generated.occurrenceModified == false && generated.dayKey == "20260102")
    }

    @Test("Materialize is idempotent")
    func idempotent() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c, end: .afterCount(5), through: (2026, 1, 31))
        let again = try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)
        #expect(again == 0)
        #expect(try occurrences(of: definition, context).count == 5)
    }

    @Test("A deleted occurrence is skipped and never regenerated; others are untouched")
    func deleteOccurrenceSkips() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == "20260103" })
        try RecurrenceMaterializer.deleteOccurrence(jan3, context: context)
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)

        let keys = try occurrences(of: definition, context).compactMap(\.occurrenceKey)
        #expect(!keys.contains("20260103"))
        #expect(keys.contains("20260101") && keys.contains("20260104"))
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == "20260103" })
        #expect(seed.notes == "seed notes")
    }

    @Test("Deleting the first occurrence moves nothing and keeps the next occurrence's work")
    func deleteFirstOccurrence() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c)
        let next = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == "20260102" })
        next.notes = "next notes"
        next.subtasks.append(Subtask(title: "next sub"))
        next.setDone(true)
        try context.save()
        let nextID = next.id

        try RecurrenceMaterializer.deleteOccurrence(seed, context: context)

        let kids = try occurrences(of: definition, context)
        #expect(!kids.contains { $0.occurrenceKey == "20260101" })
        let kept = try #require(kids.first { $0.id == nextID })
        #expect(kept.notes == "next notes" && kept.isDone && kept.subtasks.map(\.title) == ["next sub"])
        #expect(kept.dayKey == "20260102")
        #expect(definition.recurrence != nil)
    }

    @Test("Deleting the only occurrence never deletes the series")
    func deleteOnlyOccurrence() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c, end: .afterCount(1))
        try RecurrenceMaterializer.deleteOccurrence(seed, context: context)
        #expect(try RecurrenceMaterializer.definition(for: definition, context: context) != nil)
        #expect(try occurrences(of: definition, context).isEmpty)
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == "20260101" })
    }

    @Test("A moved occurrence keeps its slot: the source day is not regenerated")
    func moveKeepsSlot() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == "20260103" })
        let siblings = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.dayKey == "20260104" }
        try DataService(context).dropTask(jan3.id, into: .day("20260104"), before: nil, siblings: siblings)
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)

        let kids = try occurrences(of: definition, context)
        #expect(kids.filter { $0.dayKey == "20260103" }.isEmpty)
        #expect(kids.filter { $0.dayKey == "20260104" }.count == 2)   // the moved one + Jan 4's own
        #expect(jan3.occurrenceKey == "20260103" && jan3.occurrenceModified == true)
    }

    @Test("Deleting a moved occurrence skips its original slot, not where it sits")
    func deleteMovedSkipsOriginalSlot() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan3 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == "20260103" })
        try DataService(context).dropTask(jan3.id, into: .day("20260104"), before: nil, siblings: [])
        try RecurrenceMaterializer.deleteOccurrence(jan3, context: context)
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)

        let kids = try occurrences(of: definition, context)
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == "20260103" })
        #expect(!definition.occurrences.contains { $0.skipped && $0.dayKey == "20260104" })
        #expect(kids.filter { $0.dayKey == "20260104" }.count == 1)
        #expect(!kids.contains { $0.occurrenceKey == "20260103" })
    }

    @Test("Delete series removes the definition, every occurrence in any location, and skips")
    func deleteSeries() throws {
        let context = makeContext()
        let c = cal()
        let (seed, definition) = try startDaily(context, c, end: .afterCount(5), through: (2026, 1, 31))
        let list = try DataService(context).addCustomList(name: "Inbox")
        let jan2 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == "20260102" })
        try DataService(context).dropTask(jan2.id, into: .customList(list), before: nil, siblings: [])
        let unrelated = TaskItem(title: "Water plants", dayKey: "20260101")
        context.insert(unrelated)
        try context.save()

        try RecurrenceMaterializer.deleteSeries(seed, context: context)
        let remaining = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(remaining.map(\.id) == [unrelated.id])
        #expect(try context.fetch(FetchDescriptor<TaskOccurrence>()).isEmpty)
    }

    @Test("A rule change keeps past, done, and worked-on occurrences and removes only untouched future ones")
    func ruleChangeReconciles() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)   // Jan 1 … Jan 10
        let kids = try occurrences(of: definition, context)
        let jan7 = try #require(kids.first { $0.occurrenceKey == "20260107" })
        jan7.notes = "keep me"
        let jan9 = try #require(kids.first { $0.occurrenceKey == "20260109" })
        jan9.setDone(true)
        let jan6 = try #require(kids.first { $0.occurrenceKey == "20260106" })
        let jan6ID = jan6.id
        try context.save()

        // Daily → weekly on Thursdays (Jan 1 is a Thursday): Jan 8, 15, …
        let weekly = RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(2026, 1, 1, c))
        try RecurrenceMaterializer.changeRule(of: definition, to: weekly, today: date(2026, 1, 5, c),
                                              through: date(2026, 1, 31, c), context: context, calendar: c)
        try context.save()

        let keys = Set(try occurrences(of: definition, context).compactMap(\.occurrenceKey))
        #expect(keys.isSuperset(of: ["20260101", "20260102", "20260103", "20260104", "20260105"]))   // past/today kept
        #expect(keys.contains("20260107") && keys.contains("20260109"))   // notes / done kept
        #expect(!keys.contains("20260106") && !keys.contains("20260110"))   // untouched future removed
        #expect(keys.contains("20260108") && keys.contains("20260115") && keys.contains("20260129"))
        #expect(!(try context.fetch(FetchDescriptor<TaskItem>()).contains { $0.id == jan6ID }))
        #expect(definition.recurrenceEffectiveFromKey == "20260106")
        #expect(!definition.occurrences.contains { $0.skipped })   // removals are not user skips
    }

    @Test("A new rule never adds past occurrences, now or on later runs")
    func ruleChangeKeepsHistory() throws {
        let context = makeContext()
        let c = cal()
        let seed = TaskItem(title: "Review", dayKey: "20260101")
        context.insert(seed)
        let weekly = RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(2026, 1, 1, c))
        let definition = try RecurrenceMaterializer.startSeries(from: seed, rule: weekly, through: date(2026, 1, 31, c),
                                                                context: context, calendar: c)
        try context.save()

        let daily = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        try RecurrenceMaterializer.changeRule(of: definition, to: daily, today: date(2026, 1, 20, c),
                                              through: date(2026, 1, 31, c), context: context, calendar: c)
        try context.save()
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 2, 28, c), calendar: c)

        let keys = Set(try occurrences(of: definition, context).compactMap(\.occurrenceKey))
        #expect(!keys.contains("20260102") && !keys.contains("20260119"))   // no invented history
        #expect(keys.contains("20260115") && keys.contains("20260121") && keys.contains("20260228"))
    }

    @Test("Stopping keeps history and changed future work, removes untouched future, and generates nothing more")
    func stopRepeating() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan8 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == "20260108" })
        jan8.notes = "planned"
        try context.save()

        var stopped = try #require(definition.recurrence)
        stopped.end = .until(date(2026, 1, 5, c))
        try RecurrenceMaterializer.changeRule(of: definition, to: stopped, today: date(2026, 1, 5, c),
                                              through: date(2026, 1, 31, c), context: context, calendar: c)
        try context.save()
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 3, 1, c), calendar: c)

        let keys = try occurrences(of: definition, context).compactMap(\.occurrenceKey).sorted()
        #expect(keys == ["20260101", "20260102", "20260103", "20260104", "20260105", "20260108"])
        #expect(definition.recurrence?.hasEnded(asOf: date(2026, 1, 5, c), calendar: c) == true)
    }

    @Test("Deleting a list skips the slots of the occurrences it held")
    func listDeletionSkips() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let service = DataService(context)
        let list = try service.addCustomList(name: "Someday")
        let jan4 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == "20260104" })
        try service.dropTask(jan4.id, into: .customList(list), before: nil, siblings: [])

        try service.delete(list)
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == "20260104" })
        #expect(!(try occurrences(of: definition, context)).contains { $0.occurrenceKey == "20260104" })
    }

    @Test("Auto-delete skips a purged occurrence's slot so it never comes back open")
    func autoDeleteSkips() throws {
        let context = makeContext()
        let c = cal()
        let (_, definition) = try startDaily(context, c)
        let jan2 = try #require(try occurrences(of: definition, context).first { $0.occurrenceKey == "20260102" })
        jan2.setDone(true, at: date(2026, 1, 2, c))
        try context.save()

        AutoDeleteService.purgeCompleted(context: context, enabled: true, olderThanDays: 7, now: date(2026, 1, 20, c))
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)
        #expect(!(try occurrences(of: definition, context)).contains { $0.occurrenceKey == "20260102" })
        #expect(definition.occurrences.contains { $0.skipped && $0.dayKey == "20260102" })
        #expect(try RecurrenceMaterializer.definition(for: definition, context: context) != nil)
    }
}
