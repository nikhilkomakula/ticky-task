import Foundation
import SwiftData

/// Turns recurring templates into concrete `TaskItem` rows and owns the recurring
/// task lifecycle (materialize, delete-occurrence, delete-series, rule change).
///
/// Occurrences are real rows so the whole app — the per-day `@Query`, drag,
/// completion, reminders, search, backup — works on them unchanged. A row is a
/// *template* when `recurrence != nil` and a *materialized occurrence* when
/// `templateID != nil`; the template also serves as its own first occurrence, on
/// its start day. `RecurrenceEngine` does the pure date math; this layer only
/// bridges it to the store.
@MainActor
enum RecurrenceMaterializer {
    /// How far ahead to generate occurrences by default (covers the week and month
    /// views without unbounded row growth). Navigation extends this on demand.
    static let defaultHorizonDays = 60

    /// Generate any missing occurrences for every template, from its start through
    /// `horizon`. Idempotent: a day already materialized, completed/edited, deleted
    /// (tombstoned), or occupied by the template itself is skipped, so re-running is
    /// a no-op. Returns the number of occurrences created.
    @discardableResult
    static func materialize(context: ModelContext,
                            through horizon: Date,
                            calendar: Calendar = .current) throws -> Int {
        // `recurrence` is a Codable attribute (not predicate-filterable), so select
        // templates in memory — a personal planner has few of them.
        let templates = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.recurrence != nil }
        var created = 0
        var nextIndexByDay: [String: Double] = [:]   // monotonic within this run

        for template in templates {
            guard let rule = template.recurrence, let startKey = template.dayKey else { continue }
            let keys = RecurrenceEngine.occurrenceDayKeys(
                for: rule, from: rule.startDate, through: horizon, calendar: calendar
            )
            guard !keys.isEmpty else { continue }

            let tid: UUID? = template.id
            let existing = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.templateID == tid }))
            var handled = Set(existing.compactMap(\.dayKey))
            handled.formUnion(template.occurrences.filter(\.skipped).map(\.dayKey))
            handled.insert(startKey)   // the template is its own first occurrence

            for key in keys where !handled.contains(key) {
                let child = makeOccurrence(from: template, dayKey: key)
                child.sortIndex = nextSortIndex(forDay: key, cache: &nextIndexByDay, context: context)
                context.insert(child)
                handled.insert(key)
                created += 1
            }
        }
        if context.hasChanges { try context.save() }
        return created
    }

    // MARK: - Lifecycle

    /// Delete a single instance. A materialized occurrence is tombstoned so it won't
    /// regenerate; deleting the template's own (start-day) instance advances the
    /// series to its next occurrence — or deletes the series if there is none.
    static func deleteOccurrence(_ task: TaskItem, context: ModelContext, calendar: Calendar = .current) throws {
        if task.templateID != nil {
            try tombstoneOccurrence(task, context: context)
            context.delete(task)
            try context.save()
        } else if task.recurrence != nil {
            try advancePastStart(task, context: context, calendar: calendar)
        } else {
            context.delete(task)
            try context.save()
        }
    }

    /// Delete the whole recurring series that `task` belongs to (template or
    /// occurrence): the template, all its occurrences, and its skip tombstones.
    static func deleteSeries(_ task: TaskItem, context: ModelContext) throws {
        let template: TaskItem
        if task.recurrence != nil {
            template = task
        } else if let tid = task.templateID, let found = try fetchTask(tid, context: context) {
            template = found
        } else {
            context.delete(task)
            try context.save()
            return
        }
        let tid: UUID? = template.id
        let children = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.templateID == tid }))
        children.forEach { context.delete($0) }
        context.delete(template)   // cascades template.occurrences (tombstones)
        try context.save()
    }

    /// After the template's `recurrence` changed, rebuild future occurrences to the
    /// new rule. Preserves past, completed, tombstoned, and manually-edited days.
    static func regenerateFuture(for template: TaskItem,
                                 todayKey: String,
                                 through horizon: Date,
                                 context: ModelContext,
                                 calendar: Calendar = .current) throws {
        guard template.recurrence != nil else { return }
        let tid: UUID? = template.id
        let children = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.templateID == tid }))
        let tombstoned = Set(template.occurrences.filter(\.skipped).map(\.dayKey))
        for child in children {
            guard let key = child.dayKey, key > todayKey else { continue }   // future only
            if child.isDone || tombstoned.contains(key) || isManuallyEdited(child, template: template) { continue }
            context.delete(child)
        }
        do {
            try materialize(context: context, through: horizon, calendar: calendar)
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Turn a template back into a one-off task: clear its rule and remove every
    /// generated occurrence and skip tombstone, leaving only this (now plain) row.
    static func removeRecurrence(from template: TaskItem, context: ModelContext) throws {
        template.recurrence = nil
        let tid: UUID? = template.id
        let children = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.templateID == tid }))
        children.forEach { context.delete($0) }
        template.occurrences.filter(\.skipped).forEach { context.delete($0) }
        template.templateID = nil
        try context.save()
    }

    // MARK: - Helpers

    private static func makeOccurrence(from template: TaskItem, dayKey: String) -> TaskItem {
        // Copy the display attributes; notes/subtasks/tags are per-instance work and
        // deliberately start clean on a generated occurrence.
        let child = TaskItem(title: template.title, dayKey: dayKey)
        child.templateID = template.id
        child.timeMinutes = template.timeMinutes
        child.colorHex = template.colorHex
        child.priority = template.priority
        child.isCritical = template.isCritical
        child.alarmEnabled = template.alarmEnabled
        return child
    }

    /// Append after any existing tasks on the day; a per-run cache keeps successive
    /// occurrences on the same day monotonic even before the context is saved.
    private static func nextSortIndex(forDay key: String, cache: inout [String: Double], context: ModelContext) -> Double {
        if let next = cache[key] {
            cache[key] = next + 1
            return next
        }
        let target: String? = key
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.dayKey == target },
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let top = (try? context.fetch(descriptor))?.first?.sortIndex ?? 0
        cache[key] = top + 2
        return top + 1
    }

    private static func tombstoneOccurrence(_ child: TaskItem, context: ModelContext) throws {
        guard let tid = child.templateID, let key = child.dayKey,
              let template = try fetchTask(tid, context: context) else { return }
        if !template.occurrences.contains(where: { $0.skipped && $0.dayKey == key }) {
            template.occurrences.append(TaskOccurrence(dayKey: key, skipped: true))
        }
    }

    /// The user deleted the template's own (start-day) instance: tombstone that day,
    /// keep `startDate` as the math anchor (so interval/count phase is preserved),
    /// and move the template row onto the next occurrence. Falls back to a full
    /// series delete when the series has no further occurrence.
    private static func advancePastStart(_ template: TaskItem, context: ModelContext, calendar: Calendar) throws {
        guard let rule = template.recurrence,
              let startKey = template.dayKey,
              let startDate = WeekMath.date(fromDayKey: startKey, calendar: calendar),
              let dayAfter = calendar.date(byAdding: .day, value: 1, to: startDate),
              let searchEnd = nextOccurrenceSearchEnd(for: rule, startDate: startDate, calendar: calendar) else {
            try deleteSeries(template, context: context)
            return
        }
        let nextKeys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: dayAfter, through: searchEnd, calendar: calendar)
        guard let nextKey = nextKeys.first else {
            try deleteSeries(template, context: context)   // it was the only occurrence
            return
        }
        // Tombstone the deleted start day so materialize never recreates it.
        if !template.occurrences.contains(where: { $0.skipped && $0.dayKey == startKey }) {
            template.occurrences.append(TaskOccurrence(dayKey: startKey, skipped: true))
        }
        // Remove any already-materialized child on the promoted day to avoid a dup.
        let tid: UUID? = template.id
        let target: String? = nextKey
        let dupes = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.templateID == tid && $0.dayKey == target }))
        dupes.forEach { context.delete($0) }

        template.dayKey = nextKey
        template.isDone = false
        template.completedAt = nil
        template.updatedAt = Date()
        try context.save()
    }

    private static func isManuallyEdited(_ child: TaskItem, template: TaskItem) -> Bool {
        child.title != template.title || child.timeMinutes != template.timeMinutes
    }

    /// Cover a complete validity cycle for sparse calendar rules. A fixed horizon
    /// would incorrectly treat, for example, an every-10-years rule as exhausted.
    private static func nextOccurrenceSearchEnd(for rule: RecurrenceRule,
                                                startDate: Date,
                                                calendar: Calendar) -> Date? {
        let interval = max(1, rule.interval)
        switch rule.frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: interval, to: startDate)
        case .weekdays:
            return calendar.date(byAdding: .day, value: 7, to: startDate)
        case .weekly, .customWeekdays:
            return calendar.date(byAdding: .weekOfYear, value: interval, to: startDate)
        case .monthly, .daysOfMonth:
            let span = interval.multipliedReportingOverflow(by: 12)
            guard !span.overflow else { return nil }
            return calendar.date(byAdding: .month, value: span.partialValue, to: startDate)
        case .yearly:
            let span = interval.multipliedReportingOverflow(by: 4)
            guard !span.overflow else { return nil }
            return calendar.date(byAdding: .year, value: span.partialValue, to: startDate)
        }
    }

    private static func fetchTask(_ id: UUID, context: ModelContext) throws -> TaskItem? {
        try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first
    }
}
