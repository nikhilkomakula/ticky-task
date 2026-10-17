import SwiftUI

/// One board's drag (design 01 §4), the sibling of the planner's `DragController`: views
/// publish their frames, the pure `BoardGeometry` resolves the target, and a drop commits
/// one `MoveOp` through `KanbanService`. While hovering it also works out the WIP note for
/// the target column and the projected load of the rows the drop would change.
@MainActor
@Observable
final class BoardDragController {
    struct Projection: Equatable {
        var before: Double
        var after: Double
        var target: Double
        var utilisation: KanbanMetrics.Utilisation
    }

    struct WIPNote: Equatable {
        var columnID: UUID
        var text: String
        var blocks: Bool
    }

    private(set) var source: BoardDragSource?
    private(set) var target: BoardDropTarget?
    private(set) var pointer: CGPoint = .zero
    private(set) var previewSize: CGSize = .zero
    private(set) var previewTask: KanbanTask?
    private(set) var previewTitle = ""
    private(set) var wipNote: WIPNote?
    /// By membership id.
    private(set) var projected: [UUID: Projection] = [:]
    /// Bumped when the frames move during a drag, so the indicator follows the board.
    private(set) var geometryRevision = 0
    private var grabOffset: CGSize = .zero

    // Set by the board; not observed, so frame churn while scrolling redraws nothing.
    @ObservationIgnored var frames = BoardFrames() {
        didSet { if frames.rowOrder != rowOrder { frames.rowOrder = rowOrder } }
    }
    /// Every membership row in board order (the lazy grid publishes only drawn rows).
    @ObservationIgnored var rowOrder: [UUID] = [] {
        didSet { frames.rowOrder = rowOrder }
    }
    @ObservationIgnored var project: KanbanProject?
    @ObservationIgnored var metrics: MetricsSnapshot?
    @ObservationIgnored var commit: (MoveOp) -> Void = { _ in }
    @ObservationIgnored var scrollBy: (CGVector) -> Void = { _ in }
    @ObservationIgnored private var autoScroll: Timer?

    var isActive: Bool { source != nil }

    func isDragging(card id: UUID) -> Bool {
        if case let .cards(ids)? = source { return ids.contains(id) }
        return false
    }

    func isDragging(column id: UUID) -> Bool { source == .column(id) }
    func isDragging(row id: UUID) -> Bool { source == .row(id) }

    /// Top-left of the floating preview, so the grabbed point stays under the cursor.
    var previewOrigin: CGPoint { CGPoint(x: pointer.x - grabOffset.width, y: pointer.y - grabOffset.height) }

    // MARK: - Lifecycle

    func begin(_ source: BoardDragSource, frame: CGRect?, start: CGPoint, task: KanbanTask? = nil, title: String = "") {
        self.source = source
        previewTask = task
        previewTitle = title
        if let frame {
            previewSize = frame.size
            grabOffset = CGSize(width: start.x - frame.minX, height: start.y - frame.minY)
        }
        pointer = start
        recompute()
        autoScroll?.invalidate()
        autoScroll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }   // the board went away mid-drag
                self.tick()
            }
        }
    }

    func update(pointer: CGPoint) {
        self.pointer = pointer
        recompute()
    }

    /// The board's frames moved (scrolling, auto-scroll): the pointer may be over something new.
    func framesChanged() {
        guard isActive else { return }
        geometryRevision &+= 1
        recompute()
    }

    func end() {
        if let source, let target, let op = BoardGeometry.operation(source: source, target: target) { commit(op) }
        clear()
    }

    func cancel() { clear() }

    private func clear() {
        autoScroll?.invalidate()
        autoScroll = nil
        source = nil
        target = nil
        previewTask = nil
        previewTitle = ""
        previewSize = .zero
        grabOffset = .zero
        wipNote = nil
        projected = [:]
    }

    private func tick() {
        let delta = BoardGeometry.autoScrollDelta(pointer: pointer, viewport: frames.viewport)
        if delta != .zero { scrollBy(delta) }
    }

    private func recompute() {
        guard let source else { return }
        let next = BoardGeometry.resolve(pointer: pointer, source: source, frames: frames)
        guard next != target else { return }
        target = next
        updatePreviews()
    }

    // MARK: - Hover previews

    /// The column and membership a card would end up in for the current target.
    private func destination(of task: KanbanTask) -> (column: UUID?, resource: UUID??) {
        switch target {
        case let .cell(column, row, _)?: (column, .some(row.resourceID))
        case let .columnHeader(column)?: (column, nil)
        case let .rowHeader(row)?: (task.column?.id, .some(row.resourceID))
        default: (nil, nil)
        }
    }

    private func updatePreviews() {
        wipNote = nil
        projected = [:]
        guard case let .cards(ids)? = source, let project, target != nil else { return }
        let dragged = project.tasks.filter { ids.contains($0.id) }
        guard !dragged.isEmpty else { return }

        // As `KanbanMoves` decides: each card lands in its own column (a row header keeps
        // it), and only a column that gains cards can go over its limit.
        let landing = Dictionary(grouping: dragged) { destination(of: $0).column ?? $0.column?.id }
        for (columnID, arriving) in landing {
            guard let columnID, arriving.contains(where: { $0.column?.id != columnID }),
                  let column = project.columns.first(where: { $0.id == columnID }), let limit = column.wipLimit else { continue }
            let staying = project.tasks.filter { $0.archivedAt == nil && $0.column?.id == columnID && !ids.contains($0.id) }.count
            let count = staying + arriving.count
            if count > limit {
                wipNote = WIPNote(columnID: columnID, text: "\(count)/\(limit) — over limit", blocks: project.wipPolicy == .block)
                break
            }
        }

        guard let metrics else { return }
        let selectedIDs = Set(ids)
        let columnKinds = Dictionary(uniqueKeysWithValues: metrics.columns.map { ($0.id, $0.kind) })
        let days = MetricsDays(metrics)

        // Map metrics card IDs to their destinations via dragged tasks.
        let cardDestinations = Dictionary(uniqueKeysWithValues: dragged.map { task in
            (task.id, destination(of: task))
        })

        // Compute baselines once: current load for each affected member.
        var baseline: [UUID: Double] = [:]
        var affected: Set<UUID> = []
        for card in metrics.cards where !card.archived {
            let value = KanbanMetrics.thisWeek(metrics, days, card)
            if columnKinds[card.column] != .done, let owner = card.resource {
                baseline[owner, default: 0] += value
                affected.insert(owner)
            }
        }

        // Accumulate deltas: for each selected card, update the destination owner's load.
        var delta: [UUID: Double] = [:]
        for card in metrics.cards where selectedIDs.contains(card.id) && !card.archived {
            let value = KanbanMetrics.thisWeek(metrics, days, card)
            // Subtract from the current owner if it's open.
            if columnKinds[card.column] != .done, let owner = card.resource {
                delta[owner, default: 0] -= value
            }
            // Add to the destination owner if it's open.
            guard let dest = cardDestinations[card.id] else { continue }
            let col = dest.column ?? card.column
            if columnKinds[col] != .done {
                // dest.resource is UUID?? - unwrap to UUID?
                if let owner = dest.resource.flatMap({ $0 }) {
                    delta[owner, default: 0] += value
                    affected.insert(owner)
                }
            }
        }

        // Publish previews only for affected members.
        let t = metrics.members.reduce(into: [UUID: Double]()) { targets, member in
            targets[member.id] = KanbanMetrics.target(metrics, member)
        }
        for memberID in affected {
            let before = baseline[memberID] ?? 0
            let after = before + (delta[memberID] ?? 0)
            if after != before {
                projected[memberID] = Projection(before: before, after: after, target: t[memberID] ?? 0,
                                                utilisation: KanbanMetrics.utilisation(load: after, target: t[memberID] ?? 0))
            }
        }
    }

    // MARK: - Insertion indicator, in global coordinates

    var insertionLine: CGRect? {
        _ = geometryRevision
        guard let target else { return nil }
        let thickness: CGFloat = DragChrome.lineThickness
        switch target {
        case let .cell(column, row, before):
            guard let cell = frames.cells.first(where: { $0.columnID == column && $0.row == row }) else { return nil }
            let siblings = frames.cards.filter { $0.columnID == column && $0.row == row && !isDragging(card: $0.id) }
                .sorted { $0.frame.minY < $1.frame.minY }
            let y: CGFloat
            if let before, let card = siblings.first(where: { $0.id == before }) {
                y = card.frame.minY - 3
            } else if let last = siblings.last {
                y = last.frame.maxY + 3
            } else {
                y = cell.frame.minY + 8
            }
            return CGRect(x: cell.frame.minX + 6, y: y - thickness / 2, width: max(0, cell.frame.width - 12), height: thickness)
        case let .columnSlot(index):
            let others = frames.columnHeaders.filter { !isDragging(column: $0.id) }.sorted { $0.frame.minX < $1.frame.minX }
            guard let reference = others.first ?? frames.columnHeaders.first else { return nil }
            let x = index < others.count ? others[index].frame.minX : (others.last?.frame.maxX ?? reference.frame.maxX)
            return CGRect(x: x - thickness / 2, y: reference.frame.minY, width: thickness, height: frames.viewport.maxY - reference.frame.minY)
        case let .rowSlot(index):
            // `index` counts the complete order without the dragged row: draw above the row
            // now at that index, or below the one before it.
            guard case let .row(source)? = source, let reference = frames.rowHeaders.first(where: { !$0.isSummary }) else { return nil }
            let order = frames.rowOrder.filter { $0 != source }
            func header(_ id: UUID) -> CGRect? { frames.rowHeaders.first { !$0.isSummary && $0.row == .resource(id) }?.frame }
            let y: CGFloat
            if index < order.count, let frame = header(order[index]) {
                y = frame.minY
            } else if index > 0, index - 1 < order.count, let frame = header(order[index - 1]) {
                y = frame.maxY
            } else {
                return nil
            }
            return CGRect(x: reference.frame.minX, y: y - thickness / 2, width: frames.viewport.maxX - reference.frame.minX, height: thickness)
        case .columnHeader, .rowHeader:
            return nil
        }
    }

    /// The header or cell to outline as the drop target.
    var highlight: CGRect? {
        _ = geometryRevision
        return switch target {
        case let .columnHeader(id)?: frames.columnHeaders.first { $0.id == id }?.frame
        case let .rowHeader(row)?: frames.rowHeaders.first { $0.row == row && !$0.isSummary }?.frame
        case let .cell(column, row, _)?: frames.cells.first { $0.columnID == column && $0.row == row }?.frame
        default: nil
        }
    }
}

extension KanbanRowKey {
    var resourceID: UUID? { if case let .resource(id) = self { id } else { nil } }
}

/// Board views publish their frames (global coordinates) up to the board.
struct BoardFramesKey: PreferenceKey {
    static let defaultValue = BoardFrames()
    static func reduce(value: inout BoardFrames, nextValue: () -> BoardFrames) {
        let next = nextValue()
        value.cards += next.cards
        value.cells += next.cells
        value.columnHeaders += next.columnHeaders
        value.rowHeaders += next.rowHeaders
        if next.viewport != .zero { value.viewport = next.viewport }
        if next.corner != .zero { value.corner = next.corner }
    }
}

extension View {
    func publishBoardFrame(_ make: @escaping (CGRect) -> BoardFrames) -> some View {
        background(GeometryReader { geo in Color.clear.preference(key: BoardFramesKey.self, value: make(geo.frame(in: .global))) })
    }

    /// Makes this view a drag source. `minimumDistance: 4` keeps a click a click (open the
    /// card); high priority so the drag wins over the card's own tap, as in the planner.
    func boardDraggable(_ source: BoardDragSource, controller: BoardDragController, frame: @escaping () -> CGRect?,
                        task: KanbanTask? = nil, title: String = "") -> some View {
        modifier(BoardDraggable(source: source, controller: controller, frame: frame, task: task, title: title))
    }
}

private struct BoardDraggable: ViewModifier {
    let source: BoardDragSource
    let controller: BoardDragController
    let frame: () -> CGRect?
    let task: KanbanTask?
    let title: String
    /// Resets when the gesture ends or is cancelled; `onEnded` only runs for an end.
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        content
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        if controller.source != source {
                            controller.begin(source, frame: frame(), start: value.startLocation, task: task, title: title)
                        }
                        controller.update(pointer: value.location)
                    }
                    .onEnded { _ in
                        withAnimation(DragChrome.dropSpring) { controller.end() }
                    }
            )
            .onChange(of: isDragging) { _, dragging in
                // A cancelled gesture (no `onEnded`) leaves nothing behind.
                if !dragging, controller.source == source { controller.cancel() }
            }
    }
}
