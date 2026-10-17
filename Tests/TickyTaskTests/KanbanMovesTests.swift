import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Every row of design 01 §4's drag-and-drop table, as pure plans over a snapshot.
/// Board: columns To Do (backlog) · Doing (active) · Done (done); rows Unassigned · Ravi · Mia.
@Suite("Kanban moves")
struct KanbanMovesTests {
    let todo = UUID(), doing = UUID(), done = UUID(), done2 = UUID()
    let ravi = UUID(), mia = UUID()
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let earlier = Date(timeIntervalSinceReferenceDate: 700_000_000)

    func board(_ cards: [CardSnapshot], wip: KanbanWIPPolicy = .warn, doingLimit: Int? = nil, secondDone: Bool = false) -> BoardSnapshot {
        var columns = [
            ColumnSnapshot(id: todo, name: "To Do", kind: .backlog, sortIndex: 0, wipLimit: nil),
            ColumnSnapshot(id: doing, name: "Doing", kind: .active, sortIndex: 1, wipLimit: doingLimit),
            ColumnSnapshot(id: done, name: "Done", kind: .done, sortIndex: 2, wipLimit: nil),
        ]
        if secondDone { columns.append(ColumnSnapshot(id: done2, name: "Shipped", kind: .done, sortIndex: 3, wipLimit: nil)) }
        let rows = [
            KanbanRowSnapshot(key: .unassigned, resourceID: nil, personID: nil, name: "Unassigned", sortIndex: -1, archived: false),
            KanbanRowSnapshot(key: .resource(ravi), resourceID: ravi, personID: UUID(), name: "Ravi", sortIndex: 0, archived: false),
            KanbanRowSnapshot(key: .resource(mia), resourceID: mia, personID: UUID(), name: "Mia", sortIndex: 1, archived: false),
        ]
        return BoardSnapshot(projectID: UUID(), wipPolicy: wip, columns: columns, rows: rows, cards: cards)
    }

    func card(_ column: UUID, _ row: KanbanRowKey, _ sort: Double,
              completedAt: Date? = nil, archived: Bool = false) -> CardSnapshot {
        CardSnapshot(id: UUID(), columnID: column, row: row, sortIndex: sort, completedAt: completedAt, archived: archived,
                     priority: 0, isCritical: false, dueDate: nil, startDate: nil, estimateHours: nil, isBlocked: false)
    }

    func after(_ plan: MovePlan, _ id: UUID) -> Placement? { plan.cardChanges.first { $0.id == id }?.to }

    // MARK: - Card → cell

    @Test("Card to another cell changes column and row, inserts before the indicator, and renumbers both cells")
    func cardToAnotherCell() {
        let a = card(todo, .unassigned, 0), b = card(todo, .unassigned, 1)
        let x = card(doing, .resource(ravi), 0), y = card(doing, .resource(ravi), 1)
        let plan = KanbanMoves.plan(.cards([a.id], to: .cell(columnID: doing, row: .resource(ravi), beforeCardID: y.id)),
                                    in: board([a, b, x, y]), now: now)
        #expect(after(plan, a.id) == Placement(columnID: doing, row: .resource(ravi), sortIndex: 1, completedAt: nil))
        #expect(after(plan, y.id)?.sortIndex == 2, "the card after the indicator shifts down")
        #expect(after(plan, b.id)?.sortIndex == 0, "the source cell closes its gap")
        #expect(after(plan, x.id) == nil, "unchanged cards aren't in the plan")
        #expect(plan.wip == .ok && !plan.isNoOp)
    }

    @Test("Card to the end of a cell (no indicator) is appended")
    func appendToCell() {
        let a = card(todo, .unassigned, 0), x = card(doing, .resource(mia), 0)
        let plan = KanbanMoves.plan(.cards([a.id], to: .cell(columnID: doing, row: .resource(mia), beforeCardID: nil)),
                                    in: board([a, x]), now: now)
        #expect(after(plan, a.id)?.sortIndex == 1)
    }

    @Test("Card within its own cell reorders")
    func sameCellReorder() {
        let a = card(doing, .resource(ravi), 0), b = card(doing, .resource(ravi), 1), c = card(doing, .resource(ravi), 2)
        let plan = KanbanMoves.plan(.cards([c.id], to: .cell(columnID: doing, row: .resource(ravi), beforeCardID: a.id)),
                                    in: board([a, b, c]), now: now)
        #expect(after(plan, c.id)?.sortIndex == 0 && after(plan, a.id)?.sortIndex == 1 && after(plan, b.id)?.sortIndex == 2)
    }

    @Test("Dropping a card back where it is changes nothing")
    func noOpInPlace() {
        let a = card(doing, .resource(ravi), 0), b = card(doing, .resource(ravi), 1)
        let plan = KanbanMoves.plan(.cards([a.id], to: .cell(columnID: doing, row: .resource(ravi), beforeCardID: b.id)),
                                    in: board([a, b]), now: now)
        #expect(plan.isNoOp && plan.cardChanges.isEmpty)
    }

    // MARK: - Headers

    @Test("Card to a column header changes only its column (row kept, appended)")
    func columnHeader() {
        let a = card(todo, .resource(ravi), 0), x = card(doing, .resource(ravi), 0)
        let plan = KanbanMoves.plan(.cards([a.id], to: .columnHeader(doing)), in: board([a, x]), now: now)
        #expect(after(plan, a.id) == Placement(columnID: doing, row: .resource(ravi), sortIndex: 1, completedAt: nil))
    }

    @Test("Card to a row header changes only its row (column kept, appended), expanded or collapsed")
    func rowHeader() {
        let a = card(doing, .unassigned, 0), x = card(doing, .resource(mia), 0)
        let plan = KanbanMoves.plan(.cards([a.id], to: .rowHeader(.resource(mia))), in: board([a, x]), now: now)
        #expect(after(plan, a.id) == Placement(columnID: doing, row: .resource(mia), sortIndex: 1, completedAt: nil))
    }

    @Test("Card to the Unassigned row (cell or header) clears its resource", arguments: [true, false])
    func toUnassigned(viaHeader: Bool) {
        let a = card(doing, .resource(ravi), 0)
        let target: MoveTarget = viaHeader ? .rowHeader(.unassigned) : .cell(columnID: doing, row: .unassigned, beforeCardID: nil)
        let plan = KanbanMoves.plan(.cards([a.id], to: target), in: board([a]), now: now)
        #expect(after(plan, a.id)?.row == .unassigned && after(plan, a.id)?.columnID == doing)
    }

    // MARK: - Completion

    @Test("Entering Done from an open column stamps completion; Done → Done keeps it; leaving clears it")
    func completionTransitions() {
        let open = card(doing, .resource(ravi), 0)
        let finished = card(done, .resource(ravi), 0, completedAt: earlier)
        let toDone = KanbanMoves.plan(.cards([open.id], to: .columnHeader(done)), in: board([open]), now: now)
        #expect(after(toDone, open.id)?.completedAt == now)
        let doneToDone = KanbanMoves.plan(.cards([finished.id], to: .columnHeader(done2)), in: board([finished], secondDone: true), now: now)
        #expect(after(doneToDone, finished.id)?.completedAt == earlier, "Done → Done keeps the original completion")
        let reopen = KanbanMoves.plan(.cards([finished.id], to: .columnHeader(doing)), in: board([finished]), now: now)
        #expect(after(reopen, finished.id)?.completedAt == nil)
    }

    // MARK: - Multi-selection

    @Test("A multi-selection moves as one plan, keeping column → row → position order")
    func multiSelection() {
        let a = card(doing, .resource(mia), 0)      // later column order than b? no: same column, later row
        let b = card(doing, .resource(ravi), 0)
        let c = card(todo, .resource(mia), 3)
        let plan = KanbanMoves.plan(.cards([a.id, b.id, c.id], to: .cell(columnID: done, row: .unassigned, beforeCardID: nil)),
                                    in: board([a, b, c]), now: now)
        // To Do comes before Doing; within Doing, Ravi's row comes before Mia's.
        #expect(after(plan, c.id)?.sortIndex == 0)
        #expect(after(plan, b.id)?.sortIndex == 1)
        #expect(after(plan, a.id)?.sortIndex == 2)
        #expect(plan.cardChanges.allSatisfy { $0.to.completedAt == now })
    }

    @Test("A multi-selection dropped on a column header keeps each card's own row")
    func multiSelectionColumnHeader() {
        let a = card(todo, .resource(ravi), 0), b = card(todo, .resource(mia), 0)
        let plan = KanbanMoves.plan(.cards([a.id, b.id], to: .columnHeader(doing)), in: board([a, b]), now: now)
        #expect(after(plan, a.id)?.row == .resource(ravi) && after(plan, b.id)?.row == .resource(mia))
    }

    // MARK: - WIP

    @Test("WIP counts the whole column; warn allows the drop, block refuses it", arguments: [KanbanWIPPolicy.warn, .block])
    func wip(_ policy: KanbanWIPPolicy) {
        let x = card(doing, .resource(ravi), 0), y = card(doing, .resource(mia), 0)
        let a = card(todo, .unassigned, 0)
        let plan = KanbanMoves.plan(.cards([a.id], to: .columnHeader(doing)), in: board([x, y, a], wip: policy, doingLimit: 2), now: now)
        if policy == .warn {
            #expect(plan.wip == .warn([doing]) && after(plan, a.id)?.columnID == doing)
        } else {
            #expect(plan.wip == .blocked([doing]) && plan.isNoOp && plan.cardChanges.isEmpty)
        }
    }

    @Test("Reordering inside a column at its limit isn't a WIP violation")
    func wipReorderInsideColumn() {
        let x = card(doing, .resource(ravi), 0), y = card(doing, .resource(mia), 0)
        let plan = KanbanMoves.plan(.cards([x.id], to: .rowHeader(.resource(mia))), in: board([x, y], wip: .block, doingLimit: 2), now: now)
        #expect(plan.wip == .ok && !plan.isNoOp)
    }

    // MARK: - Columns, rows, invalid input

    @Test("Columns reorder")
    func columnReorder() {
        let plan = KanbanMoves.plan(.reorderColumn(done, toIndex: 0), in: board([]), now: now)
        #expect(plan.columnOrder == [done, todo, doing])
    }

    @Test("Resource rows reorder; Unassigned stays pinned above them")
    func rowReorder() {
        let plan = KanbanMoves.plan(.reorderRow(mia, toIndex: 0), in: board([]), now: now)
        #expect(plan.rowOrder == [mia, ravi])
        #expect(KanbanMoves.plan(.reorderRow(mia, toIndex: 5), in: board([]), now: now).isNoOp)
    }

    @Test("Unknown or archived cards, columns and rows plan nothing")
    func invalidInput() {
        let a = card(doing, .resource(ravi), 0), gone = card(doing, .resource(ravi), 1, archived: true)
        let s = board([a, gone])
        #expect(KanbanMoves.plan(.cards([UUID()], to: .columnHeader(done)), in: s, now: now).isNoOp)
        #expect(KanbanMoves.plan(.cards([gone.id], to: .columnHeader(done)), in: s, now: now).isNoOp)
        #expect(KanbanMoves.plan(.cards([a.id], to: .columnHeader(UUID())), in: s, now: now).isNoOp)
        #expect(KanbanMoves.plan(.cards([a.id], to: .rowHeader(.resource(UUID()))), in: s, now: now).isNoOp)
        #expect(KanbanMoves.plan(.cards([], to: .columnHeader(done)), in: s, now: now).isNoOp)
    }

    // MARK: - Snapshot from models

    @Test("A snapshot from the models orders columns and rows and leaves out archived cards and rows")
    @MainActor
    func snapshotFromModels() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let project = KanbanProject(name: "P", key: "P")
        context.insert(project)
        let backlog = KanbanColumn(name: "To Do", kind: .backlog, sortIndex: 1)
        let finished = KanbanColumn(name: "Done", kind: .done, sortIndex: 0)
        for c in [backlog, finished] { context.insert(c); c.project = project }
        let person = KanbanPerson(name: "Ravi", initials: "RV")
        context.insert(person)
        let active = KanbanResource(person: person, sortIndex: 0), old = KanbanResource(person: person, sortIndex: 1)
        old.archivedAt = Date()
        for r in [active, old] { context.insert(r); r.project = project }
        let shown = KanbanTask(title: "shown"), hidden = KanbanTask(title: "hidden")
        hidden.archivedAt = Date()
        for t in [shown, hidden] { context.insert(t); t.project = project; t.column = backlog; t.resource = active }
        try context.save()

        let s = BoardSnapshot.make(project: project)
        #expect(s.columns.map(\.id) == [finished.id, backlog.id])
        #expect(s.rows.map(\.key) == [.unassigned, .resource(active.id)])
        #expect(s.cards.map(\.id) == [shown.id])
        #expect(BoardSnapshot.make(project: project, includeArchived: true).cards.count == 2)
    }
}
