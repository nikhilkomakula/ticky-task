import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// The module policy (design 01 §3), membership and person edits (01 §2.2) and the
/// Attention list's rules (01 §5).
@MainActor
@Suite("Kanban module", .serialized)
struct KanbanModuleTests {
    // MARK: - Module policy

    @Test("Both modules show by default; hiding both shows the planner")
    func policyDefaults() throws {
        #expect(ModulePolicy().visible == [.planner, .kanban] && ModulePolicy().showsSwitcher)
        #expect(ModulePolicy(showPlanner: false, showKanban: false).visible == [.planner])
        let kanbanOnly = ModulePolicy(showPlanner: false, showKanban: true)
        #expect(kanbanOnly.visible == [.kanban] && !kanbanOnly.showsSwitcher)
        #expect(kanbanOnly.resolve(.planner) == .kanban && ModulePolicy(showKanban: false).resolve(.kanban) == .planner)
    }

    @Test("The last visible module's toggle can't be turned off")
    func policyLastToggle() {
        #expect(ModulePolicy().canHide(.planner) && ModulePolicy().canHide(.kanban))
        #expect(!ModulePolicy(showKanban: false).canHide(.planner))
        #expect(!ModulePolicy(showPlanner: false).canHide(.kanban))
    }

    @Test("The policy reads stored settings, and text ones")
    func policyFromDefaults() throws {
        let name = "ModulePolicy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        #expect(ModulePolicy(defaults) == ModulePolicy())
        defaults.set("NO", forKey: ModulePolicy.showKanbanKey)
        #expect(ModulePolicy(defaults).visible == [.planner])
    }

    @Test("Module visibility travels with the settings backup")
    func policyBackupRoundTrip() throws {
        func defaults() throws -> UserDefaults {
            let name = "ModuleBackup-\(UUID())"
            let d = try #require(UserDefaults(suiteName: name))
            d.removePersistentDomain(forName: name)
            return d
        }
        let from = try defaults(), to = try defaults()
        from.set(false, forKey: ModulePolicy.showKanbanKey)
        AppSettingsDTO.capture(from: from).apply(to: to)
        #expect(ModulePolicy(to).visible == [.planner])
    }

    @Test("A planner reveal (search) switches to the planner")
    func plannerRevealSwitchesModule() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let task = try DataService(context).addTask(title: "Found", location: .day(WeekMath.dayKey(for: Date())))
        let app = AppState()
        app.module = .kanban
        app.reveal(task)
        #expect(app.module == .planner && app.highlightedTaskID == task.id)
    }

    // MARK: - Memberships and people

    private func board() throws -> (KanbanService, KanbanHistory, KanbanProject, KanbanResource) {
        let history = KanbanHistory()
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()), history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let mia = try service.addMembership(try service.createPerson(name: "Mia", initials: "MI", employment: .contractor), to: project)
        history.clear()
        return (service, history, project, mia)
    }

    @Test("A membership edit is recorded, undoable and conflict-checked")
    func editMembership() throws {
        let (s, _, project, mia) = try board()
        let end = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try s.editMembership(mia, [.allocationPercent: .int(50), .assignmentRaw: .string("partTime"), .endDate: .date(end),
                                   .capacityHoursPerWeekOverride: .double(20), .role: .string("Data engineer")])
        #expect(mia.allocationPercent == 50 && mia.assignment == .partTime && mia.endDate == end)
        #expect(mia.capacityHoursPerWeekOverride == 20 && mia.role == "Data engineer")
        let entry = try #require(project.activities.max { $0.seq < $1.seq })
        try s.editMembership(mia, [.allocationPercent: .int(60)])
        #expect(throws: KanbanServiceError.self, "the allocation changed again since") { try s.revert(entry) }
        try s.undo(in: project)
        try s.undo(in: project)
        #expect(mia.allocationPercent == 100 && mia.assignment == .fullTime && mia.endDate == nil)
        #expect(mia.capacityHoursPerWeekOverride == nil && mia.role == nil)
    }

    @Test("Reverting a date edit that would end a membership before it starts is refused")
    func membershipDateRevert() throws {
        let (s, _, project, mia) = try board()
        let day = { (n: Double) in Date(timeIntervalSinceReferenceDate: 800_000_000 + n * 86_400) }
        try s.editMembership(mia, [.startDate: .date(day(20)), .endDate: .date(day(30))])
        try s.editMembership(mia, [.startDate: .date(day(10))])
        let startEdit = try #require(project.activities.max { $0.seq < $1.seq })
        try s.editMembership(mia, [.endDate: .date(day(15))])
        #expect(throws: KanbanServiceError.self, "start back to the 20th would be after the 15th") { try s.revert(startEdit) }
        #expect(mia.startDate == day(10) && mia.endDate == day(15))
        // Archived memberships too: undoing the archive would bring the bad dates back.
        let person = try #require(mia.person)
        let group = try #require(try s.archivePerson(person))
        #expect(throws: KanbanServiceError.self) { try s.revert(startEdit) }
        try s.undoPersonArchive(person, group: group)
        #expect(mia.archivedAt == nil && mia.startDate == day(10) && mia.endDate == day(15))
    }

    @Test("Invalid membership values are refused before anything changes")
    func editMembershipValidation() throws {
        let (s, history, project, mia) = try board()
        let entries = project.activities.count
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for values: [KanbanService.MembershipField: KanbanValue?] in [
            [.allocationPercent: .int(0)], [.allocationPercent: .int(101)], [.allocationPercent: .double(50)],
            [.assignmentRaw: .string("sometimes")], [.capacityHoursPerWeekOverride: .double(-1)],
            [.openTaskTargetOverride: .double(.infinity)], [.role: .int(1)],
            [.startDate: .date(start), .endDate: .date(start.addingTimeInterval(-86_400)), .allocationPercent: .int(50)],
        ] {
            #expect(throws: KanbanServiceError.self, "\(values)") { try s.editMembership(mia, values) }
        }
        #expect(mia.allocationPercent == 100 && mia.startDate == nil && project.activities.count == entries && !history.canUndo(project.id))
    }

    @Test("Person edits apply on every board and stay out of the Change Log")
    func editPerson() throws {
        let (s, history, project, mia) = try board()
        let person = try #require(mia.person)
        let other = try s.createProject(name: "Data", key: "DATA")
        let there = try s.addMembership(person, to: other, allocationPercent: 50)
        history.clear()
        let entries = project.activities.count
        try s.editPerson(person, name: "Mia Chen", initials: "MC", employment: .fte)
        #expect(mia.displayName == "Mia Chen" && there.displayName == "Mia Chen" && person.employment == .fte)
        #expect(project.activities.count == entries && !history.canUndo(project.id))
        #expect(throws: KanbanServiceError.self) { try s.editPerson(person, name: "  ") }
    }

    // MARK: - Attention

    @Test("Attention lists overdue, due-soon, blocked, Critical and unassigned urgent open cards")
    func attentionItems() throws {
        let (s, _, project, mia) = try board()
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        func card(_ title: String, _ values: [KanbanService.TaskField: KanbanValue?] = [:], row: KanbanRowKey = .resource(mia.id),
                  column: KanbanColumn? = nil) throws -> KanbanTask {
            let task = try s.createTask(in: project, title: title, column: column ?? project.orderedColumns[1], row: row)
            if !values.isEmpty { try s.edit(task, values) }
            return task
        }
        _ = try card("Overdue", [.dueDate: .date(calendar.date(byAdding: .day, value: -1, to: today)!)])
        _ = try card("Soon", [.dueDate: .date(calendar.date(byAdding: .day, value: 3, to: today)!)])
        _ = try card("Later", [.dueDate: .date(calendar.date(byAdding: .day, value: 4, to: today)!)])
        _ = try card("Blocked", [.isBlocked: .bool(true)])
        _ = try card("Urgent loose", [.priority: .int(TaskPriority.high.rawValue)], row: .unassigned)
        _ = try card("High but owned", [.priority: .int(TaskPriority.high.rawValue)])
        _ = try card("Done overdue", [.dueDate: .date(calendar.date(byAdding: .day, value: -5, to: today)!)], column: project.orderedColumns[2])
        let archived = try card("Archived blocked", [.isBlocked: .bool(true)])
        try s.archiveTask(archived)
        let items = KanbanAttentionView.items(project, now: now, calendar: calendar)
        #expect(Set(items.map(\.task.title)) == ["Overdue", "Soon", "Blocked", "Urgent loose"])
        #expect(items.first { $0.task.title == "Urgent loose" }?.reasons == ["Unassigned"])
        #expect(items.first { $0.task.title == "Overdue" }?.reasons == ["Overdue"])
    }

    @Test("Over capacity: red, or no capacity while holding work")
    func overCapacity() {
        #expect(KanbanMetrics.utilisation(load: 6, target: 5).isOverCapacity)
        #expect(!KanbanMetrics.utilisation(load: 5, target: 5).isOverCapacity)
        #expect(KanbanMetrics.utilisation(load: 1, target: 0).isOverCapacity)
        #expect(!KanbanMetrics.utilisation(load: 0, target: 0).isOverCapacity)
    }

    @Test("Metric snapshots are reused until the store or the day changes")
    func metricsCache() throws {
        let (s, _, project, mia) = try board()
        let cache = KanbanMetricsCache()
        let calendar = Calendar.current
        let key = KanbanMetricsCache.Key(generation: 1, clock: "20261017|UTC", weekStartsMonday: true)
        #expect(cache.snapshot(of: project, key: key, calendar: calendar).cards.isEmpty)
        _ = try s.createTask(in: project, title: "New", row: .resource(mia.id))
        #expect(cache.snapshot(of: project, key: key, calendar: calendar).cards.isEmpty, "same key: cached")
        var next = key
        next.generation = 2
        #expect(cache.snapshot(of: project, key: next, calendar: calendar).cards.count == 1, "a save invalidates it")
        next.clock = "20261017|Europe/London"
        #expect(cache.people([project], key: next, calendar: calendar).count == 1)
        let other = try s.createProject(name: "Data", key: "DATA")
        _ = try s.addMembership(try s.createPerson(name: "Ravi", initials: "RV"), to: other)
        #expect(cache.people([project, other], key: next, calendar: calendar).count == 2, "a different set of boards isn't the cached one")
    }

    @Test("A reveal opens the board on the card and clears the highlight")
    func revealKanban() async throws {
        let app = AppState()
        let project = UUID(), card = UUID()
        app.revealKanban(taskID: card, projectID: project)
        #expect(app.module == .kanban && app.kanban.selection == .project(project) && app.highlightedKanbanTaskID == card)
    }

    @Test("Display names stay apart from each other and from reserved categories")
    func uniqueNames() {
        let a = UUID(), b = UUID(), c = UUID()
        let names = KanbanUI.uniqueNames([(a, "No label"), (b, "Bug"), (c, "Bug")], reserved: ["No label"])
        #expect(names[a] == "No label (2)" && names[b] == "Bug" && names[c] == "Bug (2)")
        #expect(KanbanUI.uniqueNames([(a, "Unassigned")])[a] == "Unassigned (2)")
    }
}
