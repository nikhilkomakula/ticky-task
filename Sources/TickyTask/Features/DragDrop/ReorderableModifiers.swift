import SwiftUI

/// Makes a row a drag source + drop participant: it publishes its frame, dims to a
/// gap while it's the one being dragged, and carries a `DragGesture` (in "planner"
/// space) that drives the controller. Applied by the CONTAINER around each row so
/// `TaskRowView` stays reusable and its tap/hover/context-menu are untouched.
///
/// `minimumDistance: 4` keeps a stationary click as the row's tap-to-edit; only
/// real movement starts a drag. On macOS content drags don't scroll (the scroll
/// view pans via wheel/trackpad), so this never fights vertical scrolling.
struct ReorderableRow: ViewModifier {
    let id: UUID
    let kind: DragKind
    let container: ReorderContainer
    var task: TaskItem?
    var list: CustomList?
    var controller: DragController

    func body(content: Content) -> some View {
        content
            .opacity(controller.isDragging(id) ? 0.001 : 1)
            .publishRowFrame(id: id, container: container)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("planner"))
                    .onChanged { value in
                        if !controller.isDragging(id) {
                            controller.begin(id: id, kind: kind, task: task, list: list, startLocation: value.startLocation)
                        }
                        controller.update(pointer: value.location)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { controller.end() }
                    }
            )
    }
}

extension View {
    /// Make this row draggable-to-reorder within/across `container`.
    func reorderableRow(id: UUID, kind: DragKind, container: ReorderContainer,
                        controller: DragController, task: TaskItem? = nil, list: CustomList? = nil) -> some View {
        modifier(ReorderableRow(id: id, kind: kind, container: container, task: task, list: list, controller: controller))
    }

    /// Mark a custom-list card as a `.listsRow` row (frame + gap dim). The drag
    /// itself is started from the card's header via `reorderCardHandle`, so dragging
    /// a task row inside the card never moves the whole card.
    func reorderableListCard(id: UUID, controller: DragController) -> some View {
        opacity(controller.isDragging(id) ? 0.001 : 1)
            .publishRowFrame(id: id, container: .listsRow)
    }

    /// A drag handle that starts a `.listCard` drag for list `list`.
    func reorderCardHandle(id: UUID, controller: DragController, list: CustomList) -> some View {
        gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("planner"))
                .onChanged { value in
                    if !controller.isDragging(id) {
                        controller.begin(id: id, kind: .listCard, task: nil, list: list, startLocation: value.startLocation)
                    }
                    controller.update(pointer: value.location)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { controller.end() }
                }
        )
    }
}
