import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// A column's Appearance: colour and icon, automatic (stage and name) unless chosen.
@MainActor
@Suite("Kanban column appearance", .serialized)
struct KanbanColumnAppearanceTests {
    private func board() throws -> (KanbanService, KanbanHistory, KanbanProject, ModelContext) {
        let history = KanbanHistory()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: history)
        let project = try service.createProject(name: "Platform", key: "PLAT")
        history.clear()
        return (service, history, project, context)
    }

    @Test("The automatic icon follows a status name, blocked and waiting first, and the stage otherwise")
    func automaticIcon() {
        #expect(KanbanColumnStyle.nameSymbol("In Review") == "eye")
        #expect(KanbanColumnStyle.nameSymbol("QA") == "checkmark.seal")
        #expect(KanbanColumnStyle.nameSymbol("Blocked") == "hand.raised")
        #expect(KanbanColumnStyle.nameSymbol("On hold") == "hand.raised")
        #expect(KanbanColumnStyle.nameSymbol("Waiting for review") == "hourglass", "waiting wins")
        #expect(KanbanColumnStyle.nameSymbol("Blocked, waiting") == "hand.raised", "blocked wins")
        #expect(KanbanColumnStyle.nameSymbol("Ready for review") == nil, "two answers: none")
        #expect(KanbanColumnStyle.nameSymbol("Preview") == nil, "whole words only")
        #expect(KanbanColumnStyle.nameSymbol("To Do") == nil)
        let todo = KanbanColumnStyle(kind: .backlog, customColorHex: nil, name: "To Do")
        #expect(todo.symbol == "circle.dashed" && todo.kindName == "Not started")
        let review = KanbanColumnStyle(kind: .active, customColorHex: nil, name: "In Review")
        #expect(review.symbol == "eye" && review.kindName == "In progress", "the stage stays what's spoken")
    }

    @Test("A chosen icon wins; one this Mac doesn't have shows the automatic icon and stays stored")
    func chosenIcon() {
        #expect(KanbanColumnStyle(kind: .active, customColorHex: nil, customSymbol: "bolt", name: "In Review").symbol == "bolt")
        let missing = KanbanColumnStyle(kind: .done, customColorHex: nil, customSymbol: "no.such.symbol.anywhere", name: "Done")
        #expect(missing.symbol == "checkmark.circle.fill" && missing.customSymbol == "no.such.symbol.anywhere")
    }

    @Test("Every palette and stage colour reaches 3:1 for icons and rules in light and dark, without changing what's stored")
    func contrast() throws {
        for hex in TaskColor.allCases.map(\.hex) + KanbanColumnKind.allCases.map(KanbanColumnStyle.stageHex) {
            let base = try #require(KanbanContrast.rgb(hex))
            for dark in [false, true] {
                let drawn = KanbanContrast.adjusted(base, dark: dark)
                let ratio = KanbanContrast.contrast(drawn, KanbanContrast.surface(for: drawn, dark: dark))
                #expect(ratio >= KanbanContrast.minimum, "\(hex) in \(dark ? "dark" : "light"): \(ratio)")
            }
        }
        #expect(KanbanColumnStyle(kind: .active, customColorHex: TaskColor.yellow.hex).baseHex == TaskColor.yellow.hex)
        // The letter and check on each swatch read in both appearances.
        for hex in TaskColor.allCases.map(\.hex) + KanbanColumnKind.allCases.map(KanbanColumnStyle.stageHex) {
            let base = try #require(KanbanContrast.rgb(hex))
            for dark in [false, true] {
                let fill = KanbanContrast.adjusted(base, dark: dark)
                let best = max(KanbanContrast.contrast(fill, (1, 1, 1)), KanbanContrast.contrast(fill, (0, 0, 0)))
                #expect(best >= 4.5, "\(hex) badge in \(dark ? "dark" : "light"): \(best)")
            }
        }
        // The card's priority colours (the planner's green, orange, red) reach 3:1 too.
        for hex in ["#34C759", "#FF9500", "#FF3B30"] {
            let base = try #require(KanbanContrast.rgb(hex))
            for dark in [false, true] {
                let drawn = KanbanContrast.adjusted(base, dark: dark)
                #expect(KanbanContrast.contrast(drawn, KanbanContrast.surface(for: drawn, dark: dark)) >= 3)
            }
        }
    }

    @Test("Choosing a colour or icon is one entry with a clear name; picking it again writes nothing; undo and Reset work")
    func edits() throws {
        let (s, history, project, context) = try board()
        let column = project.orderedColumns[1]
        let id = project.id
        let entries = { try context.fetch(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id })) }
        let before = try entries().count
        try s.editColumn(column, symbolName: .some("bolt"))
        #expect(column.symbolName == "bolt")
        #expect(try entries().contains { $0.summary == "Changed \(column.name) icon" })
        try s.editColumn(column, symbolName: .some("bolt"))
        #expect(try entries().count == before + 1, "the same icon again: no entry")
        try s.editColumn(column, colorHex: .some(TaskColor.blue.hex))
        #expect(try entries().contains { $0.summary == "Changed \(column.name) colour" })
        try s.editColumn(column, colorHex: .some(nil), symbolName: .some(nil))
        #expect(column.colorHex == nil && column.symbolName == nil)
        #expect(try entries().contains { $0.summary == "Reset \(column.name) appearance" })
        try s.undo(in: project)
        #expect(column.colorHex == TaskColor.blue.hex && column.symbolName == "bolt", "undo brings both back")
        #expect(history.canUndo(project.id))
    }

    @Test("The icon travels in backups, templates and duplicated boards; older files without it read as automatic")
    func carried() throws {
        let (s, _, project, _) = try board()
        let column = project.orderedColumns[1]
        try s.editColumn(column, symbolName: .some("eye"))
        let dto = KanbanColumnDTO(column)
        let restored = try JSONDecoder().decode(KanbanColumnDTO.self, from: JSONEncoder().encode(dto))
        #expect(restored.symbolName == "eye")
        let older = #"{"id":"\#(UUID().uuidString)","name":"Doing","sortIndex":1,"kindRaw":"active"}"#
        #expect(try JSONDecoder().decode(KanbanColumnDTO.self, from: Data(older.utf8)).symbolName == nil)
        let copy = try s.duplicateStructure(of: project, name: "Copy", key: "COPY")
        #expect(copy.orderedColumns[1].symbolName == "eye")
        let template = try JSONDecoder().decode(KanbanTemplate.Column.self, from: Data(#"{"name":"Doing","kind":"active"}"#.utf8))
        #expect(template.symbolName == nil, "older saved templates still read")
    }
}
