import Foundation
import SwiftData

/// Where a task lives. Exactly one location per task — this single value
/// replaces the old pair of optional `(dayKey, list)` parameters so the
/// "day XOR custom list" invariant cannot be violated at the call site.
enum TaskLocation {
    case day(String)            // "yyyyMMdd"
    case customList(CustomList)
    case unassigned
}

/// Central mutation API over the SwiftData store.
///
/// Views call these methods instead of mutating models ad hoc, so ordering,
/// timestamps, and invariants stay in one place. Behavior rules (moving old
/// tasks, auto-reordering) build on top of this in `BehaviorService` (P4).
@MainActor
struct DataService {
    let context: ModelContext

    init(_ context: ModelContext) {
        self.context = context
    }

    // MARK: - Tasks

    @discardableResult
    func addTask(title: String, location: TaskLocation) throws -> TaskItem {
        let task: TaskItem
        switch location {
        case .day(let key):          task = TaskItem(title: title, dayKey: key)
        case .customList(let list):  task = TaskItem(title: title, customList: list)
        case .unassigned:            task = TaskItem(title: title)
        }
        task.sortIndex = try nextTaskSortIndex(for: location)
        context.insert(task)
        return task
    }

    func delete(_ task: TaskItem) {
        context.delete(task)
    }

    func toggleDone(_ task: TaskItem) {
        task.isDone.toggle()
        task.updatedAt = Date()
    }

    // MARK: - Subtasks

    @discardableResult
    func addSubtask(to task: TaskItem, title: String) -> Subtask {
        let nextIndex = (task.subtasks.map(\.sortIndex).max() ?? 0) + 1
        let subtask = Subtask(title: title, sortIndex: nextIndex)
        task.subtasks.append(subtask)
        task.updatedAt = Date()
        return subtask
    }

    // MARK: - Custom lists

    @discardableResult
    func addCustomList(name: String) throws -> CustomList {
        var descriptor = FetchDescriptor<CustomList>(
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let top = try context.fetch(descriptor).first?.sortIndex ?? 0
        let list = CustomList(name: name, sortIndex: top + 1)
        context.insert(list)
        return list
    }

    func delete(_ list: CustomList) {
        context.delete(list)
    }

    // MARK: - Persistence

    /// Save the context. Throws so callers (and the UI) can surface/recover
    /// from persistence failures rather than losing them silently.
    func save() throws {
        try context.save()
    }

    // MARK: - Ordering

    /// Next append sort index for a new task within its day/list.
    ///
    /// Uses a scoped, single-row fetch and **propagates** fetch failures — a
    /// swallowed error must not collapse to index 1 and duplicate an existing
    /// row's ordering.
    private func nextTaskSortIndex(for location: TaskLocation) throws -> Double {
        switch location {
        case .customList(let list):
            return (list.tasks.map(\.sortIndex).max() ?? 0) + 1

        case .day(let key):
            let target: String? = key
            var descriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.dayKey == target },
                sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            let top = try context.fetch(descriptor).first?.sortIndex ?? 0
            return top + 1

        case .unassigned:
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            let peers = all.filter { $0.dayKey == nil && $0.customList == nil }
            return (peers.map(\.sortIndex).max() ?? 0) + 1
        }
    }
}
