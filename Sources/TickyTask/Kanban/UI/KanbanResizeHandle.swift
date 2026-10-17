import SwiftUI

/// The width being dragged, read only by the frames that follow it, so a resize redraws those
/// frames rather than the whole board.
@MainActor @Observable
final class KanbanLiveWidth {
    enum Slot: Hashable {
        case sidebar, rowHeader
        case column(UUID)
    }

    private(set) var slot: Slot?
    private(set) var width: CGFloat = 0

    func set(_ slot: Slot, _ width: CGFloat?) {
        if let width {
            self.slot = slot
            self.width = width
        } else if self.slot == slot {
            self.slot = nil
        }
    }

    func width(_ slot: Slot, base: CGFloat) -> CGFloat { self.slot == slot ? width : base }
}

/// Frames a view at the summed widths of its slots, following a resize while it's dragged.
struct KanbanLiveWidthFrame: ViewModifier {
    let live: KanbanLiveWidth
    let slots: [KanbanLiveWidth.Slot]
    let base: (KanbanLiveWidth.Slot) -> CGFloat
    var height: CGFloat?
    var alignment: Alignment = .center

    func body(content: Content) -> some View {
        content.frame(width: slots.reduce(0) { $0 + live.width($1, base: base($1)) }, height: height, alignment: alignment)
    }
}

/// An 8 pt handle on a resizable column's trailing edge. Dragging resizes it live and saves
/// once the drag ends; a cancelled drag puts the width back. Double-click resets it.
struct KanbanResizeHandle: View {
    let name: String
    let slot: KanbanLiveWidth.Slot
    let width: CGFloat
    let policy: KanbanWidthPolicy
    let live: KanbanLiveWidth
    var isDisabled = false
    let onCommit: (Double) -> Void
    let onReset: () -> Void
    var onResetAll: (() -> Void)?
    /// Resets when the gesture ends or is cancelled; `onEnded` only runs for an end.
    @GestureState private var translation: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($translation) { value, state, _ in state = value.translation.width }
                    .onEnded { value in onCommit(policy.clamp(Double(width + value.translation.width))) },
                isEnabled: !isDisabled
            )
            .onChange(of: translation) { _, offset in
                live.set(slot, offset.map { CGFloat(policy.clamp(Double(width + $0))) })
            }
            .onTapGesture(count: 2, perform: onReset)
            .contextMenu {
                Button("Reset width", action: onReset)
                if let onResetAll { Button("Reset all column widths", action: onResetAll) }
            }
            .allowsHitTesting(!isDisabled)
            .help("Drag to resize; double-click to reset")
            .accessibilityElement()
            .accessibilityLabel("Resize \(name)")
            .accessibilityValue("\(Int(width.rounded())) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onCommit(policy.clamp(Double(width) + 10))
                case .decrement: onCommit(policy.clamp(Double(width) - 10))
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Reset width", onReset)
            .accessibilityIdentifier("kanban-resize-\(name)")
    }
}

extension KanbanBoardWidths {
    func width(_ slot: KanbanLiveWidth.Slot) -> CGFloat {
        switch slot {
        case .rowHeader: rowHeader
        case let .column(id): column(id)
        case .sidebar: 0
        }
    }
}
