import Foundation
import SwiftData

/// Pure task-ordering and carry-forward behaviors, driven by user settings.
/// Kept dependency-light so the ordering rules are unit-testable.
enum BehaviorService {
    /// Order tasks for display. When `completedToBottom` is on, incomplete tasks
    /// come first; within each group the `mode` decides the order (ties broken by
    /// the manual `sortIndex`).
    static func sorted(_ tasks: [TaskItem], mode: TaskSortMode, completedToBottom: Bool) -> [TaskItem] {
        tasks.sorted { lhs, rhs in
            if completedToBottom, lhs.isDone != rhs.isDone {
                return !lhs.isDone            // incomplete first
            }
            switch mode {
            case .manual:
                return lhs.sortIndex < rhs.sortIndex
            case .time:
                let l = lhs.timeMinutes ?? Int.max   // untimed sinks to the bottom
                let r = rhs.timeMinutes ?? Int.max
                return l != r ? l < r : lhs.sortIndex < rhs.sortIndex
            case .priority:
                return lhs.priority != rhs.priority
                    ? lhs.priority > rhs.priority     // higher priority first
                    : lhs.sortIndex < rhs.sortIndex
            }
        }
    }

    /// Return `items` with the element identified by `id` moved to just before
    /// `beforeID` (appended when `beforeID` is nil or not found). Drives manual
    /// drag reordering; a no-op when `id` isn't present.
    static func reordered<T: Identifiable>(_ items: [T], moving id: T.ID, before beforeID: T.ID?) -> [T] {
        guard let moving = items.first(where: { $0.id == id }) else { return items }
        var order = items.filter { $0.id != id }
        if let beforeID, let index = order.firstIndex(where: { $0.id == beforeID }) {
            order.insert(moving, at: index)
        } else {
            order.append(moving)
        }
        return order
    }

    /// The day incomplete past tasks should carry onto: today, unless weekends are
    /// hidden **and** today is a weekend — then the next visible weekday, so a
    /// previous Friday's (or a Saturday's) unfinished tasks land on Monday instead
    /// of an off-screen weekend column. Returns `todayKey` unchanged when weekends
    /// are shown or today is already a weekday.
    static func carryForwardTarget(todayKey: String,
                                   showWeekends: Bool,
                                   calendar: Calendar = .current) -> String {
        guard !showWeekends,
              let today = WeekMath.date(fromDayKey: todayKey, calendar: calendar),
              WeekMath.isSaturdayOrSunday(today, calendar: calendar) else { return todayKey }
        var cursor = today
        for _ in 0..<7 {   // bounded: the next weekday is at most 2 days away
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            if !WeekMath.isSaturdayOrSunday(cursor, calendar: calendar) {
                return WeekMath.dayKey(for: cursor, calendar: calendar)
            }
        }
        return todayKey
    }

    /// Move non-recurring, unfinished tasks from days before `targetKey` onto it.
    /// `targetKey` is normally today (see `carryForwardTarget`, which skips a hidden
    /// weekend to the next weekday). Idempotent: once moved, a task's `dayKey`
    /// equals `targetKey`, so re-running is a no-op. Recurring templates *and* their
    /// materialized occurrences are left in place — a missed recurring instance
    /// stays on its day; a fresh one appears next period. Returns the number moved.
    @MainActor
    @discardableResult
    static func carryForwardIncomplete(context: ModelContext,
                                       targetKey: String = WeekMath.dayKey(for: Date())) throws -> Int {
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        // Carry earlier-day tasks in a stable, chronological order (oldest day
        // first, then their in-day order) so multiple carried tasks don't land under
        // the target day in an arbitrary fetch order.
        let ordered = all.sorted { lhs, rhs in
            let lk = lhs.dayKey ?? "", rk = rhs.dayKey ?? ""
            if lk != rk { return lk < rk }
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.id.uuidString < rhs.id.uuidString   // stable, total order on ties
        }
        // Place carried-forward tasks after the target day's existing tasks so
        // manual ordering stays unambiguous (no sortIndex collisions).
        var nextIndex = all.filter { $0.dayKey == targetKey }.map(\.sortIndex).max() ?? 0
        var moved = 0
        for task in ordered {
            guard let key = task.dayKey,
                  task.recurrence == nil,
                  task.templateID == nil,
                  !task.isDone,
                  key < targetKey else { continue }
            nextIndex += 1
            task.dayKey = targetKey
            task.sortIndex = nextIndex
            task.updatedAt = Date()
            moved += 1
        }
        if moved > 0 { try context.save() }
        return moved
    }
}
