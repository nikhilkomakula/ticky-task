import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// The menu-bar popover's Kanban mode (design 01 §7): the day's due cards, Overdue on
/// today, the calendar's markers and the quick-add board.
@MainActor
@Suite("Kanban popover", .serialized)
struct KanbanPopoverTests {
    typealias P = KanbanPopover

    private let calendar = Calendar(identifier: .gregorian)
    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d))! }
    private func key(_ d: Int) -> String { WeekMath.dayKey(for: day(d), calendar: calendar) }

    private func boards() throws -> (KanbanService, KanbanProject, KanbanProject) {
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()))
        return (service, try service.createProject(name: "Platform", key: "PLAT"), try service.createProject(name: "Data", key: "DATA"))
    }

    @Test("The day's due cards across active boards; Overdue only on today, open cards only")
    func agenda() throws {
        let (s, platform, data) = try boards()
        try s.createTask(in: platform, title: "API", dueDate: day(14))
        try s.createTask(in: data, title: "Pipeline", dueDate: day(14))
        try s.createTask(in: platform, title: "Late", dueDate: day(10))
        try s.createTask(in: platform, title: "Late but done", column: platform.orderedColumns.last, dueDate: day(9))
        let archived = try s.createTask(in: data, title: "Archived", dueDate: day(14))
        try s.archiveTask(archived)
        try s.createTask(in: data, title: "No date")
        let projects = [platform, data]
        let today = P.agenda(projects, dayKey: key(14), now: day(14).addingTimeInterval(3600), calendar: calendar)
        #expect(Set(today.due.map(\.title)) == ["API", "Pipeline"])
        #expect(today.overdue.map(\.title) == ["Late"], "done cards aren't overdue")
        let tomorrow = P.agenda(projects, dayKey: key(15), now: day(14), calendar: calendar)
        #expect(tomorrow.due.isEmpty && tomorrow.overdue.isEmpty, "Overdue shows on today only")
        let past = P.agenda(projects, dayKey: key(9), now: day(14), calendar: calendar)
        #expect(past.due.map(\.title) == ["Late but done"])
        data.archivedAt = day(13)
        #expect(P.agenda(projects, dayKey: key(14), now: day(14), calendar: calendar).due.map(\.title) == ["API"], "archived boards drop out")
    }

    @Test("Markers: days with a card due on a live card and board")
    func markers() throws {
        let (s, platform, data) = try boards()
        let api = try s.createTask(in: platform, title: "API", dueDate: day(14))
        try s.createTask(in: data, title: "Pipeline", dueDate: day(20))
        let gone = try s.createTask(in: platform, title: "Gone", dueDate: day(22))
        try s.archiveTask(gone)
        #expect(P.dueDayKeys(platform.tasks + data.tasks, calendar: calendar) == [key(14), key(20)])
        data.archivedAt = day(13)
        #expect(P.dueDayKeys([api] + data.tasks, calendar: calendar) == [key(14)])
    }

    @Test("Quick add: the chosen board, else the last opened, else the first active one")
    func quickAddTarget() throws {
        let (_, platform, data) = try boards()
        let projects = [platform, data]
        #expect(P.quickAddProject(projects, chosen: data.id.uuidString, lastOpened: platform.id.uuidString)?.id == data.id)
        #expect(P.quickAddProject(projects, chosen: "", lastOpened: data.id.uuidString)?.id == data.id)
        #expect(P.quickAddProject(projects, chosen: UUID().uuidString, lastOpened: nil)?.id == platform.id, "a deleted choice falls back")
        data.archivedAt = Date()
        #expect(P.quickAddProject(projects, chosen: data.id.uuidString, lastOpened: nil)?.id == platform.id, "archived boards aren't offered")
        platform.archivedAt = Date()
        #expect(P.quickAddProject(projects, chosen: nil, lastOpened: nil) == nil)
    }

    @Test("A quick-added card is in the backlog, Unassigned, due that day, in one change-log entry")
    func quickAddCard() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let card = try service.createTask(in: project, title: "Call vendor", dueDate: day(14))
        #expect(card.column?.kind == .backlog && card.resource == nil && card.dueDate == day(14))
        let id = project.id
        let entries = try context.fetch(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id }))
        let entry = try #require(entries.max { $0.seq < $1.seq })
        #expect(entries.filter { $0.taskIDs.contains(card.id) }.count == 1)
        #expect(entry.kindRaw == KanbanActivityKind.created.rawValue)
        #expect(try KanbanActivityPayload.decode(entry.payload).graph?.tasks.first?.dueDate == day(14), "the creation records its due date")
    }
}
