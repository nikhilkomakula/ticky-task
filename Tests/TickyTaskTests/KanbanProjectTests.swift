import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Board-level operations (design 01 §5, §7): templates, duplicating structure, editing a
/// board's settings (undoable), archive, order, delete, and remembered row collapse state.
@MainActor
@Suite("Kanban projects", .serialized)
struct KanbanProjectTests {
    private func service(_ context: ModelContext = ModelContext(ModelContainerProvider.makeInMemoryContainer())) -> (KanbanService, KanbanHistory) {
        let history = KanbanHistory()
        return (KanbanService(context, history: history), history)
    }

    private func defaults() throws -> UserDefaults {
        let name = "KanbanTemplates-\(UUID())"
        let d = try #require(UserDefaults(suiteName: name))
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - Templates

    @Test("Built-in templates make the documented columns; an invalid template is refused")
    func templates() throws {
        let (s, _) = service()
        #expect(try s.createProject(name: "A", key: "A").orderedColumns.map(\.name) == ["To Do", "In Progress", "Done"])
        #expect(try s.createProject(name: "B", key: "B", template: .software).orderedColumns.map(\.kind)
                == [.backlog, .active, .active, .active, .done])
        let bad = KanbanTemplate(id: UUID(), name: "Bad", columns: [.init(name: "Only", kind: .active)], labels: [])
        #expect(throws: KanbanServiceError.self) { try s.createProject(name: "C", key: "C", template: bad) }
    }

    @Test("A board's structure can be duplicated, or saved as a template that makes the same board")
    func duplicateAndSaveTemplate() throws {
        let (s, _) = service()
        let source = try s.createProject(name: "Platform", key: "PLAT", template: .software)
        let review = try #require(source.orderedColumns.first { $0.name == "In Review" })
        try s.editColumn(review, colorHex: .some("#FF9500"), wipLimit: .some(3))
        _ = try s.createTask(in: source, title: "A card")
        _ = try s.addMembership(try s.createPerson(name: "Ravi", initials: "RV"), to: source)

        let copy = try s.duplicateStructure(of: source, name: "Platform 2", key: "PLT2")
        func shape(_ p: KanbanProject) -> [String] { p.orderedColumns.map { "\($0.name)|\($0.kindRaw)|\($0.colorHex ?? "")|\($0.wipLimit ?? -1)" } }
        #expect(shape(copy) == shape(source))
        #expect(copy.labels.map(\.name).sorted() == source.labels.map(\.name).sorted())
        #expect(copy.tasks.isEmpty && copy.resources.isEmpty, "no cards or people")

        let d = try defaults()
        let template = try s.saveAsTemplate(source, name: "Our flow", defaults: d)
        #expect(KanbanTemplateStore.all(d).map(\.name) == ["Default", "Software", "Our flow"])
        let fromTemplate = try s.createProject(name: "New", key: "NEW", template: try #require(KanbanTemplateStore.saved(d).first))
        #expect(shape(fromTemplate) == shape(source))
        try KanbanTemplateStore.delete(template.id, d)
        #expect(KanbanTemplateStore.saved(d).isEmpty)
        #expect(throws: KanbanServiceError.self) { try KanbanTemplateStore.save(.standard, d) }
    }

    @Test("User templates travel with the backed-up settings")
    func templatesInSettingsBackup() throws {
        let (s, _) = service()
        let source = try s.createProject(name: "Platform", key: "PLAT")
        let from = try defaults(), to = try defaults()
        _ = try s.saveAsTemplate(source, name: "Ours", defaults: from)
        AppSettingsDTO.capture(from: from).apply(to: to)
        #expect(KanbanTemplateStore.saved(to).map(\.name) == ["Ours"])
    }

    // MARK: - Editing a board

    @Test("Board edits are recorded, undoable, and conflict-checked")
    func editProject() throws {
        let (s, history) = service()
        let project = try s.createProject(name: "Platform", key: "PLAT")
        history.clear()
        try s.editProject(project, [.name: .string("Platform Core"), .loadMeasureRaw: .string("hours"),
                                    .workWeekDays: .ints([2, 3, 4]), .openTaskTarget: .double(4)])
        #expect(project.name == "Platform Core" && project.loadMeasure == .hours && project.workWeekDays == [2, 3, 4])
        let first = try #require(project.activities.max { $0.seq < $1.seq })
        try s.editProject(project, [.name: .string("Core")])
        #expect(throws: KanbanServiceError.self, "the name changed again since") { try s.revert(first) }
        try s.undo(in: project)
        try s.undo(in: project)
        #expect(project.name == "Platform" && project.loadMeasure == .taskCount && project.workWeekDays == [2, 3, 4, 5, 6])
        #expect(throws: KanbanServiceError.self) { try s.editProject(project, [.workWeekDays: .ints([0, 8])]) }
    }

    @Test("An edit with a value of the wrong kind is refused before anything changes")
    func editProjectRejectsWrongKinds() throws {
        let (s, history) = service()
        let project = try s.createProject(name: "Platform", key: "PLAT")
        history.clear()
        let entries = project.activities.count
        #expect(throws: KanbanServiceError.self) { try s.editProject(project, [.name: .string("Core"), .hoursPerDay: .int(6)]) }
        #expect(throws: KanbanServiceError.self) { try s.editProject(project, [.loadMeasureRaw: .string("points")]) }
        #expect(throws: KanbanServiceError.self) { try s.editProject(project, [.wipPolicyRaw: .string("never")]) }
        #expect(project.name == "Platform" && project.hoursPerDay == 8 && project.loadMeasure == .taskCount)
        #expect(project.activities.count == entries && !history.canUndo(project.id))
    }

    @Test("A board can be archived and restored, and ⌘Z undoes the archive")
    func archiveProject() throws {
        let (s, history) = service()
        let project = try s.createProject(name: "Platform", key: "PLAT")
        history.clear()
        try s.setProjectArchived(project, true)
        #expect(project.archivedAt != nil)
        try s.undo(in: project)
        #expect(project.archivedAt == nil)
    }

    @Test("Boards keep their sidebar order")
    func reorderProjects() throws {
        let (s, _) = service()
        let a = try s.createProject(name: "A", key: "A"), b = try s.createProject(name: "B", key: "B"), c = try s.createProject(name: "C", key: "C")
        try s.reorderProjects([c, a, b])
        #expect([c, a, b].map(\.sortIndex) == [0, 1, 2])
    }

    private func diskBoard() throws -> (KanbanService, URL, KanbanProject, UUID) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KanbanProject-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("TickyTask.store")
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: url))
        context.autosaveEnabled = false
        DiscardedContexts.keep(context)
        let (s, _) = service(context)
        let project = try s.createProject(name: "Platform", key: "PLAT")
        let row = try s.addMembership(try s.createPerson(name: "Ravi", initials: "RV"), to: project)
        let card = try s.createTask(in: project, title: "Card", row: .resource(row.id))
        _ = try s.addSubtask(to: card, title: "Step")
        let keep = try s.createProject(name: "Other", key: "OTH")
        return (s, url, project, keep.id)
    }

    @Test("Deleting a board removes it and everything on it, but not the people")
    func deleteProject() throws {
        let (s, url, project, keep) = try diskBoard()
        try s.deleteProject(project)
        let after = ModelContext(try ModelContainerProvider.makeContainer(at: url))
        #expect(try after.fetch(FetchDescriptor<KanbanProject>()).map(\.id) == [keep])
        #expect(try after.fetchCount(FetchDescriptor<KanbanTask>()) == 0 && after.fetchCount(FetchDescriptor<KanbanSubtask>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<KanbanResource>()) == 0 && after.fetchCount(FetchDescriptor<KanbanActivity>()) == 1)
        #expect(try after.fetch(FetchDescriptor<KanbanPerson>()).map(\.name) == ["Ravi"])
    }

    @Test("A failed board delete fails closed with the disk unchanged")
    func deleteProjectFailure() throws {
        let (s, url, project, _) = try diskBoard()
        let before = try KanbanBackupDTO.snapshot(context: ModelContext(try ModelContainerProvider.makeContainer(at: url))).deterministicallySorted()
        var restarted = false
        PersistenceRecovery.testHook = { restarted = true }
        defer { PersistenceRecovery.testHook = nil; PersistenceFaults.armed = [] }
        PersistenceFaults.armed = [.transaction]
        #expect(throws: (any Error).self) { try s.deleteProject(project) }
        #expect(restarted)
        let after = try KanbanBackupDTO.snapshot(context: ModelContext(try ModelContainerProvider.makeContainer(at: url))).deterministicallySorted()
        #expect(after == before)
    }

    // MARK: - View state

    @Test("Row collapse state is remembered per board, singly or all at once")
    func collapseState() throws {
        let (s, _) = service()
        let project = try s.createProject(name: "Platform", key: "PLAT")
        let row = try s.addMembership(try s.createPerson(name: "Ravi", initials: "RV"), to: project)
        try s.setRowCollapsed(project, .resource(row.id), true)
        #expect(project.collapsedRowKeys == [row.id.uuidString])
        try s.setAllRowsCollapsed(project, true)
        #expect(Set(project.collapsedRowKeys) == ["unassigned", row.id.uuidString])
        try s.setRowCollapsed(project, .unassigned, false)
        #expect(project.collapsedRowKeys == [row.id.uuidString])
        try s.setAllRowsCollapsed(project, false)
        #expect(project.collapsedRowKeys.isEmpty)
        try s.setBoardState(project, Data([1, 2]))
        #expect(project.boardState == Data([1, 2]))
    }
}
