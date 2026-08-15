import Testing
@testable import TickyTask

@MainActor
@Suite("Editor support")
struct EditorSupportTests {
    @Test("timeLabel formats minutes-since-midnight as HH:mm")
    func timeLabel() {
        #expect(TaskRowView.timeLabel(9 * 60) == "09:00")
        #expect(TaskRowView.timeLabel(13 * 60 + 5) == "13:05")
        #expect(TaskRowView.timeLabel(0) == "00:00")
        #expect(TaskRowView.timeLabel(23 * 60 + 59) == "23:59")
    }

    @Test("priority maps to/from the stored integer, clamping legacy values")
    func priorityMapping() {
        #expect(TaskPriority(rawValue: 0) == .low)
        #expect(TaskPriority(rawValue: 2) == .high)
        #expect(TaskPriority(rawValue: 3) == nil)             // the former "critical" level is gone
        // The stored-integer accessor clamps out-of-range values (legacy 3 → high).
        #expect(TaskItem(priority: 3).priorityLevel == .high)
        #expect(TaskItem(priority: -1).priorityLevel == .low)
        #expect(TaskItem(priority: 1).priorityLevel == .medium)
    }

    @Test("isCritical defaults off")
    func criticalDefaultsOff() {
        #expect(TaskItem(title: "x").isCritical == false)
    }
}
