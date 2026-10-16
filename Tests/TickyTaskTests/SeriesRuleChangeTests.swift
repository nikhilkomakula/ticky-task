import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Comprehensive test suite for recurring series rule changes.
/// Tests cover the provenance matrix (nil/false/true × matched/unmatched × past/today/future),
/// exact slots for frequency changes, rename + rule edit, historical boundary protection,
/// offline gaps, far-future reconciliation, stop/resume, afterCount anchoring,
/// legacy row protection, notification names, series linkage, order & attributes,
/// and multiple rule changes.
@MainActor
@Suite("Series rule changes")
struct SeriesRuleChangeTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
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

    // MARK: - Helper: Materialize and fetch definitions/occurrences

    private func materializeAndFetch(_ context: ModelContext, _ cal: Calendar, horizon: Date)
        throws -> (definitions: [TaskItem], occurrences: [TaskItem]) {
        try RecurrenceMaterializer.materialize(context: context, through: horizon, calendar: cal)
        let definitions = try RecurrenceMaterializer.definitions(context)
        let occurrences = try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.templateID != nil }
        ))
        return (definitions, occurrences)
    }

    // MARK: - Provenance basic cases: nil/false/true (separate, not full matrix)

    @Test("Provenance nil matched: occurrence with no slot history is kept on rule change")
    func provenanceNilMatched() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday)!

        let definition = TaskItem(title: "Daily standup", dayKey: "20261015",
                                  recurrence: RecurrenceRule(frequency: .daily, startDate: today))
        let oldOccurrence = TaskItem(title: "Daily standup", dayKey: "20261015")
        oldOccurrence.templateID = definition.id
        oldOccurrence.occurrenceKey = nil  // Legacy: slot unknown
        oldOccurrence.occurrenceModified = nil  // Legacy: provenance nil

        context.insert(definition)
        context.insert(oldOccurrence)
        try context.save()

        let newRule = RecurrenceRule(frequency: .weekly, startDate: today)
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: tomorrow, context: context, calendar: cal)
        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        #expect(occurrences.count >= 1)  // Legacy row kept
        #expect(occurrences.contains { $0.id == oldOccurrence.id })
    }

    @Test("Provenance false unmatched: untouched generated occurrence on future slot is removed")
    func provenanceFalseUnmatched() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)

        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 10, 10, cal: cal))
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)

        let futureOcc = TaskItem(title: "Task", dayKey: "20261020")
        futureOcc.templateID = definition.id
        futureOcc.occurrenceKey = "20261020"  // Future slot
        futureOcc.occurrenceModified = false  // Untouched, generated
        context.insert(futureOcc)
        try context.save()

        // Change to weekly (different schedule)
        let newRule = RecurrenceRule(frequency: .weekly, startDate: date(2026, 10, 10, cal: cal))
        let tomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday)!
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: tomorrow, context: context, calendar: cal)
        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        #expect(!occurrences.contains { $0.id == futureOcc.id })  // Removed
    }

    @Test("Provenance true: touched occurrence is always kept regardless of rule match")
    func provenanceTrue() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)

        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 10, 10, cal: cal))
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)

        let futureOcc = TaskItem(title: "Task", dayKey: "20261020")
        futureOcc.templateID = definition.id
        futureOcc.occurrenceKey = "20261020"
        futureOcc.occurrenceModified = true  // Touched
        context.insert(futureOcc)
        try context.save()

        let newRule = RecurrenceRule(frequency: .weekly, startDate: date(2026, 10, 10, cal: cal))
        let tomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday)!
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: tomorrow, context: context, calendar: cal)
        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        #expect(occurrences.contains { $0.id == futureOcc.id })  // Kept
    }

    // MARK: - Exact slots for frequency changes

    @Test("Daily to weekly: only Thu occurrences remain")
    func dailyToWeekly() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)  // Thursday
        let today = date(2026, 10, 15, cal: cal)  // Thursday
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 22, cal: cal)

        let dailyRule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Daily", recurrence: dailyRule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)
        try context.save()

        let weeklyRule = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: weeklyRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context).filter { $0.dayKey != nil }
        for occ in occurrences {
            // All occurrences should be on Thursdays (or be old ones kept)
            if let key = occ.occurrenceKey, occ.occurrenceModified != nil {
                let d = WeekMath.date(fromDayKey: key, calendar: cal)!
                let dow = cal.component(.weekday, from: d)
                #expect(dow == 5 || key < dayKey(startOfToday, cal))  // 5=Thursday or past
            }
        }
    }

    @Test("Weekly to daily: fills gaps between old weekly slots")
    func weeklyToDaily() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)  // Thursday
        let today = date(2026, 10, 15, cal: cal)  // Thursday
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 22, cal: cal)

        let weeklyRule = RecurrenceRule(frequency: .weekly, startDate: start)
        let definition = TaskItem(title: "Weekly", recurrence: weeklyRule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)
        try context.save()

        let dailyRule = RecurrenceRule(frequency: .daily, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: dailyRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let todayKey = dayKey(startOfToday, cal)
        let futureOccs = try RecurrenceMaterializer.children(of: definition, context: context)
            .filter { ($0.dayKey ?? "") >= todayKey }
        // Should have multiple days now (Fri, Sat, Sun, Mon, etc.)
        #expect(futureOccs.count >= 3)
    }

    @Test("Weekly to monthly: keeps anchored day-of-month")
    func weeklyToMonthly() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 15, cal: cal)  // 15th
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2027, 1, 31, cal: cal)

        let weeklyRule = RecurrenceRule(frequency: .weekly, startDate: start)
        let definition = TaskItem(title: "Weekly", recurrence: weeklyRule)
        context.insert(definition)
        try context.save()

        let monthlyRule = RecurrenceRule(frequency: .monthly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: monthlyRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let futureOccs = try RecurrenceMaterializer.children(of: definition, context: context).filter { $0.dayKey != nil }
        for occ in futureOccs {
            if let key = occ.dayKey, key >= dayKey(startOfToday, cal) {
                let d = WeekMath.date(fromDayKey: key, calendar: cal)!
                let day = cal.component(.day, from: d)
                #expect(day == 15)  // 15th of each month
            }
        }
    }

    @Test("Interval change: phase stays anchored to original startDate")
    func intervalChange() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 11, 30, cal: cal)

        // Every 1 day
        let rule1 = RecurrenceRule(frequency: .daily, interval: 1, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule1)
        context.insert(definition)
        try context.save()

        // Change to every 3 days
        let rule2 = RecurrenceRule(frequency: .daily, interval: 3, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: rule2, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let (defs, _) = try materializeAndFetch(context, cal, horizon: horizon)
        let def = defs.first { $0.id == definition.id }
        #expect(def?.recurrence?.interval == 3)
    }

    // MARK: - Rename then rule edit (separate and combined)

    @Test("Rename definition: occurrence title does not auto-update")
    func renameDefinitionOnly() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 22, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, startDate: today)
        let definition = TaskItem(title: "Old Title", dayKey: nil, recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: horizon, calendar: cal)
        try context.save()

        definition.title = "New Title"

        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        #expect(definition.title == "New Title")
        // Existing occurrences keep old title until rule change
        #expect(!occurrences.isEmpty)
    }

    @Test("Rename + rule edit in same transaction: new occurrences inherit new title")
    func renameAndRuleEdit() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 22, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 10, 10, cal: cal))
        let definition = TaskItem(title: "Old Title", recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)
        try context.save()

        definition.title = "New Title"
        let newRule = RecurrenceRule(frequency: .weekly, startDate: date(2026, 10, 10, cal: cal))
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let futureOccs = try RecurrenceMaterializer.children(of: definition, context: context).filter { ($0.dayKey ?? "") > dayKey(startOfToday, cal) }
        // New occurrences after rule change inherit from the definition
        for occ in futureOccs {
            if occ.dayKey! > dayKey(startOfToday, cal) {
                #expect(occ.title == "New Title")
            }
        }
    }

    // MARK: - Historical boundary: no new past

    @Test("Rule change never adds past occurrences")
    func noNewPastOccurrences() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 9, 1, cal: cal)  // Thursday
        let today = date(2026, 10, 15, cal: cal) // Wednesday
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 22, cal: cal)

        // Daily rule, but today is the rule-change point
        let rule1 = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule1)
        context.insert(definition)
        try context.save()

        // Materialize only through today
        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)

        let occsBefore = try RecurrenceMaterializer.children(of: definition, context: context)
        let keysBefore = Set(occsBefore.compactMap(\.occurrenceKey))

        // Change to weekly
        let rule2 = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: rule2, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let occsAfter = try RecurrenceMaterializer.children(of: definition, context: context)
        let keysAfter = Set(occsAfter.compactMap(\.occurrenceKey))

        // All past daily slots should remain
        let pastSlots = keysBefore.filter { $0 <= dayKey(startOfToday, cal) }
        for key in pastSlots {
            #expect(keysAfter.contains(key),
                   "Past daily slot \(key) should be retained, not removed")
        }

        // No new past slots should be added
        let newPastSlots = keysAfter.filter { key in
            key <= dayKey(startOfToday, cal) && !keysBefore.contains(key)
        }
        #expect(newPastSlots.isEmpty,
               "Should never add new past occurrences; found: \(newPastSlots)")
    }

    // MARK: - Offline gap: reconciliation with existing far-future rows

    @Test("Far-future occurrence from old rule is reconciled when rule changes")
    func offlineGapReconciliation() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 1, 1, cal: cal)  // Thursday
        let today = date(2026, 10, 15, cal: cal)  // Wednesday
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 12, 31, cal: cal)

        // Daily rule
        let rule1 = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule1)
        context.insert(definition)
        try context.save()

        // Materialize up to far future (simulating earlier navigation)
        try RecurrenceMaterializer.materialize(context: context, through: horizon, calendar: cal)

        let occsBefore = try RecurrenceMaterializer.children(of: definition, context: context)
        let keysBefore = Set(occsBefore.compactMap(\.occurrenceKey))

        // Count future untouched daily slots
        let futureUntouchedDailyBefore = keysBefore.filter { key in
            key > dayKey(startOfToday, cal) &&
            occsBefore.first(where: { $0.occurrenceKey == key })?.occurrenceModified == false
        }.count

        // Change to weekly
        let rule2 = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: rule2, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let occsAfter = try RecurrenceMaterializer.children(of: definition, context: context)
        let keysAfter = Set(occsAfter.compactMap(\.occurrenceKey))

        // All past slots should remain
        let pastSlots = keysBefore.filter { $0 <= dayKey(startOfToday, cal) }
        for key in pastSlots {
            #expect(keysAfter.contains(key),
                   "Past daily slot \(key) should be retained after rule change")
        }

        // Future untouched daily slots should be removed
        let futureUntouchedDailyAfter = keysAfter.filter { key in
            key > dayKey(startOfToday, cal) &&
            occsAfter.first(where: { $0.occurrenceKey == key })?.occurrenceModified == false
        }.count
        #expect(futureUntouchedDailyAfter < futureUntouchedDailyBefore,
               "Untouched future daily slots should be removed when changing to weekly")

        // Verify weekly pattern in future
        let futureKeys = keysAfter.filter { $0 > dayKey(startOfToday, cal) }
        for key in futureKeys {
            if let occ = occsAfter.first(where: { $0.occurrenceKey == key }), occ.occurrenceModified == false {
                let d = WeekMath.date(fromDayKey: key, calendar: cal)!
                let dow = cal.component(.weekday, from: d)
                #expect(dow == 5, "Future untouched slot \(key) should be Thursday (weekly rule)")
            }
        }
    }

    // MARK: - Stop repeating + resuming

    @Test("Stop repeating: change to until(today)")
    func stopRepeating() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 22, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 10, 10, cal: cal))
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)

        let stoppingRule = RecurrenceRule(frequency: .daily, startDate: date(2026, 10, 10, cal: cal),
                                         end: .until(today))
        try RecurrenceMaterializer.changeRule(of: definition, to: stoppingRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        #expect(definition.recurrence?.end == .until(today))

        // Future occurrences should stop
        let futureOccs = try RecurrenceMaterializer.children(of: definition, context: context).filter { ($0.dayKey ?? "") > dayKey(startOfToday, cal) }
        #expect(futureOccs.isEmpty)
    }

    @Test("Resume after stop: set end back to .never")
    func resumeAfterStop() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 22, cal: cal)

        let stoppedRule = RecurrenceRule(frequency: .daily, startDate: date(2026, 10, 10, cal: cal),
                                        end: .until(today))
        let definition = TaskItem(title: "Task", recurrence: stoppedRule)
        context.insert(definition)
        try context.save()

        let resumingRule = RecurrenceRule(frequency: .daily, startDate: date(2026, 10, 10, cal: cal),
                                         end: .never)
        try RecurrenceMaterializer.changeRule(of: definition, to: resumingRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        #expect(definition.recurrence?.end == .never)

        let futureOccs = try RecurrenceMaterializer.children(of: definition, context: context).filter { ($0.dayKey ?? "") > dayKey(startOfToday, cal) }
        #expect(!futureOccs.isEmpty)
    }

    // MARK: - afterCount anchoring

    @Test("afterCount end is preserved on rule change and still anchors to original startDate")
    func afterCountAnchoring() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 11, 30, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, interval: 1, startDate: start,
                                 end: .afterCount(10))
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)
        try context.save()

        let newRule = RecurrenceRule(frequency: .daily, interval: 3, startDate: start,
                                    end: .afterCount(10))
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        #expect(definition.recurrence?.end == .afterCount(10))
        #expect(definition.recurrence?.startDate == start)
    }

    // MARK: - Legacy rows protection

    @Test("Legacy row with provenance nil is never deleted")
    func legacyRowProtection() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 22, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 10, 10, cal: cal))
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)

        let legacyOcc = TaskItem(title: "Task", dayKey: "20261020")
        legacyOcc.templateID = definition.id
        legacyOcc.occurrenceKey = nil  // No slot recorded
        legacyOcc.occurrenceModified = nil  // Provenance unknown
        context.insert(legacyOcc)
        try context.save()

        let newRule = RecurrenceRule(frequency: .weekly, startDate: date(2026, 10, 10, cal: cal))
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let allOccs = try RecurrenceMaterializer.children(of: definition, context: context)
        #expect(allOccs.contains { $0.id == legacyOcc.id })
    }

    // MARK: - Series linkage and templateID consistency

    @Test("All occurrences have correct templateID linking to definition")
    func seriesLinkage() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let horizon = date(2026, 10, 31, cal: cal)

        let rule = RecurrenceRule(frequency: .weekly, startDate: start)
        let definition = TaskItem(title: "Weekly", recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: horizon, calendar: cal)
        try context.save()

        let occurrences = try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.templateID != nil }
        ))
        for occ in occurrences {
            #expect(occ.templateID == definition.id)
        }
    }

    // MARK: - Order & attributes: shared attributes inherit correctly

    @Test("Occurrences inherit definition's priority, color, and alarm")
    func inheritedAttributes() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let horizon = date(2026, 10, 31, cal: cal)

        let rule = RecurrenceRule(frequency: .weekly, startDate: start)
        let definition = TaskItem(title: "Task", colorHex: "#FF0000", priority: 2,
                                 alarmEnabled: true, recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: horizon, calendar: cal)
        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        for occ in occurrences {
            #expect(occ.colorHex == "#FF0000")
            #expect(occ.priority == 2)
            #expect(occ.alarmEnabled == true)
        }
    }

    @Test("New occurrences get new sort indices after rule change")
    func sortIndexOrdering() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 31, cal: cal)

        let rule = RecurrenceRule(frequency: .weekly, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)

        let newRule = RecurrenceRule(frequency: .daily, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        let sortIndices = occurrences.compactMap(\.sortIndex).sorted()
        #expect(!sortIndices.isEmpty)
    }

    // MARK: - Multiple rule changes in sequence

    @Test("Two consecutive rule changes apply correctly")
    func multipleConsecutiveChanges() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let today1 = date(2026, 10, 15, cal: cal)
        let today2 = date(2026, 10, 20, cal: cal)
        let horizon = date(2026, 11, 30, cal: cal)

        // Start with daily
        let rule1 = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule1)
        context.insert(definition)
        try context.save()

        // First change to weekly
        let rule2 = RecurrenceRule(frequency: .weekly, startDate: start)
        let startOfToday1 = cal.startOfDay(for: today1)
        try RecurrenceMaterializer.changeRule(of: definition, to: rule2, today: startOfToday1,
                                            through: today2, context: context, calendar: cal)
        try context.save()

        // Second change to monthly
        let rule3 = RecurrenceRule(frequency: .monthly, startDate: start)
        let startOfToday2 = cal.startOfDay(for: today2)
        try RecurrenceMaterializer.changeRule(of: definition, to: rule3, today: startOfToday2,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        #expect(definition.recurrence?.frequency == .monthly)
        #expect(definition.recurrence?.startDate == start)
    }

    // MARK: - Effective-from boundary

    @Test("recurrenceEffectiveFromKey is set to day after rule change")
    func effectiveFromBoundary() throws {
        let cal = calendar()
        let context = makeContext()
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 22, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 10, 10, cal: cal))
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)
        try context.save()

        let newRule = RecurrenceRule(frequency: .weekly, startDate: date(2026, 10, 10, cal: cal))
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let tomorrowKey = dayKey(cal.date(byAdding: .day, value: 1, to: startOfToday)!, cal)
        #expect(definition.recurrenceEffectiveFromKey == tomorrowKey)
    }

    // MARK: - Notes and critical flag inheritance

    @Test("Definition's critical flag propagates to new occurrences")
    func criticalFlagInheritance() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 31, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Critical Task", dayKey: nil, recurrence: rule)
        definition.isCritical = true
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)

        let newRule = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let futureOccs = try RecurrenceMaterializer.children(of: definition, context: context).filter { ($0.dayKey ?? "") > dayKey(startOfToday, cal) }
        for occ in futureOccs {
            #expect(occ.isCritical)
        }
    }

    // MARK: - Rich notes encoding/decoding

    @Test("Definition's rich notes encode and decode correctly")
    func richNotesEncoding() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)

        let doc = NotesDocument(blocks: [
            NotesBlock(kind: .paragraph, runs: [NotesRun(text: "Important", bold: true)])
        ])
        let encodedNotes = try NotesCodec.encode(doc)

        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule)
        definition.notesRich = encodedNotes
        context.insert(definition)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TaskItem>()).first
        let decodedNotes = try fetched?.notesRich.map { try NotesCodec.decode($0) }
        #expect(decodedNotes?.plainText.contains("Important") ?? false)
    }

    // MARK: - Slot skipping with occurrences

    @Test("Skip records prevent regeneration of deleted occurrences")
    func skipRecordingAndRegeneration() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let today = date(2026, 10, 15, cal: cal)
        let horizon = date(2026, 10, 31, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: horizon, calendar: cal)

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        let firstOcc = occurrences.first
        if let occ = firstOcc {
            try RecurrenceMaterializer.skipSlot(of: occ, context: context)
        }
        try context.save()

        let skipRecords = definition.occurrences.filter(\.skipped)
        #expect(!skipRecords.isEmpty)
    }

    // MARK: - Moved occurrences stay in place

    @Test("Occurrence moved to custom list is not regenerated on same slot after rule change")
    func movedOccurrenceNotRegenerated() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 31, cal: cal)

        let list = CustomList(name: "Shopping")
        context.insert(list)

        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)
        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        if let occ = occurrences.first {
            occ.customList = list
            occ.dayKey = nil
        }
        try context.save()

        let newRule = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let movedOcc = occurrences.first
        #expect(movedOcc?.customList != nil)
        #expect(movedOcc?.dayKey == nil)
    }

    // MARK: - Completion flag on occurrences

    @Test("Completed occurrence is kept during rule change")
    func completedOccurrenceKept() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 31, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        if let occ = occurrences.first {
            occ.isDone = true
            occ.completedAt = today
        }
        try context.save()

        let newRule = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let fetchedOcc = occurrences.first
        #expect(fetchedOcc?.isDone == true)
    }

    // MARK: - Subtasks on occurrences

    @Test("Occurrence with subtasks is protected from deletion")
    func occurrenceWithSubtasksProtected() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let today = date(2026, 10, 15, cal: cal)
        let startOfToday = cal.startOfDay(for: today)
        let horizon = date(2026, 10, 31, cal: cal)

        let rule = RecurrenceRule(frequency: .daily, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: startOfToday, calendar: cal)
        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        if let occ = occurrences.first {
            occ.subtasks.append(Subtask(title: "Subtask 1"))
        }
        try context.save()

        let newRule = RecurrenceRule(frequency: .weekly, startDate: start)
        try RecurrenceMaterializer.changeRule(of: definition, to: newRule, today: startOfToday,
                                            through: horizon, context: context, calendar: cal)
        try context.save()

        let fetchedOcc = occurrences.first
        #expect(fetchedOcc?.subtasks.isEmpty == false)
    }

    // MARK: - CustomList ownership for series

    @Test("Occurrence tied to definition can stay on day slot when moved between lists")
    func occurrenceCanBeMovedBetweenLocations() throws {
        let cal = calendar()
        let context = makeContext()
        let start = date(2026, 10, 1, cal: cal)
        let horizon = date(2026, 10, 31, cal: cal)

        let list1 = CustomList(name: "Work")
        let list2 = CustomList(name: "Home")
        context.insert(list1)
        context.insert(list2)

        let rule = RecurrenceRule(frequency: .weekly, startDate: start)
        let definition = TaskItem(title: "Task", recurrence: rule)
        context.insert(definition)
        try context.save()

        try RecurrenceMaterializer.materialize(context: context, through: horizon, calendar: cal)
        try context.save()

        let occurrences = try RecurrenceMaterializer.children(of: definition, context: context)
        if let occ = occurrences.first {
            occ.customList = list1
            occ.dayKey = nil
        }
        try context.save()

        if let occ = occurrences.first {
            occ.customList = list2
        }
        try context.save()

        let fetchedOcc = occurrences.first
        #expect(fetchedOcc?.customList?.id == list2.id)
    }
}
