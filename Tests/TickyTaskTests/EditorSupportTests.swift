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

    @Test("priority maps to/from the stored integer")
    func priorityMapping() {
        #expect(TaskPriority(rawValue: 0) == TaskPriority.low)
        #expect(TaskPriority(rawValue: 3) == TaskPriority.critical)
        #expect(TaskPriority.critical.isCritical == true)
        #expect(TaskPriority.high.isCritical == false)
        #expect(TaskPriority.critical.symbol == "flag.fill")
    }
}
