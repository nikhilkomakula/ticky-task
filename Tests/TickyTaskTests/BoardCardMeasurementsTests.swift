import Testing
import Foundation
@testable import TickyTask

@Suite("Board card measurements")
@MainActor
struct BoardCardMeasurementsTests {
    private func key(_ task: KanbanTask, width: CGFloat = 250, compact: Bool = false, clock: String = "2026-10-18") -> BoardCardMeasurements.Key {
        BoardCardMeasurements.Key(task: task, width: width, compact: compact, clock: clock)
    }

    @Test("An unrelated save preserves a long cell's learned heights and visible window")
    func unrelatedSave() {
        let tasks = (0..<200).map { KanbanTask(title: "Card \($0)") }
        let keys = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, key($0)) })
        var measurements = BoardCardMeasurements()
        for task in tasks { measurements.record(40, for: task.id, key: keys[task.id]!) }
        let before = BoardCardLayout(ids: tasks.map(\.id), measuredHeights: measurements.heights(for: keys))

        // A save on another board advances the global metrics generation only.
        var metrics = KanbanMetricsCache.Key(generation: 1, clock: "2026-10-18", weekStartsMonday: true)
        metrics.generation += 1
        let afterKeys = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, key($0, clock: metrics.clock)) })
        let after = BoardCardLayout(ids: tasks.map(\.id), measuredHeights: measurements.heights(for: afterKeys))

        #expect(before == after)
        #expect(after.totalHeight == 9_194)
        #expect(after.visibleIndices(in: 6_900...7_100, overscan: 0) == Array(150...154))
    }

    @Test("Editing a card invalidates its measurement without discarding its neighbors")
    func editedCard() {
        let edited = KanbanTask(title: "Before"), neighbor = KanbanTask(title: "Neighbor")
        var measurements = BoardCardMeasurements()
        measurements.record(40, for: edited.id, key: key(edited))
        measurements.record(90, for: neighbor.id, key: key(neighbor))

        let updatedAt = edited.updatedAt
        edited.title = "A much longer edited title that can wrap"
        let keys = [edited.id: key(edited), neighbor.id: key(neighbor)]
        let layout = BoardCardLayout(ids: [edited.id, neighbor.id], measuredHeights: measurements.heights(for: keys))

        #expect(edited.updatedAt == updatedAt, "undo can change content without changing its timestamp")
        #expect(layout.heights == [72, 90])
        measurements.record(110, for: edited.id, key: key(edited))
        #expect(measurements.heights(for: keys) == [edited.id: 110, neighbor.id: 90])
    }

    @Test("Widths and density invalidate measurements independently of saves")
    func widthAndDensity() {
        let task = KanbanTask(title: "Wrap to the card width")
        var measurements = BoardCardMeasurements()
        measurements.record(90, for: task.id, key: key(task))

        #expect(measurements.heights(for: [task.id: key(task, width: 180)]).isEmpty)
        #expect(measurements.heights(for: [task.id: key(task, compact: true)]).isEmpty)
        #expect(measurements.heights(for: [task.id: key(task)]) == [task.id: 90])
    }

    @Test("Related display changes invalidate a card even without changing its timestamp")
    func relatedContent() {
        let task = KanbanTask(title: "Card")
        let project = KanbanProject(name: "Board")
        let label = KanbanLabel(name: "Feature")
        let dependency = KanbanTask(title: "Prerequisite")
        let column = KanbanColumn(name: "To Do", kind: .active)
        task.labels = [label]
        task.dependsOn = [dependency]
        task.column = column
        task.project = project
        var measurements = BoardCardMeasurements()
        let original = key(task)
        measurements.record(72, for: task.id, key: original)

        label.name = "A longer label that wraps"
        #expect(measurements.heights(for: [task.id: key(task)]).isEmpty)
        label.name = "Feature"
        let done = KanbanColumn(name: "Done", kind: .done)
        dependency.column = done
        #expect(measurements.heights(for: [task.id: key(task)]).isEmpty)
        dependency.column = nil
        column.kind = .done
        #expect(measurements.heights(for: [task.id: key(task)]).isEmpty)
        column.kind = .active
        #expect(measurements.heights(for: [task.id: key(task, clock: "2026-10-19")]).isEmpty)
        project.dueSoonThresholdDays += 1
        #expect(measurements.heights(for: [task.id: key(task)]).isEmpty)
        project.dueSoonThresholdDays -= 1
        #expect(measurements.heights(for: [task.id: key(task)]) == [task.id: 72])
    }

    @Test("Metadata changes invalidate a card without changing its timestamp",
          arguments: ["notes", "due", "start", "archive", "priority", "critical", "blocked", "estimate", "complexity", "jira"])
    func directMetadataChange(field: String) {
        let task = KanbanTask(title: "Card"), neighbor = KanbanTask(title: "Neighbor")
        let updatedAt = task.updatedAt
        var measurements = BoardCardMeasurements()
        measurements.record(40, for: task.id, key: key(task))
        measurements.record(90, for: neighbor.id, key: key(neighbor))

        switch field {
        case "notes": task.notes = "A note"
        case "due": task.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        case "start": task.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        case "archive": task.archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        case "priority": task.priority = 2
        case "critical": task.isCritical = true
        case "blocked": task.isBlocked = true
        case "estimate": task.estimateHours = 12
        case "complexity": task.complexity = 3
        case "jira": task.jiraURL = "https://example.com/browse/BOARD-123"
        default: Issue.record("Unknown metadata field: \(field)")
        }

        #expect(task.updatedAt == updatedAt)
        let heights = measurements.heights(for: [task.id: key(task), neighbor.id: key(neighbor)])
        #expect(heights == [neighbor.id: 90])
    }

    @Test("Checklist add, completion and removal invalidate a card without changing its timestamp")
    func subtaskChanges() {
        let task = KanbanTask(title: "Checklist card")
        let updatedAt = task.updatedAt
        let step = KanbanSubtask(title: "First step")
        var measurements = BoardCardMeasurements()
        measurements.record(40, for: task.id, key: key(task))

        task.subtasks = [step]
        #expect(measurements.heights(for: [task.id: key(task)]).isEmpty)
        measurements.record(60, for: task.id, key: key(task))
        step.isDone = true
        #expect(measurements.heights(for: [task.id: key(task)]).isEmpty)
        measurements.record(60, for: task.id, key: key(task))
        task.subtasks = []
        #expect(measurements.heights(for: [task.id: key(task)]).isEmpty)
        #expect(task.updatedAt == updatedAt)
    }

    @Test("Timestamp, tooltip and note text edits preserve unchanged card layout")
    func unchangedLayout() {
        let task = KanbanTask(title: "Card")
        task.notes = "Existing note"
        var measurements = BoardCardMeasurements()
        measurements.record(60, for: task.id, key: key(task))

        task.updatedAt.addTimeInterval(1)
        task.blockedReason = "Only the tooltip changes"
        task.notes = "Different note, same notes marker"

        #expect(measurements.heights(for: [task.id: key(task)]) == [task.id: 60])
    }
}
