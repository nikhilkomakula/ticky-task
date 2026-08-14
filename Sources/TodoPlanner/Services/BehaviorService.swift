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

    /// Move non-recurring, unfinished tasks from past days onto today. Idempotent:
    /// once moved, a task's `dayKey` equals today's, so re-running is a no-op.
    /// Returns the number of tasks moved.
    @MainActor
    @discardableResult
    static func carryForwardIncomplete(context: ModelContext,
                                       todayKey: String = WeekMath.dayKey(for: Date())) throws -> Int {
        let all = try context.fetch(FetchDescriptor<TaskItem>())
        // Place carried-forward tasks after today's existing tasks so manual
        // ordering stays unambiguous (no sortIndex collisions).
        var nextIndex = all.filter { $0.dayKey == todayKey }.map(\.sortIndex).max() ?? 0
        var moved = 0
        for task in all {
            guard let key = task.dayKey,
                  task.recurrence == nil,
                  !task.isDone,
                  key < todayKey else { continue }
            nextIndex += 1
            task.dayKey = todayKey
            task.sortIndex = nextIndex
            task.updatedAt = Date()
            moved += 1
        }
        if moved > 0 { try context.save() }
        return moved
    }
}
