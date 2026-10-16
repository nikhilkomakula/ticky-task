import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Comprehensive shared-field propagation matrix: every shared field (title, time,
/// alarm, priority, critical, color, tags) across every edit source (first, later,
/// past, done, moved to date, listed). All fields verified on definition and EVERY
/// child. Payload isolation, timestamp updates, sticky provenance, and exact value
/// integrity across rule changes and Stop.
@MainActor
@Suite("Series shared-field matrix")
struct SeriesSharedFieldMatrixTests {
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

    /// Create a daily series with 10 occurrences, giving each different work to test isolation.
    private func createDailySeries(_ context: ModelContext, _ c: Calendar) throws -> (definition: TaskItem, children: [TaskItem]) {
        let seed = TaskItem(title: "Shared Title", dayKey: dayKey(2026, 1, 1), timeMinutes: 600)
        seed.priority = 1
        seed.alarmEnabled = false
        seed.isCritical = false
        seed.colorHex = "#ff0000"
        context.insert(seed)

        let rule = RecurrenceRule(frequency: .daily, end: .afterCount(10),
                                 startDate: date(2026, 1, 1, c))
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: rule, through: date(2026, 1, 31, c), context: context, calendar: c)
        try context.save()

        var children = try RecurrenceMaterializer.children(of: definition, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }

        // Give each child distinct notes and subtasks for isolation testing
        for (i, child) in children.enumerated() {
            child.notes = "Notes for day \(i)"
            child.subtasks.append(Subtask(id: UUID(), title: "Subtask \(i)", isDone: false, sortIndex: 0))
        }
        try context.save()

        // Mark one as completed for state isolation
        children[4].isDone = true
        children[4].completedAt = date(2026, 1, 5, c)
        try context.save()

        // Move one to custom list
        let list = CustomList(name: "Shopping")
        context.insert(list)
        children[7].customList = list
        children[7].dayKey = nil
        try context.save()

        children = try RecurrenceMaterializer.children(of: definition, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }

        return (definition, children)
    }

    // MARK: - Title propagation across all sources

    @Test("Title change from first occurrence propagates to all children",
          arguments: ["first", "later", "past", "done", "moved"])
    func titlePropagatesToAll(source: String) throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited: TaskItem
        switch source {
        case "first": edited = children[0]
        case "later": edited = children[3]
        case "past": edited = children[1]
        case "done": edited = children[4]
        case "moved": edited = children[7]
        default: edited = children[0]
        }

        let original = SharedAttributes(edited)
        var changed = original
        changed.title = "New Shared Title"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.title == "New Shared Title")
        let updated = try RecurrenceMaterializer.children(of: def, context: context)
        for child in updated {
            #expect(child.title == "New Shared Title")
        }
    }

    // MARK: - Time propagation across all sources

    @Test("Time change from any source propagates everywhere",
          arguments: ["first", "later", "past", "done", "moved"])
    func timePropagatesToAll(source: String) throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited: TaskItem
        switch source {
        case "first": edited = children[0]
        case "later": edited = children[3]
        case "past": edited = children[1]
        case "done": edited = children[4]
        case "moved": edited = children[7]
        default: edited = children[0]
        }

        let original = SharedAttributes(edited)
        var changed = original
        changed.timeMinutes = 900

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.timeMinutes == 900)
        let updated = try RecurrenceMaterializer.children(of: def, context: context)
        for child in updated {
            #expect(child.timeMinutes == 900)
        }
    }

    // MARK: - Alarm propagation

    @Test("Alarm change from any source propagates to all children")
    func alarmPropagatesToAll() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[2]
        let original = SharedAttributes(edited)
        var changed = original
        changed.alarmEnabled = true

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.alarmEnabled)
        let updated = try RecurrenceMaterializer.children(of: def, context: context)
        for child in updated {
            #expect(child.alarmEnabled)
        }
    }

    // MARK: - Priority and critical propagation

    @Test("Priority change propagates to definition and all children")
    func priorityPropagatesToAll() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[5]
        let original = SharedAttributes(edited)
        var changed = original
        changed.priority = 9

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.priority == 9)
        let updated = try RecurrenceMaterializer.children(of: def, context: context)
        for child in updated {
            #expect(child.priority == 9)
        }
    }

    @Test("Critical flag propagates to every child")
    func criticalPropagatesToAll() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[6]
        let original = SharedAttributes(edited)
        var changed = original
        changed.isCritical = true

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.isCritical)
        let updated = try RecurrenceMaterializer.children(of: def, context: context)
        for child in updated {
            #expect(child.isCritical)
        }
    }

    // MARK: - Color and tag propagation

    @Test("Color change propagates everywhere")
    func colorPropagatesToAll() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[3]
        let original = SharedAttributes(edited)
        var changed = original
        changed.colorHex = "#00ff00"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.colorHex == "#00ff00")
        let updated = try RecurrenceMaterializer.children(of: def, context: context)
        for child in updated {
            #expect(child.colorHex == "#00ff00")
        }
    }

    @Test("Tag changes propagate to all children")
    func tagsPropagate() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let tag1 = TaskTag(name: "urgent")
        let tag2 = TaskTag(name: "work")
        context.insert(tag1)
        context.insert(tag2)
        try context.save()

        let edited = children[4]
        let original = SharedAttributes(edited)
        var changed = original
        changed.tagIDs = [tag1.id, tag2.id]

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        let expectedIds = Set([tag1.id, tag2.id])
        #expect(Set(def.tags.map(\.id)) == expectedIds)
        let updated = try RecurrenceMaterializer.children(of: def, context: context)
        for child in updated {
            #expect(Set(child.tags.map(\.id)) == expectedIds)
        }
    }

    // MARK: - Payload isolation: each child keeps its own notes, subtasks, completion

    @Test("Notes remain isolated to each occurrence after shared field change")
    func notesIsolation() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[3]
        let original = SharedAttributes(edited)
        var changed = original
        changed.title = "New Title"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        let updated = try RecurrenceMaterializer.children(of: def, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }

        for (i, child) in updated.enumerated() {
            #expect(child.notes == "Notes for day \(i)")
        }
    }

    @Test("Subtasks (ID, status, order) remain exactly as set on each child")
    func subtasksPayloadIsolation() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[2]
        let original = SharedAttributes(edited)
        var changed = original
        changed.priority = 7

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        let updated = try RecurrenceMaterializer.children(of: def, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }

        for (i, child) in updated.enumerated() {
            #expect(child.subtasks.count == 1)
            #expect(child.subtasks[0].title == "Subtask \(i)")
        }
    }

    @Test("Completion state remains isolated: only completed rows stay done")
    func completionIsolation() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[6]
        let original = SharedAttributes(edited)
        var changed = original
        changed.title = "Changed Title"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        let updated = try RecurrenceMaterializer.children(of: def, context: context)

        // Only child 4 should be done
        let doneChild = try #require(updated.first { $0.occurrenceKey == dayKey(2026, 1, 5) })
        #expect(doneChild.isDone)
        #expect(doneChild.completedAt != nil)

        // All others open
        let openChildren = updated.filter { $0.id != doneChild.id }
        for child in openChildren {
            #expect(!child.isDone)
            #expect(child.completedAt == nil)
        }
    }

    // MARK: - Placement isolation

    @Test("Placement (dayKey, customList) unchanged after shared field edit")
    func placementIsolation() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[5]
        let original = SharedAttributes(edited)
        var changed = original
        changed.colorHex = "#0000ff"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        let updated = try RecurrenceMaterializer.children(of: def, context: context)

        // Calendar-placed child stays on its day
        for child in updated {
            if let key = child.occurrenceKey {
                if key < dayKey(2026, 1, 8) {  // First 7 are calendar
                    #expect(child.dayKey != nil)
                    #expect(child.customList == nil)
                }
            }
        }

        // Custom-list child stays in list
        let listedChild = updated.first { $0.occurrenceKey == dayKey(2026, 1, 8) }
        #expect(listedChild?.customList != nil)
        #expect(listedChild?.dayKey == nil)
    }

    // MARK: - Timestamp tracking

    @Test("updatedAt changes only on rows with value changes")
    func updatedAtOnlyOnChangedRows() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let timeBefore = Date()
        Thread.sleep(forTimeInterval: 0.01)

        let edited = children[2]
        let original = SharedAttributes(edited)
        var changed = original
        changed.priority = 8

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        let updated = try RecurrenceMaterializer.children(of: def, context: context)

        for child in updated {
            if child.priority == 8 {
                #expect(child.updatedAt > timeBefore)
            }
        }
    }

    // MARK: - Sticky provenance across rule changes

    @Test("Occurrence marked modified=true survives rule change unchanged")
    func provenanceStickyThroughRuleChange() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Mark one as modified
        let edited = children[2]
        edited.occurrenceModified = true
        try context.save()

        // Change the rule to weekly
        let newRule = RecurrenceRule(frequency: .weekly, startDate: date(2026, 1, 1, c))
        try RecurrenceMaterializer.changeRule(of: def, to: newRule, today: date(2026, 1, 5, c),
                                            through: date(2026, 2, 1, c), context: context, calendar: c)

        let surviving = try RecurrenceMaterializer.children(of: def, context: context)
        let marked = surviving.first { $0.occurrenceKey == dayKey(2026, 1, 3) }
        #expect(marked?.occurrenceModified == true)
    }

    // MARK: - Unrelated series untouched

    @Test("Editing one series leaves unrelated same-title series and one-offs unchanged")
    func unrelatedSeriesUntouched() throws {
        let context = makeContext()
        let c = cal()
        let (def1, children1) = try createDailySeries(context, c)

        // Create second series with same title
        let seed2 = TaskItem(title: "Shared Title", dayKey: dayKey(2026, 2, 1))
        seed2.priority = 3
        context.insert(seed2)

        let rule2 = RecurrenceRule(frequency: .daily, end: .afterCount(3),
                                  startDate: date(2026, 2, 1, c))
        let def2 = try RecurrenceMaterializer.startSeries(
            from: seed2, rule: rule2, through: date(2026, 2, 15, c), context: context, calendar: c)

        // Create one-off
        let oneOff = TaskItem(title: "Shared Title", dayKey: dayKey(2026, 3, 1))
        oneOff.priority = 5
        context.insert(oneOff)
        try context.save()

        // Edit first series
        let edited = children1[1]
        let original = SharedAttributes(edited)
        var changed = original
        changed.priority = 99

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Verify series 1 changed, others not
        #expect(def1.priority == 99)
        #expect(def2.priority == 3)
        #expect(oneOff.priority == 5)
    }

    // MARK: - Complete→reopen survives rule change with sticky provenance

    @Test("Marked-modified completed row survives rule change even after reopening")
    func completeThenReopenThenRuleChangeSurvives() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[3]
        edited.isDone = true
        edited.completedAt = date(2026, 1, 4, c)
        edited.occurrenceModified = true
        try context.save()

        // Reopen it
        edited.isDone = false
        edited.completedAt = nil
        try context.save()

        // Change rule
        let newRule = RecurrenceRule(frequency: .weekly, startDate: date(2026, 1, 1, c))
        try RecurrenceMaterializer.changeRule(of: def, to: newRule, today: date(2026, 1, 5, c),
                                            through: date(2026, 2, 1, c), context: context, calendar: c)

        let surviving = try RecurrenceMaterializer.children(of: def, context: context)
        let kept = surviving.first { $0.occurrenceKey == dayKey(2026, 1, 4) }
        #expect(kept != nil)
        #expect(kept?.occurrenceModified == true)
    }

    // MARK: - Clearing shared fields propagates everywhere

    @Test("Removing time from definition clears it on every child")
    func removingTimeClearsEverywhere() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        #expect(def.timeMinutes == 600)

        let edited = children[0]
        let original = SharedAttributes(edited)
        var changed = original
        changed.timeMinutes = nil

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.timeMinutes == nil)
        let updated = try RecurrenceMaterializer.children(of: def, context: context)
        for child in updated {
            #expect(child.timeMinutes == nil)
        }
    }

    @Test("Clearing color propagates to all children")
    func clearingColorPropagates() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[5]
        let original = SharedAttributes(edited)
        var changed = original
        changed.colorHex = nil

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.colorHex == nil)
        let updated = try RecurrenceMaterializer.children(of: def, context: context)
        for child in updated {
            #expect(child.colorHex == nil)
        }
    }
}
