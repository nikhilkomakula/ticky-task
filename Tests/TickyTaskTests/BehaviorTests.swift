import Testing
import Foundation
import SwiftData
@testable import TickyTask

@MainActor
@Suite("Behavior")
struct BehaviorTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    @Test("Sort by priority puts higher priority first")
    func sortPriority() throws {
        let context = makeContext()
        let service = DataService(context)
        let low = try service.addTask(title: "low", location: .day("20260814")); low.priority = 1
        let high = try service.addTask(title: "high", location: .day("20260814")); high.priority = 2
        let ordered = BehaviorService.sorted([low, high], mode: .priority, completedToBottom: false)
        #expect(ordered.map(\.title) == ["high", "low"])
    }

    @Test("Completed tasks sink to the bottom")
    func completedToBottom() throws {
        let context = makeContext()
        let service = DataService(context)
        let done = try service.addTask(title: "done", location: .day("20260814"))
        done.isDone = true; done.sortIndex = 1
        let open = try service.addTask(title: "open", location: .day("20260814"))
        open.sortIndex = 2
        let ordered = BehaviorService.sorted([done, open], mode: .manual, completedToBottom: true)
        #expect(ordered.map(\.title) == ["open", "done"])
    }

    @Test("Sort by time keeps untimed tasks last")
    func sortTime() throws {
        let context = makeContext()
        let service = DataService(context)
        let untimed = try service.addTask(title: "untimed", location: .day("20260814")); untimed.sortIndex = 1
        let timed = try service.addTask(title: "9am", location: .day("20260814"))
        timed.timeMinutes = 9 * 60; timed.sortIndex = 2
        let ordered = BehaviorService.sorted([untimed, timed], mode: .time, completedToBottom: false)
        #expect(ordered.map(\.title) == ["9am", "untimed"])
    }

    @Test("Carry-forward moves only past, unfinished, non-recurring tasks to today")
    func carryForward() throws {
        let context = makeContext()
        let service = DataService(context)
        _ = try service.addTask(title: "old-open", location: .day("20260101"))
        let oldDone = try service.addTask(title: "old-done", location: .day("20260101"))
        oldDone.isDone = true
        _ = try service.addTask(title: "today", location: .day("20260814"))
        try service.save()

        let moved = try BehaviorService.carryForwardIncomplete(context: context, targetKey: "20260814")
        #expect(moved == 1)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.first { $0.title == "old-open" }?.dayKey == "20260814")
        #expect(tasks.first { $0.title == "old-done" }?.dayKey == "20260101")
    }

    @Test("Carry-forward lands tasks after today's, oldest past day first")
    func carryForwardOrder() throws {
        let context = makeContext()
        let service = DataService(context)
        // An existing today task seeds the starting sortIndex; two past days.
        let today = try service.addTask(title: "today", location: .day("20260814"))
        today.sortIndex = 10
        _ = try service.addTask(title: "newer-past", location: .day("20260813"))
        _ = try service.addTask(title: "older-past", location: .day("20260101"))
        try service.save()

        let moved = try BehaviorService.carryForwardIncomplete(context: context, targetKey: "20260814")
        #expect(moved == 2)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let older = tasks.first { $0.title == "older-past" }
        let newer = tasks.first { $0.title == "newer-past" }
        #expect(older?.dayKey == "20260814")
        #expect(newer?.dayKey == "20260814")
        // Both land after today's existing task (sortIndex 10), oldest day first.
        #expect((older?.sortIndex ?? 0) > 10)
        #expect((older?.sortIndex ?? 0) < (newer?.sortIndex ?? 0))
    }

    @Test("Carry-forward leaves recurring templates and their occurrences in place")
    func carryForwardSkipsRecurring() throws {
        let context = makeContext()
        let service = DataService(context)
        // A recurring template on a past day.
        let template = try service.addTask(title: "template", location: .day("20260101"))
        template.recurrence = RecurrenceRule(frequency: .daily, startDate: Date())
        // A materialized occurrence on a past day (links back to the template).
        let occurrence = try service.addTask(title: "occurrence", location: .day("20260102"))
        occurrence.templateID = template.id
        // A plain past task that SHOULD move.
        _ = try service.addTask(title: "plain", location: .day("20260103"))
        try service.save()

        let moved = try BehaviorService.carryForwardIncomplete(context: context, targetKey: "20260814")
        #expect(moved == 1)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.first { $0.title == "template" }?.dayKey == "20260101")
        #expect(tasks.first { $0.title == "occurrence" }?.dayKey == "20260102")
        #expect(tasks.first { $0.title == "plain" }?.dayKey == "20260814")
    }

    /// A Gregorian calendar whose locale considers only Sunday a weekend. Product
    /// behavior must still treat both named Saturday/Sunday columns as weekends.
    /// 2026-01-01 is a Thursday, so Jan 2 = Fri, 3 = Sat, 4 = Sun, 5 = Mon.
    private func weekendCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_IN")
        return c
    }

    @Test("Carry-forward target skips a hidden weekend to the next weekday")
    func carryForwardTargetSkipsWeekend() {
        let c = weekendCalendar()
        // Weekends hidden: Saturday and Sunday both roll onto Monday.
        #expect(BehaviorService.carryForwardTarget(todayKey: "20260103", showWeekends: false, calendar: c) == "20260105")
        #expect(BehaviorService.carryForwardTarget(todayKey: "20260104", showWeekends: false, calendar: c) == "20260105")
        // Weekends shown → today unchanged; a weekday → today unchanged.
        #expect(BehaviorService.carryForwardTarget(todayKey: "20260103", showWeekends: true, calendar: c) == "20260103")
        #expect(BehaviorService.carryForwardTarget(todayKey: "20260107", showWeekends: false, calendar: c) == "20260107")
    }

    @Test("With weekends hidden, a Friday's unfinished tasks carry onto Monday")
    func carryForwardFridayToMonday() throws {
        let context = makeContext()
        let c = weekendCalendar()
        let service = DataService(context)
        _ = try service.addTask(title: "friday-open", location: .day("20260102"))   // Friday
        try service.save()

        // Today is Saturday with weekends hidden → target is Monday.
        let target = BehaviorService.carryForwardTarget(todayKey: "20260103", showWeekends: false, calendar: c)
        let moved = try BehaviorService.carryForwardIncomplete(context: context, targetKey: target)
        #expect(moved == 1)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.first { $0.title == "friday-open" }?.dayKey == "20260105")   // Monday
    }
}
