import Testing
import Foundation
import SwiftData
@testable import TickyTask

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

    /// A daily template starting 2026-01-01 with the given end condition.
    @discardableResult
    private func insertDailyTemplate(_ context: ModelContext, _ c: Calendar,
                                     end: RecurrenceEnd = .never) -> TaskItem {
        let start = date(2026, 1, 1, c)
        let template = TaskItem(title: "Water plants", dayKey: WeekMath.dayKey(for: start, calendar: c))
        template.recurrence = RecurrenceRule(frequency: .daily, end: end, startDate: start)
        template.timeMinutes = 540
        template.priority = 2
        template.isCritical = true
        template.alarmEnabled = true
        context.insert(template)
        try? context.save()
        return template
    }

    private func children(of template: TaskItem, _ context: ModelContext) -> [TaskItem] {
        let id = template.id
        let all = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        return all.filter { $0.templateID == id }.sorted { ($0.dayKey ?? "") < ($1.dayKey ?? "") }
    }

    @Test("Materialize creates one occurrence per due day, copying display attributes")
    func createsOccurrences() throws {
        let context = makeContext()
        let c = cal()
        let template = insertDailyTemplate(context, c, end: .afterCount(5))
        let created = try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)

        // afterCount(5) = Jan 1–5; the start day (Jan 1) is the template itself.
        #expect(created == 4)
        let kids = children(of: template, context)
        #expect(kids.map { $0.dayKey ?? "" } == ["20260102", "20260103", "20260104", "20260105"])
        let sample = kids[0]
        #expect(sample.title == "Water plants")
        #expect(sample.timeMinutes == 540)
        #expect(sample.priority == 2)
        #expect(sample.isCritical)
        #expect(sample.alarmEnabled)
        #expect(sample.recurrence == nil)
        #expect(sample.templateID == template.id)
    }

    @Test("Materialize is idempotent")
    func idempotent() throws {
        let context = makeContext()
        let c = cal()
        let template = insertDailyTemplate(context, c, end: .afterCount(5))
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)
        let again = try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)
        #expect(again == 0)
        #expect(children(of: template, context).count == 4)
    }

    @Test("A deleted occurrence is tombstoned and never regenerated")
    func skipTombstoneHonored() throws {
        let context = makeContext()
        let c = cal()
        let template = insertDailyTemplate(context, c, end: .afterCount(5))
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)

        let jan3 = children(of: template, context).first { $0.dayKey == "20260103" }!
        try RecurrenceMaterializer.deleteOccurrence(jan3, context: context)
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)

        #expect(children(of: template, context).map { $0.dayKey ?? "" } == ["20260102", "20260104", "20260105"])
        #expect(template.occurrences.contains { $0.skipped && $0.dayKey == "20260103" })
    }

    @Test("A completed occurrence is preserved, not regenerated")
    func completedPreserved() throws {
        let context = makeContext()
        let c = cal()
        let template = insertDailyTemplate(context, c, end: .afterCount(5))
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)
        let jan2 = children(of: template, context).first { $0.dayKey == "20260102" }!
        jan2.setDone(true)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)
        let kids = children(of: template, context)
        #expect(kids.count == 4)
        #expect(kids.first { $0.dayKey == "20260102" }!.isDone)
    }

    @Test("Rule change regenerates future days but keeps past, done, and edited ones")
    func ruleChangeRegenerates() throws {
        let context = makeContext()
        let c = cal()
        let template = insertDailyTemplate(context, c)   // daily, never-ending
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)
        // Children Jan 2…Jan 10 exist. Manually edit a future one so it survives.
        let jan9 = children(of: template, context).first { $0.dayKey == "20260109" }!
        jan9.title = "Custom title"
        try context.save()

        // Switch to weekly (start day is a Thursday → Jan 1, 8, 15, …).
        template.recurrence = RecurrenceRule(frequency: .weekly, startDate: date(2026, 1, 1, c))
        try RecurrenceMaterializer.regenerateFuture(
            for: template, todayKey: "20260105", through: date(2026, 1, 31, c), context: context, calendar: c
        )

        let dayKeys = Set(children(of: template, context).compactMap(\.dayKey))
        #expect(dayKeys.contains("20260103"))   // past kept
        #expect(dayKeys.contains("20260109"))   // future but edited → kept
        #expect(!dayKeys.contains("20260107"))  // future, unedited → removed
        #expect(dayKeys.contains("20260108"))   // new weekly occurrence
        #expect(dayKeys.contains("20260115"))
    }

    @Test("Delete series removes template, occurrences, and tombstones")
    func deleteSeries() throws {
        let context = makeContext()
        let c = cal()
        let template = insertDailyTemplate(context, c, end: .afterCount(5))
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)

        try RecurrenceMaterializer.deleteSeries(template, context: context)
        #expect((try context.fetch(FetchDescriptor<TaskItem>())).isEmpty)
        #expect((try context.fetch(FetchDescriptor<TaskOccurrence>())).isEmpty)
    }

    @Test("Deleting the start-day instance advances the template to the next occurrence")
    func advancePastStart() throws {
        let context = makeContext()
        let c = cal()
        let template = insertDailyTemplate(context, c)   // daily, never-ending
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 10, c), calendar: c)

        try RecurrenceMaterializer.deleteOccurrence(template, context: context, calendar: c)

        #expect(template.dayKey == "20260102")
        #expect(template.recurrence != nil)
        #expect(template.occurrences.contains { $0.skipped && $0.dayKey == "20260101" })
        // No duplicate child left on the promoted day.
        #expect(children(of: template, context).first { $0.dayKey == "20260102" } == nil)
    }

    @Test("Deleting the start-day instance preserves a sparse series")
    func advancePastSparseStart() throws {
        let context = makeContext()
        let c = cal()
        let start = date(2026, 1, 1, c)
        let template = TaskItem(title: "Decennial", dayKey: "20260101")
        template.recurrence = RecurrenceRule(frequency: .yearly, interval: 10, startDate: start)
        context.insert(template)
        try context.save()

        try RecurrenceMaterializer.deleteOccurrence(template, context: context, calendar: c)

        #expect(template.dayKey == "20360101")
        #expect(template.recurrence != nil)
        #expect(template.occurrences.contains { $0.skipped && $0.dayKey == "20260101" })
    }

    @Test("Removing recurrence detaches the series and leaves a plain task")
    func removeRecurrence() throws {
        let context = makeContext()
        let c = cal()
        let template = insertDailyTemplate(context, c, end: .afterCount(5))
        try RecurrenceMaterializer.materialize(context: context, through: date(2026, 1, 31, c), calendar: c)

        try RecurrenceMaterializer.removeRecurrence(from: template, context: context)
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 1)
        #expect(all[0].recurrence == nil)
        #expect(all[0].templateID == nil)
    }
}
