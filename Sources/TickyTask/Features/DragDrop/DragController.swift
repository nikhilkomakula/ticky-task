import SwiftUI
import SwiftData

/// Owns a single active drag-to-reorder gesture for one window. Rows/containers
/// publish their frames into it (via preferences); it computes the live drop
/// target with the pure `ReorderGeometry`, drives the floating preview + insertion
/// indicator, and commits through the already-tested `DataService`/`BehaviorService`.
///
/// One instance per window (the main window and the menu-bar popover are separate
/// scenes with separate `"planner"` coordinate spaces), created by the host view.
@MainActor
@Observable
final class DragController {
    // Active drag
    private(set) var draggingID: UUID?
    private(set) var kind: DragKind = .task
    private(set) var previewTask: TaskItem?
    private(set) var previewList: CustomList?
    private(set) var previewSize: CGSize = .zero
    private var grabOffset: CGSize = .zero
    private(set) var pointer: CGPoint = .zero

    /// Published geometry, assigned from `.onPreferenceChange` at the window root.
    var rowFrames: [RowSnapshot] = []
    var containerFrames: [ContainerSnapshot] = []

    /// Host configuration.
    var context: ModelContext?
    var sortMode: TaskSortMode = .manual
    var completedToBottom = true
    var reorderEnabled: Bool { sortMode == .manual }

    /// The live resolved drop target.
    private(set) var target: ReorderTarget?

    // MARK: - Queries used by the views

    func isDragging(_ id: UUID) -> Bool { draggingID == id }
    var isActive: Bool { draggingID != nil }

    /// Top-left of the floating preview so it tracks the cursor 1:1 (no lag): the
    /// point under the cursor stays fixed relative to the lifted row.
    var previewOrigin: CGPoint {
        CGPoint(x: pointer.x - grabOffset.width, y: pointer.y - grabOffset.height)
    }

    // MARK: - Gesture lifecycle

    func begin(id: UUID, kind: DragKind, task: TaskItem?, list: CustomList?, startLocation: CGPoint) {
        draggingID = id
        self.kind = kind
        previewTask = task
        previewList = list
        if let frame = rowFrames.first(where: { $0.id == id })?.frame {
            previewSize = frame.size
            grabOffset = CGSize(width: startLocation.x - frame.minX, height: startLocation.y - frame.minY)
        } else {
            previewSize = .zero
            grabOffset = .zero
        }
        pointer = startLocation
        recompute()
    }

    func update(pointer: CGPoint) {
        self.pointer = pointer
        recompute()
    }

    func end() {
        commit()
        clear()
    }

    func cancel() { clear() }

    private func recompute() {
        guard let draggingID else { target = nil; return }
        target = ReorderGeometry.resolveTarget(pointer: pointer, rows: rowFrames, containers: containerFrames,
                                               draggingID: draggingID, kind: kind)
    }

    private func clear() {
        draggingID = nil
        previewTask = nil
        previewList = nil
        previewSize = .zero
        grabOffset = .zero
        target = nil
    }

    // MARK: - Commit (reuses the tested persistence path)

    private func commit() {
        guard let context, let draggingID, let target else { return }
        let service = DataService(context)
        switch kind {
        case .task:
            guard let location = target.container.taskLocation(resolveList: { fetchList($0, context) }) else { return }
            // Abort (don't renumber) if the destination siblings can't be fetched:
            // proceeding with an empty list would collide the moved task at sortIndex 0.
            guard let siblings = try? siblingTasks(for: target.container, context: context) else { return }
            let beforeID = ReorderGeometry.effectiveBeforeID(target, manual: reorderEnabled)
            try? service.dropTask(draggingID, into: location, before: beforeID, siblings: siblings)
        case .listCard:
            guard case .listsRow = target.container else { return }
            let lists = (try? context.fetch(FetchDescriptor<CustomList>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
            let newOrder = BehaviorService.reordered(lists, moving: draggingID, before: target.beforeID)
            try? service.reorderLists(newOrder)
        }
    }

    /// The target container's current tasks in display order — exactly what the old
    /// `.dropDestination` call sites passed to `DataService.dropTask`.
    private func siblingTasks(for container: ReorderContainer, context: ModelContext) throws -> [TaskItem] {
        switch container {
        case .weekDay(let k), .monthDay(let k), .agendaDay(let k):
            let key: String? = k
            let all = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.dayKey == key }))
            return BehaviorService.sorted(all, mode: sortMode, completedToBottom: completedToBottom)
        case .list(let id):
            guard let list = fetchList(id, context) else { return [] }
            return BehaviorService.sorted(list.tasks, mode: sortMode, completedToBottom: completedToBottom)
        case .listsRow:
            return []
        }
    }

    private func fetchList(_ id: UUID, _ context: ModelContext) -> CustomList? {
        (try? context.fetch(FetchDescriptor<CustomList>(predicate: #Predicate { $0.id == id })))?.first
    }

    // MARK: - Insertion indicator (drawn by DragOverlayView)

    /// The accent insertion line's frame in "planner" space, or nil when inactive.
    /// A thin bar between rows (vertical containers) or between cards (horizontal).
    var insertionIndicator: CGRect? {
        guard isActive, let target,
              let container = containerFrames.first(where: { $0.container == target.container })
        else { return nil }

        let axis = container.axis
        let siblings = rowFrames
            .filter { $0.container == target.container && $0.id != draggingID }
            .sorted { edge($0.frame, axis) < edge($1.frame, axis) }
        let thickness: CGFloat = 3

        if axis == .vertical {
            let x = container.frame.minX + 6
            let width = max(0, container.frame.width - 12)
            let y: CGFloat
            if let beforeID = target.beforeID, let row = siblings.first(where: { $0.id == beforeID }) {
                y = row.frame.minY - thickness / 2 - 2
            } else if let last = siblings.last {
                y = last.frame.maxY - thickness / 2 + 2
            } else {
                y = container.frame.minY + 10
            }
            return CGRect(x: x, y: y, width: width, height: thickness)
        } else {
            let y = container.frame.minY + 6
            let height = max(0, container.frame.height - 12)
            let x: CGFloat
            if let beforeID = target.beforeID, let card = siblings.first(where: { $0.id == beforeID }) {
                x = card.frame.minX - thickness / 2 - 2
            } else if let last = siblings.last {
                x = last.frame.maxX - thickness / 2 + 2
            } else {
                x = container.frame.minX + 10
            }
            return CGRect(x: x, y: y, width: thickness, height: height)
        }
    }

    private func edge(_ r: CGRect, _ axis: ReorderAxis) -> CGFloat { axis == .vertical ? r.minY : r.minX }
}
