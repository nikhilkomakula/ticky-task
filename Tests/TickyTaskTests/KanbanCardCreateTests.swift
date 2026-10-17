import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Creating a card from the full editor (UI polish A1), board label edits (A2) and the
/// new-board default labels: one save each, nothing written on a refusal.
@MainActor
@Suite("Kanban card create and labels", .serialized)
struct KanbanCardCreateTests {
    private func board() throws -> (KanbanService, KanbanHistory, KanbanProject, ModelContext) {
        let history = KanbanHistory()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        history.clear()
        return (service, history, project, context)
    }

    private func entries(_ project: KanbanProject, _ context: ModelContext) throws -> [KanbanActivity] {
        let id = project.id
        return try context.fetch(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id }))
    }

    @Test("Every field of a new card is saved with one change-log entry, and undo removes it all")
    func fullCreate() throws {
        let (s, history, project, context) = try board()
        let ravi = try s.addMembership(try s.createPerson(name: "Ravi", initials: "RV"), to: project)
        let prerequisite = try s.createTask(in: project, title: "Design")
        let label = try #require(project.labels.min { $0.sortIndex < $1.sortIndex })
        let before = try entries(project, context).count
        var draft = KanbanCardDraft()
        draft.title = "  Build API  "
        draft.notes = "Use the gateway"
        draft.priority = 2
        draft.isCritical = true
        draft.columnID = project.orderedColumns[1].id
        draft.row = .resource(ravi.id)
        draft.dueDate = Calendar.current.startOfDay(for: Date())
        draft.estimateHours = 6
        draft.jiraURL = "https://jira.example.com/browse/PLAT-9"
        draft.labelIDs = [label.id]
        draft.dependencyIDs = [prerequisite.id]
        draft.steps = [.init(title: "Endpoints"), .init(title: "Docs", isDone: true)]
        let card = try s.createCard(draft, in: project)
        #expect(card.title == "Build API" && card.priority == 2 && card.isCritical && card.estimateHours == 6 && card.jiraKey == "PLAT-9")
        #expect(card.column?.id == project.orderedColumns[1].id && card.resource?.id == ravi.id)
        #expect(card.labels.map(\.id) == [label.id] && card.dependsOn.map(\.id) == [prerequisite.id])
        #expect(card.subtasks.sorted { $0.sortIndex < $1.sortIndex }.map(\.title) == ["Endpoints", "Docs"])
        #expect(try entries(project, context).count == before + 1, "one entry for the whole card")
        #expect(history.canUndo(project.id))
        let id = card.id
        try s.undo(in: project)
        #expect(try context.fetch(FetchDescriptor<KanbanTask>(predicate: #Predicate { $0.id == id })).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<KanbanSubtask>()) == 0, "its steps go too")
    }

    @Test("A refused draft writes nothing")
    func refusedDraft() throws {
        let (s, history, project, context) = try board()
        let before = (try entries(project, context).count, try context.fetchCount(FetchDescriptor<KanbanTask>()))
        var blank = KanbanCardDraft(); blank.title = "   "
        var badStep = KanbanCardDraft(); badStep.title = "Card"; badStep.steps = [.init(title: " ")]
        var badJira = KanbanCardDraft(); badJira.title = "Card"; badJira.jiraURL = "PLAT-1"
        var foreignLabel = KanbanCardDraft(); foreignLabel.title = "Card"; foreignLabel.labelIDs = [UUID()]
        for draft in [blank, badStep, badJira, foreignLabel] {
            #expect(throws: (any Error).self) { try s.createCard(draft, in: project) }
        }
        #expect(try entries(project, context).count == before.0 && context.fetchCount(FetchDescriptor<KanbanTask>()) == before.1)
        #expect(!history.canUndo(project.id))
    }

    @Test("Label edits apply together: add, rename, recolour, reorder, delete (removed from cards, pruned from the filter)")
    func labelChanges() throws {
        let (s, _, project, context) = try board()
        let labels = project.labels.sorted { $0.sortIndex < $1.sortIndex }
        let (first, second) = (labels[0], labels[1])
        let card = try s.createTask(in: project, title: "Card")
        try s.setLabels(card, [first, second])
        var state = KanbanBoardState.decode(project.boardState)
        state.filter.labelIDs = [second.id]
        project.boardState = state.encoded()
        try context.save()
        var changes = KanbanLabelChanges()
        changes.adds = [.init(name: "Security", colorHex: "#FF0000", symbolName: "flag.fill")]
        changes.edits = [.init(id: first.id, name: "Feature work", colorHex: "#00FF00", symbolName: "sparkles")]
        changes.deleteIDs = [second.id]
        changes.orderIDs = labels.dropFirst(2).map(\.id) + [first.id]
        try s.applyLabelChanges(changes, to: project)
        let after = project.labels.sorted { $0.sortIndex < $1.sortIndex }
        #expect(!after.contains { $0.id == second.id } && after.contains { $0.name == "Security" && $0.symbolName == "flag.fill" })
        #expect(first.name == "Feature work" && first.colorHex == "#00FF00" && first.symbolName == "sparkles")
        #expect(card.labels.map(\.id) == [first.id], "the deleted label is gone from the card")
        #expect(KanbanBoardState.decode(project.boardState).filter.labelIDs.isEmpty, "and from the saved filter")
        #expect(Set(after.map(\.sortIndex)).count == after.count)
    }

    @Test("Label edits that clash or point elsewhere are refused; nothing at all changes")
    func labelRefusals() throws {
        let (s, _, project, context) = try board()
        let labels = project.labels.sorted { $0.sortIndex < $1.sortIndex }
        let before = try entries(project, context).count
        var duplicate = KanbanLabelChanges(); duplicate.adds = [.init(name: " \(labels[0].name.uppercased()) ", colorHex: "#000000")]
        var blank = KanbanLabelChanges(); blank.edits = [.init(id: labels[0].id, name: "  ")]
        var foreign = KanbanLabelChanges(); foreign.deleteIDs = [UUID()]
        for changes in [duplicate, blank, foreign] {
            #expect(throws: (any Error).self) { try s.applyLabelChanges(changes, to: project) }
        }
        #expect(project.labels.count == labels.count && labels[0].name == project.labels.first { $0.id == labels[0].id }?.name)
        try s.applyLabelChanges(KanbanLabelChanges(), to: project)
        #expect(try entries(project, context).count == before, "no change, no entry")
    }

    @Test("Built-in templates take the Settings default labels; saved templates keep theirs")
    func defaultLabels() throws {
        let suite = "labels-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let s = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()))
        let factory = try s.createProject(name: "A", key: "A", defaults: KanbanBoardDefaults(store))
        #expect(factory.labels.count == KanbanTemplate.defaultLabels.count, "missing preference: factory labels")
        try KanbanBoardDefaults.saveLabels([.init(name: "Incident", colorHex: "#FF3B30")], to: store)
        let custom = try s.createProject(name: "B", key: "B", defaults: KanbanBoardDefaults(store))
        #expect(custom.labels.map(\.name) == ["Incident"])
        try KanbanBoardDefaults.saveLabels([], to: store)
        #expect(try s.createProject(name: "C", key: "C", defaults: KanbanBoardDefaults(store)).labels.isEmpty, "empty: none")
        store.set("not json", forKey: KanbanBoardDefaults.defaultLabelsKey)
        #expect(try s.createProject(name: "D", key: "D", defaults: KanbanBoardDefaults(store)).labels.count == KanbanTemplate.defaultLabels.count)
        #expect(store.string(forKey: KanbanBoardDefaults.defaultLabelsKey) == "not json", "reading doesn't overwrite")
    }
}
