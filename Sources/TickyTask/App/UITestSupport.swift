import Foundation
import SwiftData

/// Deterministic setup for XCUITest runs, activated by the `-uitest` launch
/// argument. When present, `TickyTaskApp` opens an **in-memory** store (never the
/// user's real data) and this seeds a fixed set of tasks in the first visible week
/// column, so UI tests can drag them and assert the resulting order.
enum UITestSupport {
    static var isRunning: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }

    static let seededTitles = ["Alpha", "Bravo", "Charlie"]

    /// The day key the seeded tasks live in: TODAY. The UI test forces the week
    /// view to 7 columns (via a launch arg) so today is always on screen, and this
    /// is unambiguous and deterministic (no start-of-week/week-start dependence).
    @MainActor static var seededDayKey: String {
        WeekMath.dayKey(for: Date())
    }

    @MainActor
    static func seed(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<TaskItem>())) ?? 0
        guard count == 0 else { return }
        let service = DataService(context)
        do {
            for title in seededTitles {
                _ = try service.addTask(title: title, location: .day(seededDayKey))
            }
            // A custom list with its own tasks, for within-list reorder tests.
            let list = try service.addCustomList(name: "Inbox")
            for title in ["ListA", "ListB", "ListC"] {
                _ = try service.addTask(title: title, location: .customList(list))
            }
            try service.save()
        } catch {
            // Seeding is best-effort; a failed seed just yields an empty test board.
        }
    }
}
