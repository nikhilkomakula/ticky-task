import SwiftUI
import AppKit
import SwiftData

/// A board card, in the planner row's visual language (design 01 §5): Critical flag,
/// priority glyph, title, then labels, due date, estimate, Jira key, blocked and
/// dependency glyphs, notes and the subtask count.
struct KanbanCardView: View {
    let task: KanbanTask
    let project: KanbanProject
    var isSelected = false
    var onOpen: () -> Void = {}
    var onDelete: (() -> Void)? = nil
    var isInDragPreview: Bool = false
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage("compactView") private var compact = false

    private var priority: TaskPriority { TaskPriority(rawValue: min(max(task.priority, 0), 2)) ?? .low }

    var body: some View {
        let _ = app.kanbanClock   // due-date colours follow the day
        let highlighted = app.highlightedKanbanTaskID == task.id

        // The Edit/Delete buttons are overlaid by the board's cell (KanbanCardSlot), outside
        // the drag gesture, only while hovered or focused.
        cardContent
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .animation(.easeInOut(duration: 0.2), value: highlighted)
        .accessibilityElement(children: .combine)
        .accessibilityValue(spokenDetails)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Edit", onOpen)
        .accessibilityAction(named: "Delete") { onDelete?() }
        .accessibilityIdentifier("kanban-card-\(task.title)")
    }

    /// What the combined card element says beyond what's visible: the hidden Low priority,
    /// the blocked reason and what it depends on.
    private var spokenDetails: String {
        var parts: [String] = []
        if priority == .low { parts.append("Low priority") }
        if task.isBlocked, let reason = task.blockedReason, !reason.isEmpty { parts.append("Blocked: \(reason)") }
        if !task.dependsOn.isEmpty { parts.append("Depends on \(task.dependsOn.map(\.title).joined(separator: ", "))") }
        return parts.joined(separator: ", ")
    }

    private var cardContent: some View {
        let highlighted = app.highlightedKanbanTaskID == task.id

        return VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if task.isCritical {
                    Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(.red)
                        .help("Critical")
                        .accessibilityLabel("Critical")
                }
                // Low is the default, so it shows nothing (it's still in the spoken summary).
                if priority != .low {
                    Image(systemName: priority.symbol).font(.system(size: 10)).foregroundStyle(priority.tint)
                        .help("\(priority.label) priority")
                        .accessibilityLabel("\(priority.label) priority")
                }
                Text(task.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)   // the full title, wrapped
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 22, alignment: .leading)
            if !task.labels.isEmpty { labels }
            metadata
        }
        .padding(.vertical, compact ? 4 : 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(highlighted || isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                lineWidth: highlighted || isSelected ? 2 : 1))
        .onTapGesture(perform: onOpen)
    }

    /// Every label as a small tag in its colour, wrapping onto more lines as needed.
    private var labels: some View {
        FlowLayout(spacing: 4) {
            ForEach(task.labels.sorted { $0.sortIndex < $1.sortIndex }) { label in
                let color = KanbanUI.color(label.colorHex) ?? .gray
                Text(label.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)   // a very long name wraps inside its tag
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(0.2)))
                    .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.5))
                    .help("Label")
            }
        }
    }

    /// One quiet row, only what's set: due, estimate, Jira, blocked, dependencies, notes, steps.
    @ViewBuilder
    private var metadata: some View {
        let subtasks = task.subtasks
        let hasAny = task.dueDate != nil || task.isBlocked || !task.dependsOn.isEmpty || task.jiraKey != nil
            || task.hasNotes || !subtasks.isEmpty || (project.loadMeasure == .hours && task.estimateHours != nil)
        if hasAny {
            // Right-aligned lines; a marker that doesn't fit moves to the next line whole.
            FlowLayout(spacing: 4, trailing: true) {
                if let due = task.dueDate { dueLabel(due) }
                if project.loadMeasure == .hours, let hours = task.estimateHours {
                    Text("\(hours.formatted(.number.precision(.fractionLength(0...1))))h").monospacedDigit()
                        .help("Estimate")
                }
                if let key = task.jiraKey { jiraChip(key) }
                if task.isBlocked {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                        .help("Blocked")
                        .accessibilityLabel("Blocked")
                        .accessibilityValue(task.blockedReason ?? "")
                }
                if !task.dependsOn.isEmpty {
                    Image(systemName: "arrow.triangle.branch")
                        .help("Dependencies")
                        .accessibilityLabel("Has dependencies")
                        .accessibilityValue(task.dependsOn.map(\.title).joined(separator: ", "))
                }
                if task.hasNotes {
                    Image(systemName: "note.text")
                        .help("Notes")
                        .accessibilityLabel("Has notes")
                        .accessibilityIdentifier("kanban-notes-\(task.id)")
                }
                if !subtasks.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "checklist")
                        Text("\(subtasks.filter(\.isDone).count)/\(subtasks.count)").monospacedDigit()
                    }
                        .help("Subtasks")
                        .accessibilityLabel("\(subtasks.filter(\.isDone).count) of \(subtasks.count) steps done")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Red when overdue, amber when due within the board's threshold; by calendar day.
    private func dueLabel(_ due: Date) -> some View {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: due)).day ?? 0
        let open = task.column?.kind != .done
        let isOverdue = open && days < 0
        let isDueSoon = open && days >= 0 && days <= project.dueSoonThresholdDays
        let color: Color = isOverdue ? .red : isDueSoon ? .orange : .secondary
        let helpText = isOverdue ? "Overdue" : isDueSoon ? "Due soon" : "Due date"
        let icon = isOverdue ? "exclamationmark.circle.fill" : isDueSoon ? "clock.fill" : "calendar"
        // The date stays primary; only the glyph carries the warning colour.
        return HStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(color)
            Text(due.formatted(.dateTime.month(.abbreviated).day())).foregroundStyle(.primary)
        }
            .help(helpText)
            .accessibilityLabel(isOverdue ? "Overdue, due \(due.formatted(date: .abbreviated, time: .omitted))"
                                : "Due \(due.formatted(date: .abbreviated, time: .omitted))")
    }

    private func jiraChip(_ key: String) -> some View {
        Button {
            if let text = task.jiraURL, let url = URL(string: text.trimmingCharacters(in: .whitespaces)) { NSWorkspace.shared.open(url) }
        } label: {
            Text(key).font(.system(size: 11).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 80)
        }
        .buttonStyle(.plain)
        .help("Open Jira \(key)")
        .accessibilityLabel("Jira issue \(key)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Edit and Delete for a card, shown on hover or focus. The board overlays them on the card
/// after its drag gesture, so pressing them never starts a drag.
struct KanbanCardHoverActions: View {
    let task: KanbanTask
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var target: Target?

    private enum Target { case edit, delete }

    var body: some View {
        HStack(spacing: 4) {
            button("pencil", .edit, help: "Edit card", id: "kanban-card-edit-\(task.id)", action: onEdit)
            button("trash", .delete, help: "Delete card", id: "kanban-card-delete-\(task.id)", action: onDelete)
        }
        .padding(.horizontal, 2)
        .background(alignment: .leading) {
            // Native backing with a short leading fade, so a long title fades out under the buttons.
            HStack(spacing: 0) {
                LinearGradient(colors: [Color(nsColor: .controlBackgroundColor).opacity(0), Color(nsColor: .controlBackgroundColor)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor))
            }
            .padding(.leading, -12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func button(_ symbol: String, _ kind: Target, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(target == kind ? (kind == .delete ? AnyShapeStyle(.red) : AnyShapeStyle(.primary)) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(target == kind ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { target = $0 ? kind : (target == kind ? nil : target) }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
    }
}
