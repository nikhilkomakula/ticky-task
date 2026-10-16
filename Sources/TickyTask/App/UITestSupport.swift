import Foundation
import SwiftData

/// Deterministic setup for XCUITest runs, activated by the `-uitest` launch
/// argument. When present, `TickyTaskApp` opens an **in-memory** store (never the
/// user's real data) and this seeds a fixed set of tasks in the first visible week
/// column, so UI tests can drag them and assert the resulting order.
enum UITestSupport {
    static var isRunning: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }

    /// The app is the unit tests' host process (`TEST_HOST`). It must then open an
    /// in-memory store and skip launch work, or every test run would rewrite the
    /// user's real store and clear the real app's pending reminders.
    static var isHostingUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// `-uitestStore <path>`: an isolated on-disk store for UI tests that relaunch
    /// the app to check persistence. Never the user's store.
    static var diskStoreURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard isRunning, let index = args.firstIndex(of: "-uitestStore"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }

    /// A per-launch, emptied defaults suite for state the app persists itself
    /// (e.g. Weekly Summary choices), so each test starts clean.
    static let scratchDefaults: UserDefaults = {
        let name = "com.tickytask.mac.uitest"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

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
            if ProcessInfo.processInfo.arguments.contains("-uitestSummarySeed") {
                try seedWeeklySummary(service)
            }
            try service.save()
        } catch {
            // Seeding is best-effort; a failed seed just yields an empty test board.
        }
    }

    /// Opt-in extra tasks for the Weekly Summary UI tests (kept out of the default
    /// seed so other tests' fixtures are unchanged): two tasks with notes plus a
    /// same-titled unrelated one-off, all today.
    @MainActor
    private static func seedWeeklySummary(_ service: DataService) throws {
        let withNotes = try service.addTask(title: "Retry fix", location: .day(seededDayKey))
        withNotes.notes = "Verified recovery after transient gateway failures."
        let second = try service.addTask(title: "Rollout doc", location: .day(seededDayKey))
        second.notes = "Drafted the rollout plan."
        _ = try service.addTask(title: "No-notes task", location: .day(seededDayKey))
    }

    /// `-uitestSummaryDelay <seconds>` slows the stub generator (for the Cancel test).
    static var summaryDelay: Duration {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uitestSummaryDelay"), index + 1 < args.count,
              let seconds = Double(args[index + 1]) else { return .milliseconds(600) }
        return .milliseconds(Int(seconds * 1000))
    }

    /// `-uitestSummaryFailure auth` makes the stub generator fail with a 401, to
    /// exercise the error banner without a real provider.
    static var summaryFailure: WeeklySummaryError? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uitestSummaryFailure"), index + 1 < args.count else { return nil }
        switch args[index + 1] {
        case "auth":
            return .authenticationRejected(.codex, SummaryErrorDetail(
                message: "API Error: 401 authentication_error (stub)", exitCode: 1, httpStatus: 401, requestID: "req_stub123456"))
        default:
            return nil
        }
    }
}
