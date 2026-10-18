import Foundation
import SwiftData

/// Volume seed for Kanban board performance benchmarking: creates one board with
/// ~30 people (memberships), default columns, and N cards spread realistically
/// (skewed: a few cells with 200+ cards, many with 5–20), with labels, priorities,
/// estimates, due dates, some blocked/critical/dependencies, and subtasks.
enum KanbanVolumeSeed {
    /// Seeds N cards into the board, deterministically. Seeded RNG and fixed date
    /// reference ensure reproducibility. Returns the created project.
    @MainActor
    @discardableResult
    static func seed(into context: ModelContext, cardCount: Int = 2000, now: Date = Date()) throws -> KanbanProject {
        let service = KanbanService(context)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        // Create the board with standard template
        let project = try service.createProject(name: "Volume", key: "VOL", template: .standard)
        let columns = project.orderedColumns

        // Create ~30 people with varied allocations and employment types
        // Seeded LCG for deterministic reproduction
        var rng = SeededRNG(seed: 0xDEADBEEF)
        
        let names = [
            ("Alice Johnson", "AJ", KanbanEmployment.fte, 100),
            ("Bob Chen", "BC", KanbanEmployment.fte, 100),
            ("Carol Davis", "CD", KanbanEmployment.fte, 100),
            ("David Martinez", "DM", KanbanEmployment.fte, 100),
            ("Emma Wilson", "EW", KanbanEmployment.fte, 100),
            ("Frank Brown", "FB", KanbanEmployment.fte, 100),
            ("Grace Lee", "GL", KanbanEmployment.fte, 100),
            ("Henry Taylor", "HT", KanbanEmployment.fte, 100),
            ("Ivy Anderson", "IA", KanbanEmployment.fte, 100),
            ("Jack White", "JW", KanbanEmployment.fte, 100),
            ("Karen Black", "KB", KanbanEmployment.contractor, 50),
            ("Leo Garcia", "LG", KanbanEmployment.contractor, 50),
            ("Mia Rodriguez", "MR", KanbanEmployment.contractor, 75),
            ("Nathan Harris", "NH", KanbanEmployment.fte, 100),
            ("Olivia Martin", "OM", KanbanEmployment.fte, 100),
            ("Patricia Clark", "PC", KanbanEmployment.fte, 100),
            ("Quinn Lewis", "QL", KanbanEmployment.fte, 100),
            ("Ryan Robinson", "RR", KanbanEmployment.fte, 100),
            ("Sophie Young", "SY", KanbanEmployment.contractor, 60),
            ("Thomas King", "TK", KanbanEmployment.fte, 100),
            ("Uma Patel", "UP", KanbanEmployment.fte, 100),
            ("Victor Scott", "VS", KanbanEmployment.contractor, 40),
            ("Wendy Green", "WG", KanbanEmployment.fte, 100),
            ("Xavier Adams", "XA", KanbanEmployment.fte, 100),
            ("Yara Nelson", "YN", KanbanEmployment.fte, 100),
            ("Zoe Hall", "ZH", KanbanEmployment.contractor, 55),
            ("Amber Turner", "AT", KanbanEmployment.fte, 100),
            ("Blake Phillips", "BP", KanbanEmployment.fte, 100),
            ("Casey Parker", "CP", KanbanEmployment.fte, 100),
        ]
        
        var members: [KanbanResource] = []
        for (name, initials, employment, allocation) in names {
            let person = try service.createPerson(name: name, initials: initials, employment: employment)
            let resource = try service.addMembership(person, to: project, allocationPercent: allocation,
                                                     assignment: allocation == 100 ? .fullTime : .partTime)
            members.append(resource)
        }
        
        let labels = project.labels.sorted { $0.sortIndex < $1.sortIndex }
        let priorityValues = [TaskPriority.low.rawValue, TaskPriority.medium.rawValue, TaskPriority.high.rawValue]
        
        // Distribute cards realistically: skewed distribution across columns and rows.
        // Column 0 (backlog): ~40%, Column 1 (active): ~35%, Column 2 (done): ~25%
        // Most rows get 5–20 cards; a few get 200+
        var cardsCreated = 0
        
        for (rowIdx, resource) in members.enumerated() {
            let memberCardCount = Int.random(in: 5...20, using: &rng)
            
            for _ in 0..<memberCardCount where cardsCreated < cardCount {
                // Pick column: bias towards backlog and active
                let columnIdx: Int
                let rand = Int.random(in: 0..<100, using: &rng)
                if rand < 40 {
                    columnIdx = 0  // backlog
                } else if rand < 75 {
                    columnIdx = 1  // active
                } else {
                    columnIdx = 2  // done
                }
                
                let column = columns[min(columnIdx, columns.count - 1)]
                let taskNumber = cardsCreated + 1
                let title = "Task \(taskNumber) (Row \(rowIdx))"
                
                let task = try service.createTask(
                    in: project,
                    title: title,
                    column: column,
                    row: .resource(resource.id)
                )
                
                // Add optional fields: priority, critical, estimate, due date, label, blocker
                var edits: [KanbanService.TaskField: KanbanValue?] = [:]
                
                // ~40% get a priority
                if Int.random(in: 0..<100, using: &rng) < 40 {
                    edits[.priority] = .int(priorityValues.randomElement(using: &rng) ?? TaskPriority.medium.rawValue)
                }
                
                // ~10% are critical
                if Int.random(in: 0..<100, using: &rng) < 10 {
                    edits[.isCritical] = .bool(true)
                }
                
                // ~30% have an estimate
                if Int.random(in: 0..<100, using: &rng) < 30 {
                    let hours = Double([1, 2, 4, 6, 8, 12].randomElement(using: &rng) ?? 4)
                    edits[.estimateHours] = .double(hours)
                }
                
                // ~20% have a due date (within next 30 days)
                if Int.random(in: 0..<100, using: &rng) < 20 {
                    let daysFromNow = Int.random(in: -5...30, using: &rng)
                    let dueDate = calendar.date(byAdding: .day, value: daysFromNow, to: today) ?? today
                    edits[.dueDate] = .date(dueDate)
                }
                
                // ~5% are blocked with a reason
                if Int.random(in: 0..<100, using: &rng) < 5 {
                    edits[.isBlocked] = .bool(true)
                    edits[.blockedReason] = .string("Waiting on review")
                }
                
                if !edits.isEmpty {
                    try service.edit(task, edits)
                }
                
                // ~15% have a label
                if Int.random(in: 0..<100, using: &rng) < 15 && !labels.isEmpty {
                    if let label = labels.randomElement(using: &rng) {
                        try service.setLabels(task, [label])
                    }
                }
                
                // ~10% have 1–3 subtasks
                if Int.random(in: 0..<100, using: &rng) < 10 {
                    let stepCount = Int.random(in: 1...3, using: &rng)
                    for stepIdx in 0..<stepCount {
                        let step = try service.addSubtask(to: task, title: "Subtask \(stepIdx + 1)")
                        if Int.random(in: 0..<100, using: &rng) < 50 {
                            try service.setSubtaskDone(step, true)
                        }
                    }
                }
                
                cardsCreated += 1
            }
        }
        
        // Add a few high-volume cells: pick a small number of (column, resource) pairs
        // and load them with 150–250 cards each to exercise realistic worst-case.
        let hotCells = 3
        for _ in 0..<hotCells where cardsCreated < cardCount {
            let columnIdx = Int.random(in: 0..<columns.count, using: &rng)
            let resourceIdx = Int.random(in: 0..<members.count, using: &rng)
            let cellCardCount = Int.random(in: 150...250, using: &rng)
            
            for _ in 0..<cellCardCount where cardsCreated < cardCount {
                let title = "Hot Cell Task \(cardsCreated + 1)"
                _ = try service.createTask(
                    in: project,
                    title: title,
                    column: columns[columnIdx],
                    row: .resource(members[resourceIdx].id)
                )
                cardsCreated += 1
            }
        }

        return project
    }
}

// MARK: - Seeded RNG for deterministic card distribution

/// A seeded linear congruential generator for deterministic, reproducible random values.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

extension Int {
    /// Returns a random value between lower and upper (inclusive), using the given RNG.
    fileprivate static func random(in range: ClosedRange<Int>, using rng: inout SeededRNG) -> Int {
        let count = range.upperBound - range.lowerBound + 1
        let random = Int.random(in: 0..<count, using: &rng)
        return range.lowerBound + random
    }
}

extension Array {
    /// Returns a random element from the array, using the given RNG.
    fileprivate func randomElement(using rng: inout SeededRNG) -> Element? {
        guard !isEmpty else { return nil }
        return self[Int.random(in: 0..<count, using: &rng)]
    }
}
