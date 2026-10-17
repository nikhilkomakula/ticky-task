import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Resizable board columns: widths live in the board's view state, decode tolerantly and
/// never touch the change log.
@MainActor
@Suite("Kanban column widths", .serialized)
struct KanbanColumnWidthTests {
    private func decode(_ json: String) -> KanbanBoardState { KanbanBoardState.decode(Data(json.utf8)) }

    @Test("Older states have no widths and draw at the defaults")
    func olderStates() {
        let state = decode(#"{"view":"list","sort":"priority"}"#)
        #expect(state.view == .list && state.rowHeaderWidth == nil && state.columnWidths == nil)
        let widths = KanbanBoardWidths(state)
        #expect(widths.rowHeader == 230 && widths.column(UUID()) == 250)
    }

    @Test("Widths round-trip, and out-of-range or bad values are clamped or dropped without losing the rest")
    func tolerantDecode() throws {
        let column = UUID()
        var state = KanbanBoardState()
        state.setRowHeaderWidth(300)
        state.setColumnWidth(320, for: column, keeping: [column])
        let restored = KanbanBoardState.decode(state.encoded())
        #expect(restored == state && KanbanBoardWidths(restored).column(column) == 320)

        let clamped = decode(#"{"sort":"title","rowHeaderWidth":5000,"columnWidths":{"\#(column.uuidString)":10,"not-a-uuid":300}}"#)
        #expect(clamped.sort == .title, "other keys survive")
        #expect(clamped.rowHeaderWidth == 400 && clamped.columnWidths?[column.uuidString] == 180)
        #expect(clamped.columnWidths?.count == 1, "a key that isn't a column id is dropped")
        let aliases = decode(#"{"columnWidths":{"\#(column.uuidString)":300,"\#(column.uuidString.lowercased())":320}}"#)
        #expect(aliases.columnWidths == [column.uuidString: 320], "two spellings of one id become one width")
        #expect(KanbanBoardWidths(aliases).column(column) == 320)

        let wrongTypes = decode(#"{"sort":"title","rowHeaderWidth":"wide","columnWidths":[1,2]}"#)
        #expect(wrongTypes.sort == .title && wrongTypes.rowHeaderWidth == nil && wrongTypes.columnWidths == nil)
        #expect(decode(#"{"columnWidths":{}}"#).columnWidths == nil, "an empty map is no map")
    }

    @Test("Setting a width clamps it, resetting removes it, and widths of deleted columns are dropped")
    func setAndReset() {
        let (a, b, gone) = (UUID(), UUID(), UUID())
        var state = KanbanBoardState()
        state.setColumnWidth(300, for: gone, keeping: [gone, a, b])
        state.setColumnWidth(999, for: a, keeping: [a, b])
        #expect(state.columnWidths == [a.uuidString: 480], "clamped, and the deleted column's width is gone")
        state.setColumnWidth(nil, for: a, keeping: [a, b])
        #expect(state.columnWidths == nil)
        state.setRowHeaderWidth(10)
        #expect(state.rowHeaderWidth == 160)
        state.setRowHeaderWidth(nil)
        #expect(state.rowHeaderWidth == nil)
    }

    @Test("Saving a width writes no change-log entry and leaves undo alone")
    func noChangeLog() throws {
        let history = KanbanHistory()
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: history)
        let project = try service.createProject(name: "Widths", key: "WID")
        history.clear()
        let id = project.id
        let before = try context.fetchCount(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id }))
        var state = KanbanBoardState.decode(project.boardState)
        state.setColumnWidth(320, for: project.orderedColumns[0].id, keeping: project.orderedColumns.map(\.id))
        try service.setBoardState(project, state.encoded())
        let after = try context.fetchCount(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id }))
        #expect(after == before && !history.canUndo(project.id))
        #expect(KanbanBoardWidths(KanbanBoardState.decode(project.boardState)).column(project.orderedColumns[0].id) == 320)
    }
}
