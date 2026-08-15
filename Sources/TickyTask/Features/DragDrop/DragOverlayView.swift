import SwiftUI

/// The window-level, non-interactive overlay that renders the lifted drag preview
/// (following the cursor 1:1) and the accent insertion line. Lives at the top of
/// the host window's root `ZStack`, inside the `"planner"` coordinate space, so the
/// preview can visually cross day-columns/lists that would otherwise clip it.
struct DragOverlayView: View {
    var controller: DragController

    var body: some View {
        ZStack(alignment: .topLeading) {
            insertionLine
            preview
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var insertionLine: some View {
        if let line = controller.insertionIndicator {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: line.width, height: line.height)
                .position(x: line.midX, y: line.midY)
                .animation(.spring(response: 0.22, dampingFraction: 0.85), value: controller.target)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var preview: some View {
        if let task = controller.previewTask, controller.previewSize != .zero {
            TaskRowView(task: task)
                .frame(width: controller.previewSize.width, alignment: .leading)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                .scaleEffect(1.03)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
                .position(x: controller.previewOrigin.x + controller.previewSize.width / 2,
                          y: controller.previewOrigin.y + controller.previewSize.height / 2)
        } else if let list = controller.previewList {
            let width = controller.previewSize.width > 0 ? controller.previewSize.width : 200
            let height = controller.previewSize.height > 0 ? controller.previewSize.height : 44
            Text(list.name.isEmpty ? "List" : list.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(width: width, height: min(height, 44), alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                .scaleEffect(1.03)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
                .position(x: controller.previewOrigin.x + width / 2,
                          y: controller.previewOrigin.y + min(height, 44) / 2)
        }
    }
}
