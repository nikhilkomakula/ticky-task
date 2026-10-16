import Foundation
import SwiftData

extension Notification.Name {
    /// Posted after a series was started or its rule changed, so the main window
    /// regenerates occurrences for every range it already showed this session.
    static let tickyTaskSeriesChanged = Notification.Name("TickyTaskSeriesChanged")
}

/// The attributes a recurring series shares: editing one on any occurrence
/// changes it on the definition and on every occurrence, past and completed ones
/// included. Notes, subtasks, completion, and placement are never shared.
struct SharedAttributes: Equatable {
    var title: String
    var timeMinutes: Int?
    var alarmEnabled: Bool
    var priority: Int
    var isCritical: Bool
    var colorHex: String?
    var tagIDs: Set<UUID>

    @MainActor
    init(_ task: TaskItem) {
        title = task.title
        timeMinutes = task.timeMinutes
        alarmEnabled = task.alarmEnabled
        priority = task.priority
        isCritical = task.isCritical
        colorHex = task.colorHex
        tagIDs = Set(task.tags.map(\.id))
    }
}

/// An editor's subtask row, held as a value until Done.
struct SubtaskDraft: Equatable, Identifiable {
    var id: UUID
    var title: String
    var isDone: Bool
    var sortIndex: Double

    @MainActor
    static func drafts(of task: TaskItem) -> [SubtaskDraft] {
        task.subtasks.sorted { $0.sortIndex < $1.sortIndex }
            .map { SubtaskDraft(id: $0.id, title: $0.title, isDone: $0.isDone, sortIndex: $0.sortIndex) }
    }
}

/// What a Done in the task editor commits. `nil` / `.unchanged` parts were not
/// edited and are not written, so a no-op Done changes nothing at all.
struct TaskEdit {
    enum RuleChange: Equatable {
        case unchanged
        /// Make a dated one-off task the first occurrence of a new series.
        case startSeries(RecurrenceRule)
        /// Replace the owning series' rule (including stopping it).
        case replace(RecurrenceRule)
    }

    var originalShared: SharedAttributes
    var editedShared: SharedAttributes
    var notes: NotesDocument?
    var subtasks: [SubtaskDraft]?
    var rule: RuleChange = .unchanged

    var isEmpty: Bool {
        originalShared == editedShared && notes == nil && subtasks == nil && rule == .unchanged
    }
}

/// Applies a `TaskEdit` in one transaction: occurrence-local changes to the edited
/// row, changed shared fields to the whole series, then any rule change. Saves
/// once; on failure the transaction is rolled back and the error is rethrown, so
/// the editor can keep its draft open.
@MainActor
enum TaskEditCommit {
    /// Returns whether a series' schedule changed (callers refresh generation).
    /// `save` is injectable so tests can make the commit fail.
    @discardableResult
    static func commit(_ edit: TaskEdit, to task: TaskItem, context: ModelContext,
                       today: Date = Date(), horizon: Date, calendar: Calendar = .current,
                       save: (ModelContext) throws -> Void = { try $0.save() }) throws -> Bool {
        guard !edit.isEmpty else { return false }
        try RecurrenceMaterializer.checkpoint(context)
        do {
            let now = Date()
            if let document = edit.notes {
                task.notesRich = try NotesCodec.encode(document)
                task.notes = document.plainText
                task.updatedAt = now
                task.markOccurrenceModified()
            }
            if let subtasks = edit.subtasks {
                apply(subtasks, to: task, context: context)
                task.updatedAt = now
                task.markOccurrenceModified()
            }
            if edit.originalShared != edit.editedShared {
                try propagate(from: edit.originalShared, to: edit.editedShared,
                              across: seriesRows(of: task, context: context), context: context, now: now)
            }
            switch edit.rule {
            case .unchanged:
                break
            case .startSeries(let rule):
                try RecurrenceMaterializer.startSeries(from: task, rule: rule, through: horizon,
                                                       context: context, calendar: calendar)
            case .replace(let rule):
                if let definition = try RecurrenceMaterializer.definition(for: task, context: context) {
                    try RecurrenceMaterializer.changeRule(of: definition, to: rule, today: today,
                                                          through: horizon, context: context, calendar: calendar)
                }
            }
            try save(context)
            return edit.rule != .unchanged
        } catch {
            context.rollbackAndRefresh()
            throw error
        }
    }

    /// The definition and every occurrence of `task`'s series, or just `task`.
    static func seriesRows(of task: TaskItem, context: ModelContext) throws -> [TaskItem] {
        guard let definition = try RecurrenceMaterializer.definition(for: task, context: context) else { return [task] }
        return [definition] + (try RecurrenceMaterializer.children(of: definition, context: context))
    }

    /// Write only the fields that differ between `original` and `edited`, so an
    /// edit never reverts a field it didn't touch (another editor may have changed
    /// it). Rows whose values don't actually change keep their timestamps, and
    /// occurrence provenance is untouched — this is not the user acting on them.
    static func propagate(from original: SharedAttributes, to edited: SharedAttributes,
                          across rows: [TaskItem], context: ModelContext, now: Date = Date()) throws {
        let tags = original.tagIDs == edited.tagIDs ? [] : try context.fetch(FetchDescriptor<TaskTag>())
            .filter { edited.tagIDs.contains($0.id) }
        for row in rows {
            var changed = false
            func write<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TaskItem, Value>,
                                         _ field: KeyPath<SharedAttributes, Value>) {
                guard original[keyPath: field] != edited[keyPath: field],
                      row[keyPath: keyPath] != edited[keyPath: field] else { return }
                row[keyPath: keyPath] = edited[keyPath: field]
                changed = true
            }
            write(\.title, \.title)
            write(\.timeMinutes, \.timeMinutes)
            write(\.alarmEnabled, \.alarmEnabled)
            // Clearing the time clears every reminder too, even on a row whose alarm
            // differed from the edited one: a reminder needs a time.
            if original.timeMinutes != nil, edited.timeMinutes == nil, row.alarmEnabled {
                row.alarmEnabled = false
                changed = true
            }
            write(\.priority, \.priority)
            write(\.isCritical, \.isCritical)
            write(\.colorHex, \.colorHex)
            if original.tagIDs != edited.tagIDs, Set(row.tags.map(\.id)) != edited.tagIDs {
                row.tags = tags
                changed = true
            }
            if changed { row.updatedAt = now }
        }
    }

    /// Make `task`'s subtasks match `drafts`: keep each subtask's identity, update
    /// changed ones, add new ones, and delete removed ones.
    private static func apply(_ drafts: [SubtaskDraft], to task: TaskItem, context: ModelContext) {
        let existing = Dictionary(uniqueKeysWithValues: task.subtasks.map { ($0.id, $0) })
        let kept = Set(drafts.map(\.id))
        for subtask in Array(task.subtasks) where !kept.contains(subtask.id) { context.delete(subtask) }
        for draft in drafts {
            if let subtask = existing[draft.id] {
                if subtask.title != draft.title { subtask.title = draft.title }
                if subtask.isDone != draft.isDone { subtask.isDone = draft.isDone }
                if subtask.sortIndex != draft.sortIndex { subtask.sortIndex = draft.sortIndex }
            } else {
                task.subtasks.append(Subtask(id: draft.id, title: draft.title, isDone: draft.isDone,
                                             sortIndex: draft.sortIndex))
            }
        }
    }
}

/// The task editor's Repeat controls as a value. Loaded from a stored rule and
/// turned back into one only when the user changed something, preserving the parts
/// the editor can't show — an imported "1st and 15th" keeps its month days, custom
/// weekdays stay custom, and the start date (the series' anchor) never moves.
struct RecurrenceDraft: Equatable {
    enum EndMode: Hashable { case never, after, on }

    var frequency: RecurrenceFrequency
    var interval: Int
    var weekdays: Set<Int>
    var endMode: EndMode
    var endCount: Int
    var endDate: Date

    /// Defaults for a new rule on a task dated `day`.
    init(newOn day: Date?, calendar: Calendar = .current) {
        frequency = .daily
        interval = 1
        weekdays = day.map { [calendar.component(.weekday, from: $0)] } ?? []
        endMode = .never
        endCount = 10
        endDate = day ?? Date()
    }

    init(rule: RecurrenceRule, calendar: Calendar = .current) {
        frequency = rule.frequency.editableEquivalent
        interval = rule.interval
        weekdays = rule.weekdays.isEmpty ? [calendar.component(.weekday, from: rule.startDate)] : rule.weekdays
        switch rule.end {
        case .never: endMode = .never; endCount = 10; endDate = rule.startDate
        case .afterCount(let n): endMode = .after; endCount = max(1, n); endDate = rule.startDate
        case .until(let date): endMode = .on; endCount = 10; endDate = date
        }
    }

    /// Equal for editing purposes: end dates compare by calendar day.
    func isEquivalent(to other: RecurrenceDraft, calendar: Calendar = .current) -> Bool {
        var lhs = self, rhs = other
        lhs.endDate = calendar.startOfDay(for: endDate)
        rhs.endDate = calendar.startOfDay(for: other.endDate)
        return lhs == rhs
    }

    /// The rule these controls describe. With an `original`, its frequency form,
    /// month days, start date, and (when the day is unchanged) exact end date are
    /// kept; `startDate` anchors a brand-new rule.
    func rule(replacing original: RecurrenceRule?, startDate: Date, calendar: Calendar = .current) -> RecurrenceRule {
        let start = original?.startDate ?? startDate
        let form = original.map { $0.frequency.editableEquivalent == frequency ? $0.frequency : frequency } ?? frequency
        let end: RecurrenceEnd
        switch endMode {
        case .never: end = .never
        case .after: end = .afterCount(max(1, endCount))
        case .on:
            if case .until(let kept)? = original?.end,
               calendar.isDate(kept, inSameDayAs: endDate) { end = .until(kept) } else { end = .until(endDate) }
        }
        let days: Set<Int>
        switch form {
        case .weekly, .customWeekdays:
            days = weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : weekdays
        default:
            days = []
        }
        return RecurrenceRule(frequency: form,
                              interval: form == .weekdays ? 1 : max(1, interval),
                              weekdays: days,
                              monthDays: form == .daysOfMonth ? (original?.monthDays ?? []) : [],
                              end: end,
                              startDate: start)
    }
}

extension RecurrenceFrequency {
    /// The frequencies offered in the editor. `.customWeekdays` and `.daysOfMonth`
    /// only arrive via legacy import and are shown as weekly / monthly.
    static var editableCases: [RecurrenceFrequency] { [.daily, .weekdays, .weekly, .monthly, .yearly] }

    /// The editable frequency that represents a stored one.
    var editableEquivalent: RecurrenceFrequency {
        switch self {
        case .customWeekdays: return .weekly
        case .daysOfMonth: return .monthly
        default: return self
        }
    }
}

extension RecurrenceRule {
    /// Whether the series has stopped: it ends on or before `today`.
    func hasEnded(asOf today: Date, calendar: Calendar = .current) -> Bool {
        guard case .until(let date) = end else { return false }
        return calendar.startOfDay(for: date) <= calendar.startOfDay(for: today)
    }
}
