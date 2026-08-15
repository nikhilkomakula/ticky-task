import Testing
import Foundation
import CoreGraphics
import SwiftData
@testable import TickyTask

@Suite("Reorder geometry")
struct ReorderGeometryTests {

    // Three 40pt-tall rows stacked in a 100x300 vertical container at origin.
    // Midpoints: A=20, B=60, C=100.
    private let day = ReorderContainer.weekDay("20260101")
    private func vRow(_ id: UUID, _ y: CGFloat, _ container: ReorderContainer) -> RowSnapshot {
        RowSnapshot(id: id, container: container, frame: CGRect(x: 0, y: y, width: 100, height: 40))
    }
    private func vContainer(_ container: ReorderContainer, empty: Bool = false) -> ContainerSnapshot {
        ContainerSnapshot(container: container, frame: CGRect(x: 0, y: 0, width: 100, height: 300),
                          accepts: .task, axis: .vertical, isEmpty: empty)
    }

    @Test("Empty container: any pointer inside appends")
    func emptyAppends() {
        let t = ReorderGeometry.resolveTarget(pointer: CGPoint(x: 50, y: 50), rows: [],
                                              containers: [vContainer(day, empty: true)],
                                              draggingID: UUID(), kind: .task)
        #expect(t?.container == day)
        #expect(t?.beforeID == nil)
    }

    @Test("Midpoint decides before/after — dragging DOWN inserts after")
    func midpointBeforeAfter() {
        let a = UUID(), b = UUID(), c = UUID(), dragged = UUID()
        let rows = [vRow(a, 0, day), vRow(b, 40, day), vRow(c, 80, day)]
        let containers = [vContainer(day)]
        func resolve(_ y: CGFloat) -> UUID? {
            ReorderGeometry.resolveTarget(pointer: CGPoint(x: 50, y: y), rows: rows, containers: containers,
                                          draggingID: dragged, kind: .task)?.beforeID
        }
        #expect(resolve(10) == a)    // top half of A → before A
        #expect(resolve(50) == b)    // below A's midpoint → before B (i.e. after A)
        #expect(resolve(90) == c)    // below B's midpoint → before C
        #expect(resolve(200) == nil) // past the last midpoint → append
    }

    @Test("The dragged row is excluded from its own hit-test")
    func draggedExcluded() {
        let a = UUID(), b = UUID(), c = UUID()
        let rows = [vRow(a, 0, day), vRow(b, 40, day), vRow(c, 80, day)]
        // Dragging B, pointer hovering B's own old slot (y≈60): B is ignored, so the
        // next candidate is C (midpoint 100) → before C, which commits as a no-op move.
        let t = ReorderGeometry.resolveTarget(pointer: CGPoint(x: 50, y: 60), rows: rows,
                                              containers: [vContainer(day)], draggingID: b, kind: .task)
        #expect(t?.beforeID == c)
    }

    @Test("Kind filtering: a task ignores a listsRow, a card ignores task containers")
    func kindFiltering() {
        let list = ReorderContainer.list(UUID())
        let listsRow = ReorderContainer.listsRow
        let card = UUID()
        let overlapping = [
            ContainerSnapshot(container: list, frame: CGRect(x: 0, y: 0, width: 100, height: 300), accepts: .task, axis: .vertical, isEmpty: true),
            ContainerSnapshot(container: listsRow, frame: CGRect(x: 0, y: 0, width: 100, height: 300), accepts: .listCard, axis: .horizontal, isEmpty: false)
        ]
        let asTask = ReorderGeometry.resolveTarget(pointer: CGPoint(x: 50, y: 50), rows: [],
                                                   containers: overlapping, draggingID: UUID(), kind: .task)
        #expect(asTask?.container == list)
        let asCard = ReorderGeometry.resolveTarget(pointer: CGPoint(x: 50, y: 50), rows: [],
                                                   containers: overlapping, draggingID: card, kind: .listCard)
        #expect(asCard?.container == listsRow)
    }

    @Test("Horizontal axis: cards resolve on x, left half → before")
    func horizontalCards() {
        let a = UUID(), b = UUID()
        let rowsRow = ReorderContainer.listsRow
        let rows = [
            RowSnapshot(id: a, container: rowsRow, frame: CGRect(x: 0, y: 0, width: 120, height: 200)),
            RowSnapshot(id: b, container: rowsRow, frame: CGRect(x: 120, y: 0, width: 120, height: 200))
        ]
        let containers = [ContainerSnapshot(container: rowsRow, frame: CGRect(x: 0, y: 0, width: 300, height: 200),
                                            accepts: .listCard, axis: .horizontal, isEmpty: false)]
        func resolve(_ x: CGFloat) -> UUID? {
            ReorderGeometry.resolveTarget(pointer: CGPoint(x: x, y: 100), rows: rows, containers: containers,
                                          draggingID: UUID(), kind: .listCard)?.beforeID
        }
        #expect(resolve(30) == a)     // left half of A → before A
        #expect(resolve(130) == b)    // just past A's mid (60), left of B's mid (180) → before B
        #expect(resolve(260) == nil)  // past B's midpoint → append
    }

    @Test("Surface-qualified containers with the same day key don't collide")
    func surfaceQualified() {
        let agenda = ReorderContainer.agendaDay("20260101")
        let month = ReorderContainer.monthDay("20260101")
        let aRow = UUID()
        // A row registered for the agenda must not be considered when the pointer is
        // over the month cell (append-only, no rows).
        let rows = [RowSnapshot(id: aRow, container: agenda, frame: CGRect(x: 0, y: 0, width: 100, height: 40))]
        let containers = [ContainerSnapshot(container: month, frame: CGRect(x: 0, y: 0, width: 100, height: 300),
                                            accepts: .task, axis: .vertical, isEmpty: true)]
        let t = ReorderGeometry.resolveTarget(pointer: CGPoint(x: 50, y: 10), rows: rows, containers: containers,
                                              draggingID: UUID(), kind: .task)
        #expect(t?.container == month)
        #expect(t?.beforeID == nil)   // month cell ignores the agenda's row → append
    }

    @Test("Innermost (smallest) accepting container wins")
    func innermostWins() {
        let outer = ReorderContainer.weekDay("outer")
        let inner = ReorderContainer.list(UUID())
        let containers = [
            ContainerSnapshot(container: outer, frame: CGRect(x: 0, y: 0, width: 400, height: 400), accepts: .task, axis: .vertical, isEmpty: true),
            ContainerSnapshot(container: inner, frame: CGRect(x: 10, y: 10, width: 100, height: 100), accepts: .task, axis: .vertical, isEmpty: true)
        ]
        let t = ReorderGeometry.resolveTarget(pointer: CGPoint(x: 50, y: 50), rows: [], containers: containers,
                                              draggingID: UUID(), kind: .task)
        #expect(t?.container == inner)
    }

    @Test("No accepting container under the pointer → nil (caller keeps last target)")
    func noContainer() {
        let t = ReorderGeometry.resolveTarget(pointer: CGPoint(x: 999, y: 999), rows: [],
                                              containers: [vContainer(day)], draggingID: UUID(), kind: .task)
        #expect(t == nil)
    }

    @Test("Sort-mode gating: position honored only in manual")
    func sortModeGating() {
        let before = UUID()
        let target = ReorderTarget(container: day, beforeID: before)
        #expect(ReorderGeometry.effectiveBeforeID(target, manual: true) == before)
        #expect(ReorderGeometry.effectiveBeforeID(target, manual: false) == nil)
        #expect(ReorderGeometry.effectiveBeforeID(nil, manual: true) == nil)
    }

    @Test("taskLocation maps day kinds to .day and listsRow to nil")
    func taskLocationMapping() {
        if case .day(let k)? = ReorderContainer.weekDay("D").taskLocation(resolveList: { _ in nil }) {
            #expect(k == "D")
        } else { Issue.record("weekDay should map to .day") }
        if case .day(let k)? = ReorderContainer.monthDay("M").taskLocation(resolveList: { _ in nil }) {
            #expect(k == "M")
        } else { Issue.record("monthDay should map to .day") }
        if case .day(let k)? = ReorderContainer.agendaDay("A").taskLocation(resolveList: { _ in nil }) {
            #expect(k == "A")
        } else { Issue.record("agendaDay should map to .day") }
        #expect(ReorderContainer.listsRow.taskLocation(resolveList: { _ in nil }) == nil)
    }

    // MARK: - Composition: resolved target → real DataService.dropTask

    @MainActor
    @Test("Composition: dragging DOWN commits an insert-after through DataService")
    func compositionInsertAfter() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = DataService(context)
        let a = try service.addTask(title: "A", location: .day("20260101"))
        let b = try service.addTask(title: "B", location: .day("20260101"))
        let c = try service.addTask(title: "C", location: .day("20260101"))
        try service.save()

        // Rows laid out A(0), B(40), C(80); drag A down below B's midpoint (y=70).
        let rows = [vRow(a.id, 0, day), vRow(b.id, 40, day), vRow(c.id, 80, day)]
        let target = ReorderGeometry.resolveTarget(pointer: CGPoint(x: 50, y: 70), rows: rows,
                                                   containers: [vContainer(day)], draggingID: a.id, kind: .task)
        #expect(target?.beforeID == c.id)   // after B, before C

        let siblings = BehaviorService.sorted(try context.fetch(FetchDescriptor<TaskItem>()), mode: .manual, completedToBottom: false)
        try service.dropTask(a.id, into: .day("20260101"), before: target?.beforeID, siblings: siblings)

        let ordered = BehaviorService.sorted(try context.fetch(FetchDescriptor<TaskItem>()), mode: .manual, completedToBottom: false)
        #expect(ordered.map(\.title) == ["B", "A", "C"])
    }
}
