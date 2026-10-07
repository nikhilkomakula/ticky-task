import SwiftUI
import SwiftData

/// A single task row: completion toggle, priority glyph, title, and trailing
/// metadata (subtask badge, alarm, time). Hover-highlighted; tap to edit.
struct TaskRowView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @AppStorage("compactView") private var compactView = false
    let task: TaskItem
    var onEdit: (() -> Void)? = nil

    @State private var isHovering = false
    /// Shown when deleting a recurring task, to pick this occurrence vs the series.
    @State private var isConfirmingDelete = false

    /// Flashed briefly when a search result jumps to this row.
    private var isHighlighted: Bool { app.highlightedTaskID == task.id }

    private var rowFill: Color {
        if isHighlighted { return Color.accentColor.opacity(0.18) }
        return isHovering ? Color.primary.opacity(0.075) : Color.primary.opacity(0.035)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: toggleDone) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(task.isDone ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 20)

            // The priority glyphs, title, and trailing metadata share the title's
            // first-line baseline, so the smaller Critical flag + priority icons sit
            // ON the first line of the (possibly wrapping) title instead of being
            // top-pinned and floating above it.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(spacing: 3) {
                    if task.isCritical {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Critical")
                    }
                    Image(systemName: task.priorityLevel.symbol)
                        .foregroundStyle(task.priorityLevel.tint)
                        .accessibilityLabel("\(task.priorityLevel.label) priority")
                    if task.isRecurring {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Repeats")
                    }
                }
                .font(.system(size: 11))

                Text(task.title.isEmpty ? "Untitled" : task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    // Always wrap to the available column width (week columns, day
                    // agenda, and custom lists all use this row). `maxWidth` bounds the
                    // width so the title wraps instead of claiming its full single-line
                    // width; `fixedSize(vertical:)` lets the wrapped title grow the row
                    // height instead of being clipped to one line.
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if task.hasNotes {
                    Image(systemName: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("Has notes")
                        .accessibilityIdentifier("notesIcon")
                }

                if !task.subtasks.isEmpty {
                    let done = task.subtasks.filter(\.isDone).count
                    Text("\(done)/\(task.subtasks.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                }

                if task.alarmEnabled {
                    Image(systemName: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let minutes = task.timeMinutes, !compactView {
                    Text(Self.timeLabel(minutes))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        // Keep the time at its intrinsic width so it never compresses
                        // and wraps vertically; the title (layoutPriority 1) wraps instead.
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compactView ? 4 : 6)
        .background(
            rowFill,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Edit/Delete float over the trailing metadata on hover, so the row never
        // reflows and the title keeps its full width when not hovering. Real
        // Buttons consume the click, so the row's tap-to-edit never double-fires.
        .overlay(alignment: .trailing) {
            if isHovering {
                HStack(spacing: 2) {
                    Button { onEdit?() } label: { Image(systemName: "pencil") }
                        .help("Edit task")
                    Button(role: .destructive, action: requestDelete) { Image(systemName: "trash") }
                        .help("Delete task")
                        .accessibilityIdentifier("row-delete")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(.trailing, 6)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
        .onTapGesture { onEdit?() }
        .help("Edit task")
        .contextMenu {
            Button(task.isDone ? "Mark as not done" : "Mark as done", action: toggleDone)
            if onEdit != nil { Button("Edit…") { onEdit?() } }
            Divider()
            Button("Delete", role: .destructive, action: requestDelete)
                .accessibilityIdentifier("context-delete")
        }
        .confirmationDialog("This task repeats.", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete This Occurrence", role: .destructive) { deleteThisOccurrence() }
            Button("Delete the Whole Series", role: .destructive) { deleteSeries() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete just this day, or every occurrence of the series?")
        }
        .accessibilityIdentifier("taskRow-\(task.title.isEmpty ? "Untitled" : task.title)")
    }

    private func toggleDone() {
        task.setDone(!task.isDone)
        try? context.save()
        Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
    }

    /// Recurring tasks ask this-occurrence vs whole-series; others delete at once.
    private func requestDelete() {
        if task.isRecurring {
            isConfirmingDelete = true
        } else {
            context.delete(task)
            try? context.save()
            resyncReminders()
        }
    }

    private func deleteThisOccurrence() {
        try? RecurrenceMaterializer.deleteOccurrence(task, context: context)
        resyncReminders()
    }

    private func deleteSeries() {
        try? RecurrenceMaterializer.deleteSeries(task, context: context)
        resyncReminders()
    }

    private func resyncReminders() {
        Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
    }

    /// 24-hour "HH:mm" from minutes-since-midnight.
    static func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
