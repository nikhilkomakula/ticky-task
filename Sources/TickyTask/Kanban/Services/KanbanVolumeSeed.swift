import Foundation
import SwiftData

/// A large, deterministic board for scrolling benchmarks (UI tests under `-uitest` and unit
/// tests only): 29 people, the standard columns and `cardCount` cards. Three hot cells hold a
/// quarter of the cards between them, the rest spread over every cell; cards carry priorities,
/// estimates, due dates, labels, blockers, dependencies and subtasks, so every card icon renders.
/// The board and people go through the service; cards are inserted directly and saved once,
/// since thousands of service saves would outlast a UI test's launch.
enum KanbanVolumeSeed {
    @MainActor
    @discardableResult
    static func seed(into context: ModelContext, cardCount: Int = 2000, now: Date = Date()) throws -> KanbanProject {
        let service = KanbanService(context)
        let project = try service.createProject(name: "Volume", key: "VOL", template: .standard)
        let columns = project.orderedColumns
        let labels = project.labels.sorted { $0.sortIndex < $1.sortIndex }
        var rng = SeededRNG(seed: 0xDEADBEEF)
        var members: [KanbanResource] = []
        for name in names {
            let initials = String(name.split(separator: " ").compactMap(\.first))
            members.append(try service.addMembership(try service.createPerson(name: name, initials: initials), to: project))
        }
        let hot = (0..<3).map { _ in (columns[rng.below(columns.count)], members[rng.below(members.count)]) }
        let today = Calendar.current.startOfDay(for: now)
        var nextSort: [ObjectIdentifier: Double] = [:]
        var previous: KanbanTask?
        for n in 0..<cardCount {
            let (column, member) = n % 4 == 0 ? hot[n / 4 % 3] : (columns[rng.below(columns.count)], members[rng.below(members.count)])
            let cell = ObjectIdentifier(column)
            let task = KanbanTask(title: "Task \(n + 1)", priority: rng.below(3), sortIndex: nextSort[cell, default: 0])
            nextSort[cell, default: 0] += 1
            context.insert(task)
            task.project = project
            task.column = column
            task.resource = member
            task.isCritical = rng.below(10) == 0
            if rng.below(3) == 0 { task.estimateHours = Double([1, 2, 4, 8][rng.below(4)]) }
            if rng.below(5) == 0 { task.dueDate = Calendar.current.date(byAdding: .day, value: rng.below(36) - 5, to: today) }
            if rng.below(20) == 0 { task.isBlocked = true; task.blockedReason = "Waiting on review" }
            if rng.below(3) == 0 { task.complexity = 1 + rng.below(3) }
            if !labels.isEmpty, rng.below(6) == 0 { task.labels = [labels[rng.below(labels.count)]] }
            if rng.below(10) == 0 {
                for i in 0..<(1 + rng.below(3)) {
                    let step = KanbanSubtask(title: "Step \(i + 1)", isDone: rng.below(2) == 0, sortIndex: Double(i))
                    context.insert(step)
                    step.task = task
                }
            }
            if let previous, rng.below(25) == 0 { task.dependsOn = [previous] }
            if column.kind == .done { task.completedAt = today }
            previous = task
        }
        try context.save()
        return project
    }

    private static let names = [
        "Alice Johnson", "Bob Chen", "Carol Davis", "David Martinez", "Emma Wilson", "Frank Brown", "Grace Lee",
        "Henry Taylor", "Ivy Anderson", "Jack White", "Karen Black", "Leo Garcia", "Mia Rodriguez", "Nathan Harris",
        "Olivia Martin", "Patricia Clark", "Quinn Lewis", "Ryan Robinson", "Sophie Young", "Thomas King", "Uma Patel",
        "Victor Scott", "Wendy Green", "Xavier Adams", "Yara Nelson", "Zoe Hall", "Amber Turner", "Blake Phillips",
        "Casey Parker",
    ]
}

/// A seeded linear congruential generator, so every run builds the same board.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    /// 0 ..< bound.
    mutating func below(_ bound: Int) -> Int { Int.random(in: 0..<bound, using: &self) }
}
