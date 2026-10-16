import Foundation
import SwiftData

/// Turns recurring series into concrete `TaskItem` rows and owns the series
/// lifecycle (materialize, start, rule change, delete occurrence/series).
///
/// A series is a hidden **definition** (`recurrence != nil`, no day or list) that
/// owns the shared attributes and skip records, plus one ordinary child row per
/// occurrence (`templateID == definition.id`) — the first occurrence included.
/// Occurrences are real rows so the per-day `@Query`, drag, completion, reminders,
/// search, and backup work on them unchanged. Each child keeps the slot it was
/// generated for in `occurrenceKey`, independent of where it now sits, so moving
/// an occurrence never frees its slot for regeneration. `RecurrenceEngine` does
/// the pure date math.
@MainActor
enum RecurrenceMaterializer {
    /// How far ahead to generate occurrences by default (covers the week and month
    /// views without unbounded row growth). Navigation extends this on demand.
    static let defaultHorizonDays = 60

    enum LifecycleError: Error {
        /// A definition is not an occurrence; only its series can be deleted.
        case notAnOccurrence
        /// The task can no longer start a series (it already belongs to one, or it
        /// is not on a calendar day) — another window changed it meanwhile.
        case cannotStartSeries
    }

    /// The context is shared by every window. Persist anything else already pending
    /// before a transaction, so rolling it back on failure reverts only its own work.
    static func checkpoint(_ context: ModelContext) throws {
        if context.hasChanges { try context.save() }
    }

    /// Normalize legacy rows, then generate any missing occurrences for every
    /// series through `horizon`. Idempotent: a slot that already has an occurrence
    /// (wherever it was moved) or was skipped is never generated again. Saves once;
    /// rolls back on failure. Returns the number of occurrences created.
    @discardableResult
    static func materialize(context: ModelContext,
                            through horizon: Date,
                            calendar: Calendar = .current) throws -> Int {
        try checkpoint(context)
        do {
            try RecurrenceNormalizer.normalize(context: context)
            var created = 0
            var nextIndexByDay: [String: Double] = [:]
            for definition in try definitions(context) {
                created += try generateOccurrences(for: definition, through: horizon, context: context,
                                                   sortCache: &nextIndexByDay, calendar: calendar)
            }
            if context.hasChanges { try context.save() }
            return created
        } catch {
            context.rollbackAndRefresh()
            throw error
        }
    }

    // MARK: - Lifecycle (callers save, except where noted)

    /// Make the dated one-off `task` the first occurrence of a new series: a hidden
    /// definition takes the rule and the shared attributes, and `task` keeps its
    /// UUID, notes, and subtasks as the seed occurrence (kept even if its day is
    /// not on the rule). Generates the following occurrences through `horizon`.
    @discardableResult
    static func startSeries(from task: TaskItem, rule: RecurrenceRule, through horizon: Date,
                            context: ModelContext, calendar: Calendar = .current) throws -> TaskItem {
        guard task.recurrence == nil, task.templateID == nil, task.dayKey != nil, task.customList == nil else {
            throw LifecycleError.cannotStartSeries
        }
        let definition = TaskItem(title: task.title, timeMinutes: task.timeMinutes, colorHex: task.colorHex,
                                  priority: task.priority, alarmEnabled: task.alarmEnabled, recurrence: rule)
        definition.isCritical = task.isCritical
        definition.tags = task.tags
        context.insert(definition)

        task.templateID = definition.id
        task.occurrenceKey = task.dayKey
        task.occurrenceModified = true
        task.updatedAt = Date()

        var cache: [String: Double] = [:]
        try generateOccurrences(for: definition, through: horizon, context: context,
                                sortCache: &cache, calendar: calendar)
        return definition
    }

    /// Replace a series' rule (also how it stops: an end of `.until(today)`).
    /// Schedule changes apply after `today`: the old rule first catches up through
    /// today, so nothing it already owed is lost; the new rule then generates only
    /// from tomorrow (persisted as `recurrenceEffectiveFromKey`, so later runs never
    /// invent past occurrences either). Interval phase and counts stay anchored to
    /// the original start. Future occurrences the new rule no longer schedules are
    /// removed only when provably untouched; everything else is kept in place.
    static func changeRule(of definition: TaskItem, to newRule: RecurrenceRule, today: Date,
                           through requestedHorizon: Date, context: ModelContext,
                           calendar: Calendar = .current) throws {
        guard let oldRule = definition.recurrence else { return }
        let startOfToday = calendar.startOfDay(for: today)
        let todayKey = WeekMath.dayKey(for: startOfToday, calendar: calendar)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return }

        var cache: [String: Double] = [:]
        try generateOccurrences(for: definition, through: startOfToday, context: context,
                                sortCache: &cache, calendar: calendar)
        let existing = try children(of: definition, context: context)

        var rule = newRule
        rule.startDate = oldRule.startDate
        definition.recurrence = rule
        definition.recurrenceEffectiveFromKey = WeekMath.dayKey(for: tomorrow, calendar: calendar)
        definition.updatedAt = Date()

        let horizon = reconciliationHorizon(existing, requested: requestedHorizon, today: startOfToday,
                                            calendar: calendar)
        let scheduled = Set(RecurrenceEngine.occurrenceDayKeys(for: rule, from: tomorrow, through: horizon,
                                                               calendar: calendar))
        for child in existing {
            guard let key = child.occurrenceKey, key > todayKey, !scheduled.contains(key),
                  isUntouchedGenerated(child) else { continue }
            context.delete(child)
        }
        try generateOccurrences(for: definition, through: horizon, context: context,
                                sortCache: &cache, calendar: calendar)
    }

    /// Delete exactly one occurrence and skip its slot so it never regenerates. A
    /// legacy occurrence with an unknown slot is deleted without a skip record. Never
    /// deletes the series or touches any other occurrence. Saves.
    static func deleteOccurrence(_ task: TaskItem, context: ModelContext) throws {
        guard task.recurrence == nil else { throw LifecycleError.notAnOccurrence }
        try checkpoint(context)
        do {
            try skipSlot(of: task, context: context)
            context.delete(task)
            try context.save()
        } catch {
            context.rollbackAndRefresh()
            throw error
        }
    }

    /// Delete the whole series `task` belongs to: its definition, every occurrence
    /// in any day or list (past and completed included), and its skip records. Saves.
    static func deleteSeries(_ task: TaskItem, context: ModelContext) throws {
        try checkpoint(context)
        do {
            guard let definition = try definition(for: task, context: context) else {
                context.delete(task)   // an orphaned occurrence: it is its whole series
                try context.save()
                return
            }
            for child in try children(of: definition, context: context) { context.delete(child) }
            context.delete(definition)   // cascades its skip records
            try context.save()
        } catch {
            context.rollbackAndRefresh()
            throw error
        }
    }

    /// Record that `occurrence`'s slot must not regenerate (before it is deleted by
    /// the user, auto-delete, or a list deletion). Reuses an existing record for the
    /// slot, so there is never more than one per (series, day).
    static func skipSlot(of occurrence: TaskItem, context: ModelContext) throws {
        guard let key = occurrence.occurrenceKey,
              let definition = try definition(for: occurrence, context: context),
              definition.id != occurrence.id else { return }
        let records = definition.occurrences.filter { $0.dayKey == key }
        if records.contains(where: \.skipped) { return }
        if let record = records.first {
            record.skipped = true
        } else {
            definition.occurrences.append(TaskOccurrence(dayKey: key, skipped: true))
        }
    }

    /// The definition owning `task` (itself when `task` is a definition).
    static func definition(for task: TaskItem, context: ModelContext) throws -> TaskItem? {
        if task.recurrence != nil { return task }
        guard let id = task.templateID else { return nil }
        return try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first
    }

    /// Every occurrence linked to `definition`, in any location.
    static func children(of definition: TaskItem, context: ModelContext) throws -> [TaskItem] {
        let id: UUID? = definition.id
        return try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.templateID == id }))
    }

    // MARK: - Generation

    static func definitions(_ context: ModelContext) throws -> [TaskItem] {
        // `recurrence` is a Codable attribute (not predicate-filterable), so select
        // definitions in memory — a personal planner has few of them.
        try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.recurrence != nil && $0.templateID == nil }
    }

    @discardableResult
    static func generateOccurrences(for definition: TaskItem, through horizon: Date, context: ModelContext,
                                    sortCache: inout [String: Double], calendar: Calendar) throws -> Int {
        guard let rule = definition.recurrence else { return 0 }
        let from = definition.recurrenceEffectiveFromKey
            .flatMap { WeekMath.date(fromDayKey: $0, calendar: calendar) } ?? rule.startDate
        let keys = RecurrenceEngine.occurrenceDayKeys(for: rule, from: from, through: horizon, calendar: calendar)
        guard !keys.isEmpty else { return 0 }

        var handled = Set(try children(of: definition, context: context).compactMap(\.occurrenceKey))
        handled.formUnion(definition.occurrences.filter(\.skipped).map(\.dayKey))
        var created = 0
        for key in keys where !handled.contains(key) {
            let child = makeOccurrence(of: definition, slot: key)
            child.sortIndex = nextSortIndex(forDay: key, cache: &sortCache, context: context)
            context.insert(child)
            handled.insert(key)
            created += 1
        }
        return created
    }

    /// A fresh occurrence: the series' shared attributes and tags, with empty
    /// notes, subtasks, and completion — those belong to each occurrence alone.
    static func makeOccurrence(of definition: TaskItem, slot: String) -> TaskItem {
        let child = TaskItem(title: definition.title, dayKey: slot, timeMinutes: definition.timeMinutes,
                             colorHex: definition.colorHex, priority: definition.priority,
                             alarmEnabled: definition.alarmEnabled)
        child.isCritical = definition.isCritical
        child.tags = definition.tags
        child.templateID = definition.id
        child.occurrenceKey = slot
        child.occurrenceModified = false
        return child
    }

    /// Append after any existing tasks on the day; a per-run cache keeps successive
    /// occurrences on the same day monotonic even before the context is saved.
    static func nextSortIndex(forDay key: String, cache: inout [String: Double], context: ModelContext) -> Double {
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

    // MARK: - Helpers

    /// Generated, never acted on, and carrying no work: the only kind of occurrence
    /// a rule change may remove. Legacy rows (`nil` provenance) never qualify.
    private static func isUntouchedGenerated(_ child: TaskItem) -> Bool {
        child.occurrenceModified == false && !child.hasOccurrenceWork
            && child.customList == nil && child.dayKey == child.occurrenceKey
    }

    /// Reconcile at least as far as anything already generated for the series, so
    /// a far-future range visited earlier is rebuilt to the new rule too.
    private static func reconciliationHorizon(_ children: [TaskItem], requested: Date, today: Date,
                                              calendar: Calendar) -> Date {
        let lookahead = calendar.date(byAdding: .day, value: defaultHorizonDays, to: today) ?? today
        let latestKey = children.flatMap { [$0.occurrenceKey, $0.dayKey] }.compactMap { $0 }.max()
        let latest = latestKey.flatMap { WeekMath.date(fromDayKey: $0, calendar: calendar) } ?? today
        return max(requested, lookahead, latest)
    }
}
