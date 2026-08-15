import SwiftUI

/// Rows publish their frames (in the "planner" space) up to the window root, where
/// the `DragController` collects them for hit-testing.
struct RowFramesKey: PreferenceKey {
    static let defaultValue: [RowSnapshot] = []
    static func reduce(value: inout [RowSnapshot], nextValue: () -> [RowSnapshot]) {
        value.append(contentsOf: nextValue())
    }
}

/// Containers publish their frames + drop policy the same way.
struct ContainerFramesKey: PreferenceKey {
    static let defaultValue: [ContainerSnapshot] = []
    static func reduce(value: inout [ContainerSnapshot], nextValue: () -> [ContainerSnapshot]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Publish this view's frame as a reorderable row in `container`.
    func publishRowFrame(id: UUID, container: ReorderContainer) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFramesKey.self,
                    value: [RowSnapshot(id: id, container: container, frame: geo.frame(in: .global))]
                )
            }
        )
    }

    /// Publish this view's frame as a drop container.
    func publishContainerFrame(_ container: ReorderContainer, accepts: DragKind, axis: ReorderAxis, isEmpty: Bool) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ContainerFramesKey.self,
                    value: [ContainerSnapshot(container: container, frame: geo.frame(in: .global),
                                              accepts: accepts, axis: axis, isEmpty: isEmpty)]
                )
            }
        )
    }
}
