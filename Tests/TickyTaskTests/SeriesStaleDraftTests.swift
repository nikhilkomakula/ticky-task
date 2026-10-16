import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Tests for concurrent editors with stale drafts: both TaskEdit drafts are constructed
/// before either is committed. Covers: different shared fields both survive, same field
/// → last commit wins, stale no-op preserves another's rule change, stale start-series
/// conflicts, and alarm-only stale edits without time.
@MainActor
@Suite("Series stale drafts")
struct SeriesStaleDraftTests {
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

    /// Create a daily series with 5 occurrences from 2026-01-01.
    private func createDailySeries(_ context: ModelContext, _ c: Calendar) throws -> (definition: TaskItem, children: [TaskItem]) {
        let seed = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 1), timeMinutes: 600)
        seed.priority = 1
        seed.isCritical = true
        context.insert(seed)

        let rule = RecurrenceRule(frequency: .daily, end: .afterCount(5),
                                 startDate: date(2026, 1, 1, c))
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: rule, through: date(2026, 1, 31, c), context: context, calendar: c)
        try context.save()

        let children = try RecurrenceMaterializer.children(of: definition, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }
        return (definition, children)
    }

    // MARK: - Different shared fields, both survive

    @Test("Two concurrent edits changing different fields both survive: title and priority")
    func concurrentDifferentFieldsSurvive() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Editor 1 captures baseline and prepares to change title
        let edited1 = children[0]
        let orig1 = SharedAttributes(edited1)
        var change1 = orig1
        change1.title = "New Title"
        let edit1 = TaskEdit(originalShared: orig1, editedShared: change1)

        // Editor 2 (separate context fetch): prepares to change priority
        let edited2 = children[1]
        let orig2 = SharedAttributes(edited2)
        var change2 = orig2
        change2.priority = 5
        let edit2 = TaskEdit(originalShared: orig2, editedShared: change2)

        // Commit editor 1
        try TaskEditCommit.commit(edit1, to: edited1, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Commit editor 2 (stale origin, but changing different field)
        try TaskEditCommit.commit(edit2, to: edited2, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.title == "New Title")
        #expect(def.priority == 5)
    }

    // MARK: - Same field: last commit wins

    @Test("Two concurrent edits on same field: last successful commit wins")
    func sameSFieldLastCommitWins() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[1]

        // Editor 1 prepares title change
        let orig1 = SharedAttributes(edited)
        var change1 = orig1
        change1.title = "Editor 1 Title"
        let edit1 = TaskEdit(originalShared: orig1, editedShared: change1)

        // Editor 2 prepares title change (stale baseline)
        let orig2 = SharedAttributes(edited)
        var change2 = orig2
        change2.title = "Editor 2 Title"
        let edit2 = TaskEdit(originalShared: orig2, editedShared: change2)

        // Commit both in order
        try TaskEditCommit.commit(edit1, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)
        try TaskEditCommit.commit(edit2, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.title == "Editor 2 Title")
    }

    // MARK: - Stale no-op preserves another editor's rule change

    @Test("Stale no-op commit does not revert another editor's rule change")
    func staleNoOpPreservesRuleChange() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[0]

        // Editor 1: prepare a rule change
        let orig1 = SharedAttributes(edited)
        let newRule = RecurrenceRule(frequency: .weekly, startDate: date(2026, 1, 1, c))
        let edit1 = TaskEdit(originalShared: orig1, editedShared: orig1, rule: .replace(newRule))

        // Editor 2: prepare no-op (no changes)
        let orig2 = SharedAttributes(edited)
        let edit2 = TaskEdit(originalShared: orig2, editedShared: orig2)

        // Commit editor 1 with rule change
        try TaskEditCommit.commit(edit1, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)
        #expect(def.recurrence?.frequency == .weekly)

        // Commit stale no-op (should do nothing)
        let scheduleChanged = try TaskEditCommit.commit(edit2, to: edited, context: context,
                                                        today: date(2026, 1, 5, c),
                                                        horizon: date(2026, 2, 1, c), calendar: c)

        #expect(!scheduleChanged)
        #expect(def.recurrence?.frequency == .weekly)  // Still weekly
    }

    // MARK: - Stale title-only edit does not revert rule change

    @Test("Stale editor changing only title does not revert other editor's rule change")
    func staleTitleOnlyDoesNotRevertRule() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[2]

        // Editor 1: change rule
        let orig1 = SharedAttributes(edited)
        let newRule = RecurrenceRule(frequency: .weekly, startDate: date(2026, 1, 1, c))
        let edit1 = TaskEdit(originalShared: orig1, editedShared: orig1, rule: .replace(newRule))

        // Editor 2 (stale): change only title
        let orig2 = SharedAttributes(edited)
        var change2 = orig2
        change2.title = "Renamed"
        let edit2 = TaskEdit(originalShared: orig2, editedShared: change2)

        // Commit rule change first
        try TaskEditCommit.commit(edit1, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Commit stale title-only
        try TaskEditCommit.commit(edit2, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.title == "Renamed")
        #expect(def.recurrence?.frequency == .weekly)  // Rule intact
    }

    // MARK: - Two stale startSeries drafts: only first succeeds

    @Test("Two stale startSeries on same one-off: only first creates definition, second throws")
    func twoStartSeriesDraftsFirstWins() throws {
        let context = makeContext()
        let c = cal()

        // Create a one-off task
        let oneOff = TaskItem(title: "One-off", dayKey: dayKey(2026, 1, 5))
        oneOff.priority = 2
        context.insert(oneOff)
        try context.save()

        let oneOffId = oneOff.id

        // Editor 1 prepares startSeries with daily rule
        let orig1 = SharedAttributes(oneOff)
        let rule1 = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 5, c))
        let edit1 = TaskEdit(originalShared: orig1, editedShared: orig1, rule: .startSeries(rule1))

        // Editor 2 prepares startSeries with weekly rule (stale, same task)
        let orig2 = SharedAttributes(oneOff)
        let rule2 = RecurrenceRule(frequency: .weekly, startDate: date(2026, 1, 5, c))
        let edit2 = TaskEdit(originalShared: orig2, editedShared: orig2, rule: .startSeries(rule2))

        // Commit editor 1
        try TaskEditCommit.commit(edit1, to: oneOff, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(oneOff.templateID != nil)
        let definitionId1 = oneOff.templateID
        try context.save()

        // Try to commit editor 2 (should fail: task already in a series)
        var didThrow = false
        var threwCorrectError = false
        do {
            try TaskEditCommit.commit(edit2, to: oneOff, context: context, today: date(2026, 1, 5, c),
                                      horizon: date(2026, 2, 1, c), calendar: c)
        } catch RecurrenceMaterializer.LifecycleError.cannotStartSeries {
            didThrow = true
            threwCorrectError = true
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(threwCorrectError)
        // Seed's templateID unchanged
        #expect(oneOff.templateID == definitionId1)
        // Nothing else changed
        #expect(oneOff.priority == 2)
        #expect(oneOff.id == oneOffId)
    }

    // MARK: - Stale alarm-only enable after time removed (finding 12)

    @Test("Stale alarm-only enable after another editor removed time leaves no invalid state")
    func staleAlarmEnableAfterTimeRemoved() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[2]

        // Editor 1 prepares to remove time
        let orig1 = SharedAttributes(edited)
        var change1 = orig1
        change1.timeMinutes = nil
        let edit1 = TaskEdit(originalShared: orig1, editedShared: change1)

        // Editor 2 prepares to enable alarm (stale baseline still has time)
        let orig2 = SharedAttributes(edited)
        var change2 = orig2
        change2.alarmEnabled = true
        let edit2 = TaskEdit(originalShared: orig2, editedShared: change2)

        // Commit editor 1: remove time
        try TaskEditCommit.commit(edit1, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.timeMinutes == nil)
        #expect(!def.alarmEnabled)  // Time removal also clears alarm

        // Commit editor 2: stale alarm enable
        try TaskEditCommit.commit(edit2, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // No row should have alarm enabled without time
        let allRows = try context.fetch(FetchDescriptor<TaskItem>())
        let badStateFound = allRows.contains { $0.alarmEnabled && $0.timeMinutes == nil }
        #expect(!badStateFound)
    }

    // MARK: - Stale title + priority, different changes

    @Test("Two stale concurrent edits: editor 1 title + priority, editor 2 title only")
    func staleConcurrentMixedEdits() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[1]

        // Editor 1 captures and changes both title and priority
        let orig1 = SharedAttributes(edited)
        var change1 = orig1
        change1.title = "Editor 1 Title"
        change1.priority = 10
        let edit1 = TaskEdit(originalShared: orig1, editedShared: change1)

        // Editor 2 captures same baseline and changes only title
        let orig2 = SharedAttributes(edited)
        var change2 = orig2
        change2.title = "Editor 2 Title"
        let edit2 = TaskEdit(originalShared: orig2, editedShared: change2)

        // Commit both
        try TaskEditCommit.commit(edit1, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)
        try TaskEditCommit.commit(edit2, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Title from editor 2 (last), priority from editor 1 (first, unchanged by editor 2)
        #expect(def.title == "Editor 2 Title")
        #expect(def.priority == 10)
    }

    // MARK: - Stale edit with critical flag (this is intentionally a no-op on critical)

    @Test("Stale editor on same field: if not actually edited, change from other editor persists")
    func staleCriticalFlagNoOpChange() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[3]

        // Editor 1: disable critical and change title
        let orig1 = SharedAttributes(edited)
        var change1 = orig1
        change1.isCritical = false
        change1.title = "Editor 1"
        let edit1 = TaskEdit(originalShared: orig1, editedShared: change1)

        // Editor 2 (stale): only change title to something else, keep critical as-is
        // This is the key: orig2.isCritical will equal change2.isCritical, so no change written
        let orig2 = SharedAttributes(edited)
        var change2 = orig2
        change2.title = "Editor 2"
        // Deliberately not changing isCritical
        let edit2 = TaskEdit(originalShared: orig2, editedShared: change2)

        // Commit editor 1
        try TaskEditCommit.commit(edit1, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(!def.isCritical)
        #expect(def.title == "Editor 1")

        // Commit stale editor 2: only change title
        try TaskEditCommit.commit(edit2, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Critical should stay as editor 1 left it (false)
        #expect(!def.isCritical)
        // Title from editor 2
        #expect(def.title == "Editor 2")
    }
}
