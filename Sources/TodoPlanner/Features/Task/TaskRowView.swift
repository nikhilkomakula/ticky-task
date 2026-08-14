import SwiftUI
import SwiftData

/// A single task row: completion toggle, priority glyph, title, and trailing
/// metadata (subtask badge, alarm, time). Hover-highlighted; tap to edit.
struct TaskRowView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("compactView") private var compactView = false
    let task: TaskItem
    var onEdit: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleDone) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(task.isDone ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 20)

            Image(systemName: task.priorityLevel.symbol)
                .font(.system(size: 11))
                .foregroundStyle(task.priorityLevel.tint)

            Text(task.title.isEmpty ? "Untitled" : task.title)
                .font(.system(size: 13))
                .strikethrough(task.isDone)
                .foregroundStyle(task.isDone ? .secondary : .primary)
                .lineLimit(compactView ? 1 : 2)
                .layoutPriority(1)

            Spacer(minLength: 4)

            if !task.subtasks.isEmpty {
                let done = task.subtasks.filter(\.isDone).count
                Text("\(done)/\(task.subtasks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            if task.alarmEnabled {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let minutes = task.timeMinutes, !compactView {
                Text(Self.timeLabel(minutes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compactView ? 4 : 6)
        .background(
            isHovering ? Color.primary.opacity(0.075) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onTapGesture { onEdit?() }
        .help("Edit task")
        .contextMenu {
            Button(task.isDone ? "Mark as not done" : "Mark as done", action: toggleDone)
            if onEdit != nil { Button("Edit…") { onEdit?() } }
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func toggleDone() {
        task.isDone.toggle()
        task.updatedAt = Date()
        try? context.save()
        Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
    }

    private func delete() {
        context.delete(task)
        try? context.save()
        Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
    }

    /// 24-hour "HH:mm" from minutes-since-midnight.
    static func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
