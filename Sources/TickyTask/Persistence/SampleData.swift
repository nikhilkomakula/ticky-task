import Foundation
import SwiftData

/// Seeds a small set of welcome tasks on first launch (when the store is
/// completely empty), mirroring the legacy app's initial sample data. Safe to
/// call on every launch — it no-ops once anything exists.
enum SampleData {
    @MainActor
    static func seedIfEmpty(_ context: ModelContext) {
        let taskCount = (try? context.fetchCount(FetchDescriptor<TaskItem>())) ?? 0
        let listCount = (try? context.fetchCount(FetchDescriptor<CustomList>())) ?? 0
        guard taskCount == 0, listCount == 0 else { return }

        let service = DataService(context)
        let today = WeekMath.dayKey(for: Date())

        do {
            let review = try service.addTask(title: "Review pull request", location: .day(today))
            review.priorityLevel = .high
            review.isCritical = true
            review.timeMinutes = 10 * 60
            service.addSubtask(to: review, title: "Check the tests pass")
            service.addSubtask(to: review, title: "Leave review comments")

            let lunch = try service.addTask(title: "Lunch with the team", location: .day(today))
            lunch.priorityLevel = .low
            lunch.timeMinutes = 12 * 60 + 30

            let plan = try service.addTask(title: "Draft weekly plan", location: .day(today))
            plan.priorityLevel = .medium
            plan.notes = """
            This week's goals:

            - **Ship** the weekly view
            - Start the *calendar* month view
            - Review everything with `Codex`
            """

            // Default custom lists (renamable; persist across all weeks).
            for name in ["Requires immediate attention", "To be addressed", "Weekend tasks", "Miscellaneous"] {
                _ = try service.addCustomList(name: name)
            }

            try service.save()
        } catch {
            // First-run seeding is best-effort; ignore failures.
        }
    }
}
