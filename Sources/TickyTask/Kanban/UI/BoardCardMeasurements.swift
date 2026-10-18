import Foundation
import CoreGraphics

/// Measurements survive saves elsewhere; only a card's own layout inputs invalidate it.
struct BoardCardMeasurements {
    struct Key: Equatable {
        var width: CGFloat
        var compact: Bool
        var title: String
        var priority: Int
        var isCritical: Bool
        var labelNames: [String]
        var isBlocked: Bool
        var dueDate: Date?
        var startDate: Date?
        var estimateHours: Double?
        var complexity: Int?
        var jiraKey: String?
        var hasNotes: Bool
        var subtasksDone: Int
        var subtasksTotal: Int
        var waitingCount: Int
        var isDone: Bool
        var isArchived: Bool
        var dueSoonThresholdDays: Int?
        var clock: String

        @MainActor
        init(task: KanbanTask, width: CGFloat, compact: Bool, clock: String) {
            self.width = width
            self.compact = compact
            title = task.title
            priority = task.priority
            isCritical = task.isCritical
            labelNames = task.labels.sorted { $0.sortIndex < $1.sortIndex }.map(\.name)
            isBlocked = task.isBlocked
            dueDate = task.dueDate
            startDate = task.startDate
            estimateHours = task.estimateHours
            complexity = task.complexity
            jiraKey = task.jiraKey
            hasNotes = task.hasNotes
            subtasksDone = task.subtasks.filter(\.isDone).count
            subtasksTotal = task.subtasks.count
            waitingCount = task.dependsOn.filter { $0.archivedAt != nil || $0.column?.kind != .done }.count
            isDone = task.column?.kind == .done
            isArchived = task.archivedAt != nil
            dueSoonThresholdDays = task.project?.dueSoonThresholdDays
            self.clock = clock
        }
    }

    private struct Entry {
        var key: Key
        var height: CGFloat
    }

    private var entries: [UUID: Entry] = [:]

    func heights(for keys: [UUID: Key]) -> [UUID: CGFloat] {
        var heights: [UUID: CGFloat] = [:]
        for (id, key) in keys {
            if let entry = entries[id], entry.key == key { heights[id] = entry.height }
        }
        return heights
    }

    mutating func record(_ height: CGFloat, for id: UUID, key: Key) {
        guard entries[id]?.key != key || entries[id]?.height != height else { return }
        entries[id] = Entry(key: key, height: height)
    }

    mutating func retain(_ ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}
