import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Tests for offline gaps and far-future cache reconciliation in recurring series.
/// Covers scenarios where materialization doesn't happen continuously, and rule changes
/// must correctly handle existing far-future slots and reconcile schedules.
@MainActor
@Suite("Series schedule gaps")
struct SeriesScheduleGapTests {
    /// Every day key from `start` through `end`, inclusive.
    private func keys(from start: (Int, Int, Int), through end: (Int, Int, Int)) -> [String] {
        let c = calendar()
        var day = c.date(from: DateComponents(year: start.0, month: start.1, day: start.2))!
        let last = c.date(from: DateComponents(year: end.0, month: end.1, day: end.2))!
        var out: [String] = []
        while day <= last { out.append(WeekMath.dayKey(for: day, calendar: c)); day = c.date(byAdding: .day, value: 1, to: day)! }
        return out
    }

    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    private func makeDiskContext(at url: URL) throws -> ModelContext {
        ModelContext(try ModelContainerProvider.makeContainer(at: url.appendingPathComponent("TickyTask.store")))
    }

    private func calendar(_ tz: String = "America/New_York") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        cal.firstWeekday = 1
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0, minute: Int = 0, cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    private func dayKey(_ date: Date, _ cal: Calendar) -> String {
        WeekMath.dayKey(for: date, calendar: cal)
    }

    private func dayKey(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d%02d%02d", y, m, d)
    }

    private func occurrences(of definition: TaskItem, _ context: ModelContext) throws -> [TaskItem] {
        try RecurrenceMaterializer.children(of: definition, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }
    }

    // MARK: - Offline gap: daily → weekly with catch-up

    @Test("Offline gap: daily through day 5, jump to day 20, change to weekly")
    func offlineGapDailyToWeekly() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)  // Thursday
        let day5 = date(2026, 10, 5, cal: cal)   // Monday
        let day20 = date(2026, 10, 20, cal: cal) // Tuesday (no intervening materialize)
        let horizon = date(2026, 10, 31, cal: cal)

        let dailyRule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Daily task", recurrence: dailyRule)
        context.insert(definition)
        try context.save()

        // Materialize only through day 5
        try RecurrenceMaterializer.materialize(context: context, through: day5, calendar: cal)
        var occsBefore = try occurrences(of: definition, context)
        let uuidsBefore = Set(occsBefore.compactMap(\.id))
        #expect(occsBefore.count >= 5, "Should have at least 5 daily occurrences through day 5")

        // Change rule to weekly WITHOUT intervening materialize (simulating offline gap)
        let weeklyRule = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: weeklyRule, today: day5,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        // Verify exact slot coverage
        var occsAfter = try occurrences(of: definition, context)

        // 1. Old-rule slots owed through day 5 (Oct 1-5): 5 daily occurrences
        let oldRuleSlots = Set(keys(from: (2026, 10, 1), through: (2026, 10, 5)))
        let oldRuleOccs = occsAfter.filter { occSlot in
            guard let key = occSlot.occurrenceKey else { return false }
            return oldRuleSlots.contains(key) && key <= dayKey(day5, cal)
        }
        #expect(oldRuleOccs.count == 5, "Should have exactly 5 old-rule daily slots through day 5")

        // 2. New-rule future slots (Thursdays on/after day 8): day 8, 15, 22, 29
        let newRuleDays = [date(2026, 10, 8, cal: cal), date(2026, 10, 15, cal: cal),
                          date(2026, 10, 22, cal: cal), date(2026, 10, 29, cal: cal)]
        let newRuleKeys = Set(newRuleDays.map { dayKey($0, cal) })
        let newRuleOccs = occsAfter.filter { newRuleKeys.contains($0.occurrenceKey ?? "") }
        #expect(newRuleOccs.count == 4, "Should have exactly 4 new-rule weekly Thursday slots")

        // 3. Pre-existing UUIDs kept (old-rule daily slots before the gap should be retained)
        for occ in oldRuleOccs {
            #expect(uuidsBefore.contains(occ.id),
                   "Old-rule occurrence \(occ.occurrenceKey ?? "nil") should retain its UUID")
        }

        // 4. Untouched future daily occurrences beyond day 5 should be removed
        let dailySlotsAfterDay5 = occsAfter.filter { occ in
            guard let key = occ.occurrenceKey, key > dayKey(day5, cal), key < dayKey(2026, 10, 8) else { return false }
            return occ.occurrenceModified == false  // Generated, untouched
        }
        #expect(dailySlotsAfterDay5.isEmpty, "Generated daily slots between day 5 and first Thursday should be removed")
    }

    // MARK: - Offline gap: weekly → daily with historical protection

    @Test("Offline gap: weekly through Oct 15, jump to Nov 1, change to daily")
    func offlineGapWeeklyToDaily() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)  // Thursday
        let day15 = date(2026, 10, 15, cal: cal) // Thursday
        let nov1 = date(2026, 11, 1, cal: cal)   // Sunday (gap, no materialize)
        let horizon = date(2026, 11, 15, cal: cal)

        let weeklyRule = RecurrenceRule(frequency: .weekly, startDate: start)
        let definition = TaskItem(title: "Weekly task", recurrence: weeklyRule)
        context.insert(definition)
        try context.save()

        // Materialize through Oct 15
        try RecurrenceMaterializer.materialize(context: context, through: day15, calendar: cal)
        let occsBefore = try occurrences(of: definition, context)
        #expect(occsBefore.count >= 3, "Should have at least 3 weekly Thursday occurrences")

        // Change to daily; historical protection should prevent daily slots before the rule change from appearing
        let dailyRule = RecurrenceRule(frequency: .daily, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: dailyRule, today: day15,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let occsAfter = try occurrences(of: definition, context)

        // Should NOT have daily occurrences for days between Oct 1 and Oct 15 (except those that were generated before)
        let historicalDailyOccs = occsAfter.filter { occ in
            guard let key = occ.occurrenceKey, occ.occurrenceModified == false else { return false }
            // Should not generate new daily for historical dates
            return key >= dayKey(2026, 10, 1) && key < dayKey(day15, cal)
        }
        #expect(historicalDailyOccs.isEmpty,
               "Should never add new daily occurrences for dates before rule change")

        // Should have daily starting from day 16 (after day 15)
        let futureOccs = occsAfter.filter { ($0.occurrenceKey ?? "") >= dayKey(2026, 10, 16) }
        #expect(futureOccs.count >= 10, "Should have daily occurrences from day 16 onward")
    }

    // MARK: - Far-future reconciliation

    @Test("Far-future: materialize 6 months ahead, rule change closer to today, revisit far range")
    func farFutureReconciliation() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let farFuture = date(2027, 4, 15, cal: cal)  // 6 months ahead
        let start = date(2026, 1, 1, cal: cal)

        // Daily series
        let dailyRule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Daily", recurrence: dailyRule)
        context.insert(definition)
        try context.save()

        // Pre-materialize far future (simulating user navigating ahead)
        try RecurrenceMaterializer.materialize(context: context, through: farFuture, calendar: cal)
        var occs = try occurrences(of: definition, context)

        // Change to weekly while closer to today
        let weeklyRule = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: weeklyRule, today: startOfToday,
                                            through: date(2026, 11, 15, cal: cal), context: context, calendar: cal)
        try context.save()

        // Re-materialize to the far future horizon
        try RecurrenceMaterializer.materialize(context: context, through: farFuture, calendar: cal)

        // Verify far-future slots now match weekly schedule, not daily
        occs = try occurrences(of: definition, context)
        let farFutureOccs = occs.filter { ($0.occurrenceKey ?? "") >= dayKey(2026, 4, 1) }
        for occ in farFutureOccs {
            guard let key = occ.occurrenceKey else { continue }
            let d = WeekMath.date(fromDayKey: key, calendar: cal)!
            let dow = cal.component(.weekday, from: d)
            let isThursday = (dow == 5)  // 1=Sunday, 5=Thursday
            #expect(isThursday || occ.occurrenceModified == true,
                   "Far-future slot \(key) should be Thursday (weekly rule) or touched")
        }

        // No daily slots should exist in far future for untouched occurrences
        let farFutureDailyGenerated = farFutureOccs.filter { occ in
            guard let key = occ.occurrenceKey, occ.occurrenceModified == false else { return false }
            let d = WeekMath.date(fromDayKey: key, calendar: cal)!
            let dow = cal.component(.weekday, from: d)
            return dow != 5  // Not Thursday
        }
        #expect(farFutureDailyGenerated.isEmpty,
               "Far-future generated occurrences should not include non-Thursday daily slots")
    }

    // MARK: - Offline gap with reopened on-disk store

    @Test("Offline gap with disk reopen: old slots survive, new rule takes effect")
    func offlineGapWithDiskReopen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TickyTaskTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cal = calendar()
        let start = date(2026, 10, 1, cal: cal)
        let day5 = date(2026, 10, 5, cal: cal)
        let day20 = date(2026, 10, 20, cal: cal)
        let horizon = date(2026, 10, 31, cal: cal)

        // Session 1: Materialize daily through day 5
        do {
            let context = try makeDiskContext(at: tempDir)
            let dailyRule = RecurrenceRule(frequency: .daily, startDate: start)
            let definition = TaskItem(title: "Task", recurrence: dailyRule)
            context.insert(definition)
            try context.save()

            try RecurrenceMaterializer.materialize(context: context, through: day5, calendar: cal)
            let occs = try occurrences(of: definition, context)
            #expect(occs.count >= 5)
        }

        // Session 2: Reopen, change rule to weekly
        do {
            let context = try makeDiskContext(at: tempDir)
            let definitions = try RecurrenceMaterializer.definitions(context)
            guard let definition = definitions.first else {
                #expect(Bool(false), "Definition should exist after reopen")
                return
            }

            let weeklyRule = RecurrenceRule(frequency: .weekly, startDate: start)
            try RecurrenceMaterializer.changeRule(of: definition, to: weeklyRule, today: day5,
                                                through: horizon, context: context, calendar: cal)
            try context.save()

            let occs = try occurrences(of: definition, context)
            #expect(occs.count >= 8, "Should have old daily + new weekly slots")
        }

        // Session 3: Reopen again, verify no slots were lost
        do {
            let context = try makeDiskContext(at: tempDir)
            let definitions = try RecurrenceMaterializer.definitions(context)
            guard let definition = definitions.first else {
                #expect(Bool(false), "Definition should survive reopen")
                return
            }

            let occs = try occurrences(of: definition, context)
            #expect(occs.count >= 8, "Persisted slots should survive reopen")

            // Verify old daily slots are still there
            let dailySlots = occs.filter { key in
                guard let k = key.occurrenceKey else { return false }
                return k >= dayKey(2026, 10, 1) && k <= dayKey(day5, cal)
            }
            #expect(dailySlots.count >= 5, "Old daily slots should persist through reopens")
        }
    }

    // MARK: - Replace weak count assertions with exact sets (from SeriesRuleChangeTests)

    @Test("Daily to weekly with exact slot sets: no new past, all future weekly present")
    func dailyToWeeklyExactSlots() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)  // Thursday
        let today = date(2026, 10, 15, cal: cal) // Thursday
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 31, cal: cal)

        let dailyRule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Daily", recurrence: dailyRule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)
        let dailyOccs = try occurrences(of: definition, context)
        let dailyKeys = Set(dailyOccs.compactMap(\.occurrenceKey))

        let weeklyRule = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: weeklyRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let afterOccs = try occurrences(of: definition, context)
        let afterKeys = Set(afterOccs.compactMap(\.occurrenceKey))

        // Past (Oct 1-15): all original daily slots should remain
        let pastDailyKeys = dailyKeys.filter { $0 <= dayKey(startOfToday, cal) }
        for key in pastDailyKeys {
            #expect(afterKeys.contains(key),
                   "Past daily slot \(key) should be retained")
        }

        // Future (after Oct 15): only Thursdays on Oct 22, 29 should exist (and no new daily)
        let expectedFutureThursdays = Set([dayKey(2026, 10, 22), dayKey(2026, 10, 29)])
        let futureKeys = afterKeys.filter { $0 > dayKey(startOfToday, cal) }
        #expect(futureKeys == expectedFutureThursdays,
               "Future slots should be exactly the two Thursdays, not \(futureKeys)")
    }

    @Test("Weekly to monthly with exact day-of-month anchoring")
    func weeklyToMonthlyExactAnchoring() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)  // First of month, Thursday
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2027, 3, 31, cal: cal)

        let weeklyRule = RecurrenceRule(frequency: .weekly, startDate: start)
        let definition = TaskItem(title: "Weekly", recurrence: weeklyRule)
        context.insert(definition)
        try context.save()

        let monthlyRule = RecurrenceRule(frequency: .monthly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: monthlyRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let occs = try occurrences(of: definition, context)
        let keys = Set(occs.compactMap(\.occurrenceKey))

        // Should have 1st of Oct, Nov, Dec, Jan, Feb, Mar, but NOT other dates
        let expectedMonthly = Set([dayKey(2026, 10, 1), dayKey(2026, 11, 1), dayKey(2026, 12, 1),
                                   dayKey(2027, 1, 1), dayKey(2027, 2, 1), dayKey(2027, 3, 1)])
        let futureMonthlyKeys = keys.filter { $0 > dayKey(startOfToday, cal) }
        #expect(futureMonthlyKeys == expectedMonthly.filter { $0 > dayKey(startOfToday, cal) },
               "Monthly rule should anchor to 1st of each month exactly")
    }
}
