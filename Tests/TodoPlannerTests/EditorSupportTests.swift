import Testing
@testable import TodoPlanner

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

    @Test("priority maps to/from the stored integer")
    func priorityMapping() {
        #expect(TaskPriority(rawValue: 0) == TaskPriority.none)
        #expect(TaskPriority(rawValue: 3) == TaskPriority.high)
        #expect(TaskPriority.none.isFlagged == false)
        #expect(TaskPriority.high.isFlagged == true)
    }
}
