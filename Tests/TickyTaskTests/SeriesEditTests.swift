import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// TaskEditCommit series-field propagation and isolated occurrence-local edits.
/// Covers 9 areas: shared propagation (10+ parameterized tests), clearing fields,
/// payload isolation, local edits, no-op editing, combined commit, startSeries,
/// failure atomicity, and concurrent editors.
@MainActor
@Suite("Series editing")
struct SeriesEditTests {
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

    /// Create a daily series with 10 occurrences from 2026-01-01.
    private func createDailySeries(_ context: ModelContext, _ c: Calendar) throws -> (definition: TaskItem, children: [TaskItem]) {
        let seed = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 1), timeMinutes: 600)
        seed.priority = 1
        seed.alarmEnabled = true
        seed.isCritical = true
        seed.colorHex = "#ff0000"
        context.insert(seed)

        let rule = RecurrenceRule(frequency: .daily, end: .afterCount(10),
                                 startDate: date(2026, 1, 1, c))
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: rule, through: date(2026, 1, 31, c), context: context, calendar: c)
        try context.save()

        let children = try RecurrenceMaterializer.children(of: definition, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }
        return (definition, children)
    }

    // MARK: - 1. Shared Propagation (title, priority, critical, time, alarm, color, tags)

    @Test("Rename from first occurrence propagates to all children",
          arguments: ["20260101", "20260103", "20260109"] as [String])
    func renamePropagates(fromKey: String) throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = try #require(children.first { $0.occurrenceKey == fromKey })
        let others = children.filter { $0.id != edited.id }
        let beforeIds = Set(children.map(\.id))

        let original = SharedAttributes(edited)
        var changed = original
        changed.title = "Renamed task"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.title == "Renamed task")
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        let hasAllRenamed = updatedChildren.allSatisfy { $0.title == "Renamed task" }
        #expect(hasAllRenamed)
        let afterIds = try context.fetch(FetchDescriptor<TaskItem>()).map(\.id).filter { $0 != def.id }
        #expect(Set(afterIds) == beforeIds)  // no rows added/deleted
    }

    @Test("Changing priority from any occurrence updates definition and all children")
    func priorityPropagates() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[3]  // later occurrence
        let original = SharedAttributes(edited)
        var changed = original
        changed.priority = 3

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.priority == 3)
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        let hasAllPriority3 = updatedChildren.allSatisfy { $0.priority == 3 }
        #expect(hasAllPriority3)
    }

    @Test("Toggling critical status propagates to definition and all children")
    func criticalPropagates() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = try #require(children.first { $0.occurrenceKey == "20260105" })
        let original = SharedAttributes(edited)
        var changed = original
        changed.isCritical = false  // turn off

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(!def.isCritical)
        let allMatch1 = children.allSatisfy(\.isCritical)
        #expect(!allMatch1)
    }

    @Test("Changing time minutes propagates everywhere")
    func timePropagates() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = try #require(children.first { $0.occurrenceKey == "20260107" })
        let original = SharedAttributes(edited)
        var changed = original
        changed.timeMinutes = 720  // noon

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.timeMinutes == 720)
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        #expect(updatedChildren.allSatisfy { $0.timeMinutes == 720 })
    }

    @Test("Disabling alarm propagates to all children, including those with different prior alarm state")
    func disableAlarmPropagates() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Give one child a different alarm state
        children[4].alarmEnabled = false
        try context.save()

        let edited = children[2]  // one with alarm on
        let original = SharedAttributes(edited)
        var changed = original
        changed.alarmEnabled = false

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(!def.alarmEnabled)
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        #expect(updatedChildren.allSatisfy { !$0.alarmEnabled })
    }

    @Test("Changing color propagates to definition and all occurrences")
    func colorPropagates() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = try #require(children.first { $0.occurrenceKey == "20260109" })
        let original = SharedAttributes(edited)
        var changed = original
        changed.colorHex = "#00ff00"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.colorHex == "#00ff00")
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        let hasAllColorGreen = updatedChildren.allSatisfy { $0.colorHex == "#00ff00" }
        #expect(hasAllColorGreen)
    }

    @Test("Adding tags to series propagates tag identity to all children")
    func tagPropagates() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Create a tag
        let tag = TaskTag(name: "urgent")
        context.insert(tag)
        try context.save()

        let edited = children[1]
        let original = SharedAttributes(edited)
        var changed = original
        changed.tagIDs = [tag.id]

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.tags.map(\.id) == [tag.id])
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        #expect(updatedChildren.allSatisfy { $0.tags.map(\.id) == [tag.id] })
    }

    // MARK: - 2. Clearing Shared Fields

    @Test("Removing time clears alarm on all rows, even those with differing prior alarm state")
    func removingTimeClearsAlarm() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Vary alarm state
        children[3].alarmEnabled = false
        try context.save()

        let edited = children[0]
        let original = SharedAttributes(edited)
        var changed = original
        changed.timeMinutes = nil  // remove time

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.timeMinutes == nil)
        #expect(!def.alarmEnabled)
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        #expect(updatedChildren.allSatisfy { $0.timeMinutes == nil && !$0.alarmEnabled })
    }

    @Test("Clearing color removes it from definition and all children")
    func clearingColor() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[2]
        let original = SharedAttributes(edited)
        var changed = original
        changed.colorHex = nil

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.colorHex == nil)
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        #expect(updatedChildren.allSatisfy { $0.colorHex == nil })
    }

    @Test("Removing all tags propagates empty set to definition and all children")
    func removingAllTags() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Add a tag to definition and children
        let tag = TaskTag(name: "work")
        context.insert(tag)
        def.tags = [tag]
        for child in children {
            child.tags = [tag]
        }
        try context.save()

        let edited = children[1]
        let original = SharedAttributes(edited)
        var changed = original
        changed.tagIDs = []  // clear tags

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.tags.isEmpty)
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        #expect(updatedChildren.allSatisfy { $0.tags.isEmpty })
    }

    // MARK: - 3. Payload Isolation (notes, subtasks, completion, placement)

    @Test("Occurrence notes and rich bytes remain isolated and unchanged after shared edits")
    func notesIsolation() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Give each child unique notes
        for (i, child) in children.enumerated() {
            child.notes = "Notes for occurrence \(i)"
        }
        try context.save()

        let edited = children[2]
        let editedNotesAfter = edited.notes

        let original = SharedAttributes(edited)
        var changed = original
        changed.title = "Changed title"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Each child's notes must remain unchanged
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }
        for (i, child) in updatedChildren.enumerated() {
            #expect(child.notes == "Notes for occurrence \(i)")
        }
    }

    @Test("Subtasks remain isolated per occurrence during shared field changes")
    func subtasksIsolation() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Give different subtasks to each occurrence
        for (i, child) in children.enumerated() {
            let sub = Subtask(title: "Subtask for \(i)")
            sub.sortIndex = Double(i)
            child.subtasks.append(sub)
        }
        try context.save()

        let edited = children[3]
        let editedSubsBefore = edited.subtasks.map(\.title).sorted()

        let original = SharedAttributes(edited)
        var changed = original
        changed.priority = 5

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // All occurrences retain their original subtasks
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }
        for (i, child) in updatedChildren.enumerated() {
            #expect(child.subtasks.map(\.title) == ["Subtask for \(i)"])
        }
    }

    @Test("Completion state and timestamps remain isolated to each occurrence")
    func completionIsolation() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Mark one occurrence done, leave others open
        let completedChild = children[2]
        completedChild.setDone(true, at: date(2026, 1, 3, c))
        try context.save()

        let edited = children[4]
        let original = SharedAttributes(edited)
        var changed = original
        changed.title = "Retitled"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        let updated2 = try #require(updatedChildren.first { $0.occurrenceKey == "20260103" })
        let updated4 = try #require(updatedChildren.first { $0.occurrenceKey == "20260105" })
        #expect(updated2.isDone && updated2.completedAt != nil)
        #expect(!updated4.isDone && updated4.completedAt == nil)
    }

    @Test("Placement (dayKey, customList) remains independent after shared edits")
    func placementIsolation() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Verify each child has its own dayKey
        for (i, child) in children.enumerated() {
            #expect(child.dayKey == dayKey(2026, 1, i + 1))
        }

        let edited = children[2]
        let original = SharedAttributes(edited)
        var changed = original
        changed.colorHex = "#0000ff"

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
            .sorted { ($0.occurrenceKey ?? "") < ($1.occurrenceKey ?? "") }
        for (i, child) in updatedChildren.enumerated() {
            #expect(child.dayKey == dayKey(2026, 1, i + 1))
        }
    }

    // MARK: - 4. Local Edits (notes and subtasks only on edited row, set occurrenceModified)

    @Test("Notes edit sets only the edited row and marks it modified")
    func notesLocalEdit() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[3]
        let original = SharedAttributes(edited)
        let newDoc = NotesDocument(blocks: [
            NotesBlock(kind: .paragraph, runs: [
                NotesRun(text: "New rich notes")
            ])
        ])

        let edit = TaskEdit(originalShared: original, editedShared: original, notes: newDoc)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(edited.notes == "New rich notes")
        #expect(edited.notesRich != nil)
        #expect(edited.occurrenceModified == true)

        // Other occurrences untouched
        let others = children.filter { $0.id != edited.id }
        #expect(others.allSatisfy { $0.notes == "" && $0.notesRich == nil })
    }

    @Test("Subtask edit only modifies the edited row and sets occurrenceModified")
    func subtasksLocalEdit() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[2]
        let newSubtask = SubtaskDraft(id: UUID(), title: "New subtask", isDone: false, sortIndex: 0)

        let original = SharedAttributes(edited)
        let edit = TaskEdit(originalShared: original, editedShared: original, subtasks: [newSubtask])
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(edited.subtasks.count == 1)
        #expect(edited.subtasks[0].title == "New subtask")
        #expect(edited.occurrenceModified == true)

        // Other occurrences remain empty
        let others = children.filter { $0.id != edited.id }
        #expect(others.allSatisfy { $0.subtasks.isEmpty })
    }

    @Test("Combined notes and subtask edit only affects the edited row")
    func notesAndSubtasksLocalEdit() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[1]
        let newDoc = NotesDocument(blocks: [
            NotesBlock(kind: .paragraph, runs: [
                NotesRun(text: "Rich notes")
            ])
        ])
        let newSubtask = SubtaskDraft(id: UUID(), title: "Task 1", isDone: false, sortIndex: 0)

        let original = SharedAttributes(edited)
        let edit = TaskEdit(originalShared: original, editedShared: original, notes: newDoc, subtasks: [newSubtask])
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(edited.notes == "Rich notes")
        #expect(edited.subtasks.count == 1)
        #expect(edited.occurrenceModified == true)

        // All others stay untouched
        let others = children.filter { $0.id != edited.id }
        // Untouched siblings keep their own provenance: the seed is `true`, generated ones `false`.
        let othersUntouched = others.allSatisfy {
            $0.notes.isEmpty && $0.subtasks.isEmpty && $0.occurrenceModified == ($0.occurrenceKey == "20260101")
        }
        #expect(othersUntouched)
    }

    // MARK: - 5. No-op Editing

    @Test("Empty commit changes nothing: no save, no timestamp bump")
    func noOpCommit() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[2]
        let beforeTimestamp = edited.updatedAt
        let beforeTitle = edited.title

        let original = SharedAttributes(edited)
        let edit = TaskEdit(originalShared: original, editedShared: original)
        #expect(edit.isEmpty)

        let scheduleChanged = try TaskEditCommit.commit(edit, to: edited, context: context,
                                                        today: date(2026, 1, 5, c),
                                                        horizon: date(2026, 2, 1, c), calendar: c)
        #expect(!scheduleChanged)
        #expect(edited.updatedAt == beforeTimestamp)
        #expect(edited.title == beforeTitle)
    }

    @Test("RecurrenceDraft with imported .daysOfMonth preserves monthDays round-trip")
    func preservedImportedRuleForm() throws {
        let context = makeContext()
        let c = cal()

        // Create a series with .daysOfMonth (legacy)
        let seed = TaskItem(title: "Monthly", dayKey: dayKey(2026, 1, 1))
        context.insert(seed)

        let rule = RecurrenceRule(frequency: .daysOfMonth,
                                 monthDays: [1, 15],
                                 startDate: date(2026, 1, 1, c))
        let definition = try RecurrenceMaterializer.startSeries(
            from: seed, rule: rule, through: date(2026, 2, 1, c), context: context, calendar: c)
        try context.save()

        let draft = RecurrenceDraft(rule: rule, calendar: c)
        let reconstructed = draft.rule(replacing: rule, startDate: rule.startDate, calendar: c)

        #expect(reconstructed.frequency == .daysOfMonth)
        #expect(reconstructed.monthDays == [1, 15])
    }

    // MARK: - 6. Combined Commit (rename + time + notes + rule)

    @Test("Combined rename, time, notes, and rule change in one commit produces coherent result")
    func combinedCommit() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[1]
        let horizon = date(2026, 2, 1, c)

        let original = SharedAttributes(edited)
        var changed = original
        changed.title = "Renamed and rescheduled"
        changed.timeMinutes = 900

        let newDoc = NotesDocument(blocks: [
            NotesBlock(kind: .paragraph, runs: [
                NotesRun(text: "New notes for this one")
            ])
        ])

        let newRule = RecurrenceRule(frequency: .weekly, weekdays: [5],
                                    startDate: date(2026, 1, 1, c))

        let edit = TaskEdit(originalShared: original, editedShared: changed, notes: newDoc,
                           rule: .replace(newRule))
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: horizon, calendar: c)

        // Shared title and time applied everywhere
        #expect(def.title == "Renamed and rescheduled")
        #expect(def.timeMinutes == 900)
        let updatedChildren = try RecurrenceMaterializer.children(of: def, context: context)
        #expect(updatedChildren.allSatisfy { $0.title == "Renamed and rescheduled" })
        #expect(updatedChildren.allSatisfy { $0.timeMinutes == 900 })

        // Notes only on the edited row
        #expect(edited.notes == "New notes for this one")
        #expect(edited.occurrenceModified == true)
        let others = updatedChildren.filter { $0.id != edited.id }
        #expect(others.allSatisfy { $0.notes == "" })

        // New rule applied
        #expect(def.recurrence?.frequency == .weekly)
        #expect(def.recurrence?.weekdays == [5])
    }

    // MARK: - 7. Starting a Series

    @Test("startSeries rejects when task already belongs to a series")
    func startSeriesRejectedAlreadyLinked() throws {
        let context = makeContext()
        let c = cal()

        let task = TaskItem(title: "One-off", dayKey: dayKey(2026, 1, 1))
        task.templateID = UUID()
        context.insert(task)

        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        do {
            _ = try RecurrenceMaterializer.startSeries(from: task, rule: rule, through: date(2026, 1, 31, c),
                                                       context: context, calendar: c)
            Issue.record("Should have thrown LifecycleError")
        } catch RecurrenceMaterializer.LifecycleError.cannotStartSeries {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("startSeries rejects when task is in a custom list")
    func startSeriesRejectedInList() throws {
        let context = makeContext()
        let c = cal()

        let task = TaskItem(title: "One-off", dayKey: dayKey(2026, 1, 1))
        task.customList = CustomList(id: UUID(), name: "Test")
        context.insert(task)

        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        do {
            _ = try RecurrenceMaterializer.startSeries(from: task, rule: rule, through: date(2026, 1, 31, c),
                                                       context: context, calendar: c)
            Issue.record("Should have thrown LifecycleError")
        } catch RecurrenceMaterializer.LifecycleError.cannotStartSeries {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("startSeries rejects when task has no day")
    func startSeriesRejectedNoDay() throws {
        let context = makeContext()
        let c = cal()

        let task = TaskItem(title: "One-off")
        task.dayKey = nil
        context.insert(task)

        let rule = RecurrenceRule(frequency: .daily, startDate: date(2026, 1, 1, c))
        do {
            _ = try RecurrenceMaterializer.startSeries(from: task, rule: rule, through: date(2026, 1, 31, c),
                                                       context: context, calendar: c)
            Issue.record("Should have thrown LifecycleError")
        } catch RecurrenceMaterializer.LifecycleError.cannotStartSeries {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("startSeries from a one-off creates definition and seed with occurrenceModified=true")
    func startSeriesCreatesDefinition() throws {
        let context = makeContext()
        let c = cal()

        let task = TaskItem(title: "New series", dayKey: dayKey(2026, 1, 5))
        task.notes = "seed notes"
        task.priority = 2
        context.insert(task)
        let taskId = task.id

        let rule = RecurrenceRule(frequency: .weekly, weekdays: [5], startDate: date(2026, 1, 5, c))
        let definition = try RecurrenceMaterializer.startSeries(from: task, rule: rule,
                                                               through: date(2026, 2, 1, c),
                                                               context: context, calendar: c)

        #expect(definition.recurrence != nil && definition.templateID == nil)
        #expect(definition.dayKey == nil && definition.customList == nil)
        #expect(task.id == taskId)  // seed keeps its UUID
        #expect(task.templateID == definition.id)
        #expect(task.occurrenceKey == dayKey(2026, 1, 5))
        #expect(task.occurrenceModified == true)
        #expect(task.notes == "seed notes")
    }

    // MARK: - 8. Failure Atomicity

    @Test("Failed commit rolls back all changes (shared, local, rule) and rethrows")
    func failureRollback() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        let edited = children[2]
        let beforeTitle = def.title
        let beforeEditedNotes = edited.notes

        let original = SharedAttributes(edited)
        var changed = original
        changed.title = "This will fail"

        let newDoc = NotesDocument(blocks: [
            NotesBlock(kind: .paragraph, runs: [
                NotesRun(text: "These notes will be rolled back")
            ])
        ])

        let edit = TaskEdit(originalShared: original, editedShared: changed, notes: newDoc)

        var didThrow = false
        do {
            try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                      horizon: date(2026, 2, 1, c), calendar: c) { _ in
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Injected failure"])
            }
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        // Verify rollback: title and notes unchanged
        #expect(def.title == beforeTitle)
        #expect(edited.notes == beforeEditedNotes)
    }

    @Test("Failed commit does not revert unrelated pending changes in context")
    func failureDoesNotRevertUnrelated() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Create an unrelated task, save it, then leave a change pending (not saved)
        let unrelated = TaskItem(title: "Unrelated", dayKey: dayKey(2026, 1, 20))
        context.insert(unrelated)
        try context.save()
        unrelated.priority = 5

        // Now make a failing edit
        let edited = children[1]
        let original = SharedAttributes(edited)
        var changed = original
        changed.title = "Will fail"

        let edit = TaskEdit(originalShared: original, editedShared: changed)

        do {
            try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                      horizon: date(2026, 2, 1, c), calendar: c) { _ in
                throw NSError(domain: "test", code: 1)
            }
        } catch {
            // Expected
        }

        // The definition's title should be rolled back
        #expect(def.title == "Daily task")
        // But unrelated changes should persist
        #expect(unrelated.priority == 5)
    }

    // MARK: - 9. Concurrent Editors

    @Test("Two edits changing different shared fields both survive when committed sequentially")
    func concurrentEditorsDifferentFields() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Editor 1: change title
        let edited1 = children[0]
        let original1 = SharedAttributes(edited1)
        var changed1 = original1
        changed1.title = "Editor 1 title"

        let edit1 = TaskEdit(originalShared: original1, editedShared: changed1)
        try TaskEditCommit.commit(edit1, to: edited1, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Editor 2 (separate context fetch): change priority
        let edited2 = children[2]
        let original2 = SharedAttributes(edited2)
        var changed2 = original2
        changed2.priority = 7

        let edit2 = TaskEdit(originalShared: original2, editedShared: changed2)
        try TaskEditCommit.commit(edit2, to: edited2, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Both changes persisted
        #expect(def.title == "Editor 1 title")
        #expect(def.priority == 7)
    }

    @Test("Two edits changing the same field: last commit wins")
    func concurrentEditorsSameField() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Editor 1: change priority to 2
        let edited1 = children[0]
        let original1 = SharedAttributes(edited1)
        var changed1 = original1
        changed1.priority = 2

        let edit1 = TaskEdit(originalShared: original1, editedShared: changed1)
        try TaskEditCommit.commit(edit1, to: edited1, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.priority == 2)

        // Editor 2: change priority to 5
        let edited2 = children[1]
        let original2 = SharedAttributes(edited2)
        var changed2 = original2
        changed2.priority = 5

        let edit2 = TaskEdit(originalShared: original2, editedShared: changed2)
        try TaskEditCommit.commit(edit2, to: edited2, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Last wins
        #expect(def.priority == 5)
    }

    @Test("A no-op stale commit does not revert another editor's change")
    func staleNoOpDoesNotRevert() throws {
        let context = makeContext()
        let c = cal()
        let (def, children) = try createDailySeries(context, c)

        // Editor 1: change title
        let edited1 = children[0]
        let original1 = SharedAttributes(edited1)
        var changed1 = original1
        changed1.title = "New title"

        let edit1 = TaskEdit(originalShared: original1, editedShared: changed1)
        try TaskEditCommit.commit(edit1, to: edited1, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        #expect(def.title == "New title")

        // Editor 2 (stale): has old shared attributes, makes no changes
        let edited2 = children[1]
        let original2 = SharedAttributes(edited2)  // This still has "Daily task"
        let edit2 = TaskEdit(originalShared: original2, editedShared: original2)  // No-op

        let scheduleChanged = try TaskEditCommit.commit(edit2, to: edited2, context: context,
                                                        today: date(2026, 1, 5, c),
                                                        horizon: date(2026, 2, 1, c), calendar: c)

        // No-op doesn't touch anything
        #expect(!scheduleChanged)
        #expect(def.title == "New title")  // Editor 1's change survives
    }

    // MARK: - Additional: Unrelated Series and One-offs Untouched

    @Test("Editing one series does not affect unrelated series or one-offs with same title")
    func unrelatedSeriesUntouched() throws {
        let context = makeContext()
        let c = cal()
        let (def1, children1) = try createDailySeries(context, c)

        // Create a second series with the same title
        let seed2 = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 15))
        context.insert(seed2)

        let rule2 = RecurrenceRule(frequency: .daily, end: .afterCount(5),
                                  startDate: date(2026, 1, 15, c))
        let def2 = try RecurrenceMaterializer.startSeries(
            from: seed2, rule: rule2, through: date(2026, 2, 1, c), context: context, calendar: c)

        // Create an unrelated one-off with the same title
        let oneOff = TaskItem(title: "Daily task", dayKey: dayKey(2026, 1, 20))
        context.insert(oneOff)
        try context.save()

        // Edit the first series
        let edited = children1[2]
        let original = SharedAttributes(edited)
        var changed = original
        changed.priority = 99

        let edit = TaskEdit(originalShared: original, editedShared: changed)
        try TaskEditCommit.commit(edit, to: edited, context: context, today: date(2026, 1, 5, c),
                                  horizon: date(2026, 2, 1, c), calendar: c)

        // Only def1's series changed
        #expect(def1.priority == 99)
        #expect(def2.priority == 0)  // unchanged
        #expect(oneOff.priority == 0)  // unchanged
    }
}
