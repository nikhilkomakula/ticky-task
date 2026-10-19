import Foundation
import SwiftData

/// Deterministic setup for XCUITest runs, activated by the `-uitest` launch
/// argument. When present, `TickyTaskApp` opens an **in-memory** store — or, with
/// `-uitestStore <path>`, an isolated on-disk one; never the user's real data — and
/// this seeds a fixed set of tasks in the first visible week column.
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

    /// `-uitestKanbanVolume <N>`: seeds a board with N cards for scrolling performance tests.
    static var kanbanVolumeCardCount: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard isRunning, let index = args.firstIndex(of: "-uitestKanbanVolume"), index + 1 < args.count else { return nil }
        return Int(args[index + 1])
    }

    #if DEBUG
    /// `-uitestFailPurgeSaves`: every auto-delete save fails (a store that keeps
    /// rejecting saves), to exercise recovery without a restart loop.
    static var failPurgeSaves: Bool { isRunning && ProcessInfo.processInfo.arguments.contains("-uitestFailPurgeSaves") }

    /// `-uitestFailTaskSave`: the first editor Done fails to save, to exercise the
    /// save-error path.
    @MainActor static var failNextTaskSave = isRunning && ProcessInfo.processInfo.arguments.contains("-uitestFailTaskSave")
    #endif

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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uitestOldCompletion") {
                // Completed a month ago: due for auto-delete.
                let old = try service.addTask(title: "Done long ago", location: .day(seededDayKey))
                old.setDone(true, at: Date(timeIntervalSinceNow: -30 * 86_400))
            }
            #endif
            if ProcessInfo.processInfo.arguments.contains("-uitestRecurringSeed") {
                try seedRecurringSeries(service)
            }
            try service.save()
            if ProcessInfo.processInfo.arguments.contains("-uitestKanbanSeed") {
                try seedKanban(context)
            }
            if ProcessInfo.processInfo.arguments.contains("-uitestKanbanVaried") {
                try seedVariedBoard(context)
            }
            if let cardCount = kanbanVolumeCardCount {
                _ = try KanbanVolumeSeed.seed(into: context, cardCount: cardCount)
            }
        } catch {
            // Seeding is best-effort; a failed seed just yields an empty test board.
        }
    }

    /// Opt-in boards for the Kanban UI tests: "Platform" (Ravi full-time; Mia, a 50%
    /// part-time contractor ending in 10 days; cards in every column, one overdue and
    /// blocked) and "Data", where Mia is 60%, so she's over-allocated across boards.
    @MainActor
    private static func seedKanban(_ context: ModelContext) throws {
        let kanban = KanbanService(context)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let platform = try kanban.createProject(name: "Platform", key: "PLAT")
        let ravi = try kanban.addMembership(try kanban.createPerson(name: "Ravi Kumar", initials: "RK"), to: platform)
        let miaPerson = try kanban.createPerson(name: "Mia Chen", initials: "MC", employment: .contractor)
        let mia = try kanban.addMembership(miaPerson, to: platform, allocationPercent: 50, assignment: .partTime)
        try kanban.editMembership(mia, [.endDate: .date(calendar.date(byAdding: .day, value: 10, to: today)!)])
        let columns = platform.orderedColumns
        _ = try kanban.createTask(in: platform, title: "Triage inbox")
        let api = try kanban.createTask(in: platform, title: "Build API", column: columns[1], row: .resource(ravi.id))
        try kanban.edit(api, [.priority: .int(TaskPriority.high.rawValue), .dueDate: .date(calendar.date(byAdding: .day, value: -2, to: today)!),
                              .isBlocked: .bool(true), .blockedReason: .string("Waiting on keys")])
        _ = try kanban.createTask(in: platform, title: "Write docs", column: columns[1], row: .resource(mia.id))
        _ = try kanban.createTask(in: platform, title: "Ship v1", column: columns[2], row: .resource(ravi.id))
        let data = try kanban.createProject(name: "Data", key: "DATA")
        let miaOnData = try kanban.addMembership(miaPerson, to: data, allocationPercent: 60)
        _ = try kanban.createTask(in: data, title: "Load warehouse", column: data.orderedColumns[1], row: .resource(miaOnData.id))
        // `-uitestKanbanDone`: seven more of Ravi's cards finished 1–7 days ago, so his Done
        // cell (with Ship v1, finished now) shows five and tucks three away.
        if ProcessInfo.processInfo.arguments.contains("-uitestKanbanDone") {
            for index in 1...7 {
                let card = try kanban.createTask(in: platform, title: "Finished \(index)", column: columns[2], row: .resource(ravi.id))
                card.completedAt = calendar.date(byAdding: .day, value: -index, to: Date())
            }
            try context.save()
        }
        // `-uitestKanbanHolidays`: this week's Wednesday is "Seed Day", and next week is a
        // "Shutdown" closing a week Ravi had overridden, so the override needs review.
        if ProcessInfo.processInfo.arguments.contains("-uitestKanbanHolidays") {
            let monday = KanbanDay.today().monday, next = KanbanDay.today().monday.adding(days: 7)
            try kanban.setOverride(ravi, week: next, halfDays: 8)
            try kanban.addHoliday(KanbanHolidayDTO(day: monday.adding(days: 2).key, name: "Seed Day"), on: platform)
            for day in 0..<5 { try kanban.addHoliday(KanbanHolidayDTO(day: next.adding(days: day).key, name: "Shutdown"), on: platform) }
        }
        // `-uitestKanbanWide`: enough columns that the board scrolls sideways.
        if ProcessInfo.processInfo.arguments.contains("-uitestKanbanWide") {
            for index in 1...6 { _ = try kanban.addColumn(to: platform, name: "Stage \(index)", at: 2) }
        }
    }

    /// `-uitestKanbanVaried`: a small board shaped like a real one that once sent the lazily
    /// built rows into an endless layout loop when scrolled in jumps: twelve people plus
    /// Unassigned, 26 cards one to three per cell in To Do and In Progress, labelled titles that
    /// wrap to one, two or three lines, sorted by priority.
    @MainActor
    private static func seedVariedBoard(_ context: ModelContext) throws {
        let kanban = KanbanService(context)
        let board = try kanban.createProject(name: "Varied", key: "VAR", template: .standard)
        let names = ["Avery Stone", "Jordan Patel", "Riley Moreno", "Casey Lindqvist", "Morgan Oyelaran", "Quinn Adebayo",
                     "Taylor Brooks", "Rowan Iyer", "Sam Okafor", "Drew Castellanos", "Harper Nakamura-Wells", "Elliot Fry"]
        var rows: [KanbanRowKey] = []
        for (index, name) in names.enumerated() {
            let person = try kanban.createPerson(name: name, initials: String(name.split(separator: " ").compactMap(\.first)),
                                                 employment: index % 5 < 2 ? .contractor : .fte)
            rows.append(.resource(try kanban.addMembership(person, to: board).id))
        }
        rows.append(.unassigned)
        let titles = ["Intro call with the data architect", "Pending wave one ops and resources", "Code isolation",
                      "Discuss post go-live enhancements with the customer", "Review wave one documentation",
                      "Evaluation pipeline", "Conversational flow type two", "Requirements review for analytics",
                      "Audit agents", "Retrospective notes and follow-ups"]
        // (row, column, cards): the real board's sparse cells.
        let cells = [(0, 0, 1), (1, 0, 3), (2, 0, 1), (2, 1, 2), (3, 0, 1), (4, 0, 3), (5, 0, 3), (6, 1, 2), (7, 0, 1),
                     (7, 1, 1), (8, 1, 1), (9, 1, 1), (10, 0, 2), (11, 1, 3), (12, 0, 1)]
        let labels = board.labels.sorted { $0.sortIndex < $1.sortIndex }
        var count = 0
        for (row, column, cards) in cells {
            for _ in 0..<cards {
                let task = try kanban.createTask(in: board, title: titles[count % titles.count], column: board.orderedColumns[column],
                                                 row: rows[row])
                task.priority = [1, 2, 1, 0, 2][count % 5]
                if !labels.isEmpty, count % 8 != 7 { task.labels = Array(labels.prefix(1 + count % 2)) }
                count += 1
            }
        }
        board.boardState = { var state = KanbanBoardState.decode(board.boardState); state.sort = .priority; return state.encoded() }()
        try context.save()
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

    /// Opt-in seed for recurring series tests: creates daily "Standup" (started 2 days
    /// ago with past done occurrence), "Paycheck" (1st & 15th of month), and weekly
    /// "Meeting" series.
    @MainActor
    private static func seedRecurringSeries(_ service: DataService) throws {
        let today = Date()
        let calendar = Calendar.current

        // Daily "Standup" starting 2 days ago
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let standupKey = WeekMath.dayKey(for: twoDaysAgo)
        let standup = try service.addTask(title: "Standup", location: .day(standupKey))

        let standupRule = RecurrenceRule(
            frequency: .daily,
            interval: 1,
            end: .never,
            startDate: twoDaysAgo
        )
        try RecurrenceMaterializer.startSeries(from: standup, rule: standupRule,
                                               through: calendar.date(byAdding: .day, value: 60, to: today)!,
                                               context: service.context)

        // Mark the first occurrence (2 days ago) as done
        standup.setDone(true)

        // "Paycheck" on 1st and 15th of the month
        let paycheckKey = WeekMath.dayKey(for: today)
        let paycheck = try service.addTask(title: "Paycheck", location: .day(paycheckKey))
        let paycheckRule = RecurrenceRule(
            frequency: .daysOfMonth,
            interval: 1,
            monthDays: [1, 15],
            end: .never,
            startDate: today
        )
        try RecurrenceMaterializer.startSeries(from: paycheck, rule: paycheckRule,
                                               through: calendar.date(byAdding: .day, value: 60, to: today)!,
                                               context: service.context)

        // Weekly "Meeting" on the same weekday as today
        let meetingKey = WeekMath.dayKey(for: today)
        let meeting = try service.addTask(title: "Meeting", location: .day(meetingKey))
        let todayWeekday = calendar.component(.weekday, from: today)
        let meetingRule = RecurrenceRule(
            frequency: .customWeekdays,
            interval: 1,
            weekdays: Set([todayWeekday]),
            end: .never,
            startDate: today
        )
        try RecurrenceMaterializer.startSeries(from: meeting, rule: meetingRule,
                                               through: calendar.date(byAdding: .day, value: 60, to: today)!,
                                               context: service.context)
    }
}
