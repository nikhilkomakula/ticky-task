import SwiftUI
import SwiftData

/// A single task row: completion toggle, color dot, title, and optional time,
/// with a context menu for quick actions. Tapping invokes `onEdit` (the full
/// editor is wired in P2.3).
struct TaskRowView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("compactView") private var compactView = false
    let task: TaskItem
    var onEdit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleDone) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            if let hex = task.colorHex, let color = Color(hex: hex) {
                Circle().fill(color).frame(width: 8, height: 8)
            }

            if task.priorityLevel.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(task.priorityLevel.tint)
            }

            if task.alarmEnabled {
                Image(systemName: "bell.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(task.title.isEmpty ? "Untitled" : task.title)
                .strikethrough(task.isDone)
                .foregroundStyle(task.isDone ? .secondary : .primary)
                .lineLimit(2)

            Spacer(minLength: 4)

            if !task.subtasks.isEmpty {
                let done = task.subtasks.filter(\.isDone).count
                Text("\(done)/\(task.subtasks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let minutes = task.timeMinutes, !compactView {
                Text(Self.timeLabel(minutes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { onEdit?() }
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
        // Completing (or reopening) a task adds/removes its pending reminder.
        Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
    }

    private func delete() {
        context.delete(task)
        try? context.save()
        // Drop any pending reminder for the deleted task.
        Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
    }

    /// 24-hour "HH:mm" from minutes-since-midnight.
    static func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
