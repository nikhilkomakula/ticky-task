import Foundation
import SwiftData

/// "Load demo board" (Settings › Kanban): a small board that shows every part of the
/// module — people with different allocations, a contractor rolling off, cards in each
/// column, one overdue and blocked, labels, steps and an estimate. Never created on first run.
enum KanbanDemoSeed {
    @MainActor
    @discardableResult
    static func load(_ service: KanbanService, now: Date = Date(), calendar: Calendar = .current) throws -> KanbanProject {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        let project = try service.createProject(name: "Demo board", key: "DEMO", template: .software)
        let columns = project.orderedColumns
        let ana = try service.addMembership(try service.createPerson(name: "Ana Lopez", initials: "AL"), to: project)
        let sam = try service.addMembership(try service.createPerson(name: "Sam Okafor", initials: "SO"), to: project,
                                            allocationPercent: 50, assignment: .partTime)
        let kim = try service.addMembership(try service.createPerson(name: "Kim Park", initials: "KP", employment: .contractor), to: project)
        try service.editMembership(kim, [.endDate: .date(day(18))])
        let labels = project.labels.sorted { $0.sortIndex < $1.sortIndex }
        func card(_ title: String, _ column: Int, _ row: KanbanResource?, _ values: [KanbanService.TaskField: KanbanValue?] = [:],
                  label: Int? = nil, steps: [(String, Bool)] = []) throws {
            let task = try service.createTask(in: project, title: title, column: columns[column], row: row.map { .resource($0.id) } ?? .unassigned)
            if !values.isEmpty { try service.edit(task, values) }
            if let label { try service.setLabels(task, [labels[label]]) }
            for (title, done) in steps {
                let step = try service.addSubtask(to: task, title: title)
                if done { try service.setSubtaskDone(step, true) }
            }
        }
        try card("Plan the Q3 roadmap", 0, nil, [.priority: .int(TaskPriority.high.rawValue)], label: 0)
        try card("Research search providers", 0, nil, [:], label: 4)
        try card("Design the onboarding flow", 1, ana, [.dueDate: .date(day(4))], label: 0)
        try card("Fix login timeout", 2, ana, [.isCritical: .bool(true), .dueDate: .date(day(-2)), .isBlocked: .bool(true),
                                               .blockedReason: .string("Waiting on the auth team")], label: 1)
        try card("Write API docs", 2, sam, [.estimateHours: .double(6)], label: 5, steps: [("Endpoints", true), ("Examples", false)])
        try card("Migrate the billing service", 3, kim, [.dueDate: .date(day(6)), .jiraURL: .string("https://jira.example.com/browse/DEMO-42")], label: 3)
        try card("Set up error alerts", 4, kim, [:], label: 6)
        return project
    }
}
