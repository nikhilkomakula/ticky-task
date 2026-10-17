import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// A board's remembered view state and card filter (design 01 §5).
@MainActor
@Suite("Kanban board state", .serialized)
struct KanbanBoardStateTests {
    @Test("Board state survives missing, unknown and malformed keys")
    func tolerantDecoding() throws {
        #expect(KanbanBoardState.decode(nil) == KanbanBoardState())
        #expect(KanbanBoardState.decode(Data("not json".utf8)) == KanbanBoardState())
        let json = #"{"view":"list","sort":"someday","showArchived":true,"future":1,"filter":{"text":"api","due":"overdue","hasJira":false,"x":2}}"#
        let state = KanbanBoardState.decode(Data(json.utf8))
        #expect(state.view == .list && state.sort == .manual && state.showArchived)
        #expect(state.filter.text == "api" && state.filter.due == .overdue && state.filter.hasJira == false)
        var round = state
        round.sort = .dueDate
        #expect(KanbanBoardState.decode(round.encoded()) == round)
    }

    private func board() throws -> (KanbanService, KanbanProject, KanbanResource, [String: KanbanTask]) {
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()))
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let ravi = try service.addMembership(try service.createPerson(name: "Ravi", initials: "RV"), to: project)
        var cards: [String: KanbanTask] = [:]
        for title in ["Build API", "Write docs", "Fix login", "Plan"] { cards[title] = try service.createTask(in: project, title: title) }
        return (service, project, ravi, cards)
    }

    @Test("Each filter condition narrows the cards, and they combine")
    func filterConditions() throws {
        let (s, project, ravi, cards) = try board()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        try s.edit(cards["Build API"]!, [.priority: .int(2), .isBlocked: .bool(true), .dueDate: .date(calendar.date(byAdding: .day, value: -1, to: today)!),
                                         .jiraURL: .string("https://jira.example.com/browse/PLAT-1"), .estimateHours: .double(3)])
        try s.edit(cards["Write docs"]!, [.isCritical: .bool(true), .notes: .string("about the API")])
        try s.move(.cards([cards["Fix login"]!.id], to: .rowHeader(.resource(ravi.id))), in: project)
        let label = try #require(project.labels.first)
        try s.setLabels(cards["Plan"]!, [label])
        func titles(_ change: (inout KanbanCardFilter) -> Void) -> Set<String> {
            var f = KanbanCardFilter()
            change(&f)
            return Set(project.tasks.filter { f.matches($0, now: now, calendar: calendar) }.map(\.title))
        }
        #expect(titles { _ in } == ["Build API", "Write docs", "Fix login", "Plan"])
        #expect(titles { $0.text = "api" } == ["Build API", "Write docs"], "title or notes")
        #expect(titles { $0.priorities = [2] } == ["Build API"])
        #expect(titles { $0.criticalOnly = true } == ["Write docs"])
        #expect(titles { $0.blockedOnly = true } == ["Build API"])
        #expect(titles { $0.resourceIDs = [ravi.id] } == ["Fix login"])
        #expect(titles { $0.unassigned = true } == ["Build API", "Write docs", "Plan"])
        #expect(titles { $0.resourceIDs = [ravi.id]; $0.unassigned = true } == ["Build API", "Write docs", "Fix login", "Plan"])
        #expect(titles { $0.labelIDs = [label.id] } == ["Plan"])
        #expect(titles { $0.due = .overdue } == ["Build API"])
        #expect(titles { $0.due = KanbanCardFilter.Due.none } == ["Write docs", "Fix login", "Plan"])
        #expect(titles { $0.hasJira = true } == ["Build API"])
        #expect(titles { $0.hasEstimate = false } == ["Write docs", "Fix login", "Plan"])
        #expect(titles { $0.text = "api"; $0.criticalOnly = true } == ["Write docs"], "conditions combine")
        var f = KanbanCardFilter()
        #expect(!f.isActive)
        f.blockedOnly = true
        #expect(f.isActive)
    }

    @Test("Sorts order a cell's cards; manual keeps the stored order")
    func sorting() throws {
        let (s, _, _, cards) = try board()
        try s.edit(cards["Plan"]!, [.priority: .int(2)])
        try s.edit(cards["Fix login"]!, [.isCritical: .bool(true)])
        try s.edit(cards["Write docs"]!, [.dueDate: .date(Date(timeIntervalSinceReferenceDate: 1))])
        let all = Array(cards.values)
        var state = KanbanBoardState()
        #expect(state.sorted(all).map(\.title) == ["Build API", "Write docs", "Fix login", "Plan"])
        state.sort = .priority
        #expect(state.sorted(all).map(\.title).prefix(2) == ["Fix login", "Plan"], "Critical first, then High")
        state.sort = .dueDate
        #expect(state.sorted(all).first?.title == "Write docs")
        state.sort = .title
        #expect(state.sorted(all).map(\.title) == ["Build API", "Fix login", "Plan", "Write docs"])
    }
}
