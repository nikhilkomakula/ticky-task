import SwiftUI

/// The board's non-interactive drag overlay, in the planner's chrome: the lifted card
/// (or column/row title) following the cursor 1:1, the accent insertion line, and an
/// outline on the target header or cell — red when a blocking WIP limit would refuse it.
struct BoardDragOverlay: View {
    var controller: BoardDragController
    let project: KanbanProject

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if let frame = controller.highlight {
                    let blocked = controller.wipNote?.blocks == true
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(blocked ? Color.red : Color.accentColor, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill((blocked ? Color.red : Color.accentColor).opacity(0.06)))
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX - origin.x, y: frame.midY - origin.y)
                }
                if let line = controller.insertionLine {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: line.width, height: line.height)
                        .position(x: line.midX - origin.x, y: line.midY - origin.y)
                        .animation(DragChrome.lineSpring, value: controller.target)
                }
                preview(origin: origin)
                if let note = controller.wipNote {
                    Label(note.blocks ? "\(note.text) — can’t drop here" : note.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.red.opacity(0.9)))
                        .foregroundStyle(.white)
                        .position(x: controller.pointer.x - origin.x, y: controller.pointer.y - origin.y - 28)
                        .accessibilityIdentifier("kanban-wip-note")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func preview(origin: CGPoint) -> some View {
        if let task = controller.previewTask, controller.previewSize != .zero {
            KanbanCardView(task: task, project: project)
                .frame(width: controller.previewSize.width)
                .scaleEffect(DragChrome.liftScale)
                .shadow(color: .black.opacity(DragChrome.shadowOpacity), radius: DragChrome.shadowRadius, y: DragChrome.shadowY)
                .position(x: controller.previewOrigin.x + controller.previewSize.width / 2 - origin.x,
                          y: controller.previewOrigin.y + controller.previewSize.height / 2 - origin.y)
        } else if controller.isActive, !controller.previewTitle.isEmpty {
            let size = CGSize(width: max(controller.previewSize.width, 160), height: min(max(controller.previewSize.height, 32), 44))
            Text(controller.previewTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(width: size.width, height: size.height, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                .scaleEffect(DragChrome.liftScale)
                .shadow(color: .black.opacity(DragChrome.shadowOpacity), radius: DragChrome.shadowRadius, y: DragChrome.shadowY)
                .position(x: controller.previewOrigin.x + size.width / 2 - origin.x,
                          y: controller.previewOrigin.y + size.height / 2 - origin.y)
        }
    }
}
