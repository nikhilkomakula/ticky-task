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
        // the drag gesture; the reserved space in the title row keeps them off the text.
        cardContent
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .animation(.easeInOut(duration: 0.2), value: highlighted)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Edit", onOpen)
        .accessibilityAction(named: "Delete") { onDelete?() }
        .accessibilityIdentifier("kanban-card-\(task.title)")
    }

    private var cardContent: some View {
        let highlighted = app.highlightedKanbanTaskID == task.id

        return VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if task.isCritical {
                    Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(.red)
                        .help("Critical")
                        .accessibilityLabel("Critical")
                }
                Image(systemName: priority.symbol).font(.system(size: 11)).foregroundStyle(priority.tint)
                    .help(priority.label.lowercased() == "low" ? "Low priority" : priority.label.lowercased() == "medium" ? "Medium priority" : "High priority")
                    .accessibilityLabel("\(priority.label) priority")
                Text(task.title)
                    .font(.system(size: 13))
                    .lineLimit(compact ? 2 : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Reserve 52pt for hover buttons (not visible, just space)
                if !isInDragPreview {
                    Color.clear.frame(width: 52, height: 22)
                }
            }
            if !task.labels.isEmpty { labels }
            metadata
        }
        .padding(.vertical, compact ? 4 : 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(highlighted || isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                                                lineWidth: highlighted || isSelected ? 2 : 1))
        .onTapGesture(perform: onOpen)
    }

    private var labels: some View {
        HStack(spacing: 4) {
            ForEach(task.labels.sorted { $0.sortIndex < $1.sortIndex }) { label in
                Text(label.name)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill((KanbanUI.color(label.colorHex) ?? .gray).opacity(0.22)))
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var metadata: some View {
        let subtasks = task.subtasks
        let hasAny = task.dueDate != nil || task.isBlocked || !task.dependsOn.isEmpty || task.jiraKey != nil
            || task.hasNotes || !subtasks.isEmpty || (project.loadMeasure == .hours && task.estimateHours != nil)
        if hasAny {
            HStack(spacing: 6) {
                if let due = task.dueDate { dueLabel(due) }
                if project.loadMeasure == .hours, let hours = task.estimateHours {
                    Text("\(hours.formatted(.number.precision(.fractionLength(0...1))))h").monospacedDigit()
                }
                if let key = task.jiraKey { jiraChip(key) }
                if task.isBlocked {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                        .help("Blocked")
                        .accessibilityLabel("Blocked")
                        .accessibilityValue(task.blockedReason ?? "")
                }
                if !task.dependsOn.isEmpty {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                        .help("Dependencies")
                        .accessibilityLabel("Has dependencies")
                        .accessibilityValue(task.dependsOn.map(\.title).joined(separator: ", "))
                }
                Spacer(minLength: 0)
                if task.hasNotes {
                    Image(systemName: "note.text").foregroundStyle(.secondary)
                        .help("Notes")
                        .accessibilityLabel("Has notes")
                        .accessibilityIdentifier("kanban-notes-\(task.id)")
                }
                if !subtasks.isEmpty {
                    Text("\(subtasks.filter(\.isDone).count)/\(subtasks.count)")
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(.quaternary))
                        .help("Steps")
                        .accessibilityLabel("\(subtasks.filter(\.isDone).count) of \(subtasks.count) steps done")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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
        return Label(due.formatted(.dateTime.month(.abbreviated).day()), systemImage: icon)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .help(helpText)
            .accessibilityLabel(isOverdue ? "Overdue, due \(due.formatted(date: .abbreviated, time: .omitted))"
                                : "Due \(due.formatted(date: .abbreviated, time: .omitted))")
    }

    private func jiraChip(_ key: String) -> some View {
        Button {
            if let text = task.jiraURL, let url = URL(string: text.trimmingCharacters(in: .whitespaces)) { NSWorkspace.shared.open(url) }
        } label: {
            Text(key).font(.caption2.monospaced())
                .padding(.horizontal, 4)
                .background(Capsule().strokeBorder(.secondary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help("Open Jira")
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

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onEdit) { Image(systemName: "pencil").font(.system(size: 11)) }
                .help("Edit card")
                .accessibilityLabel("Edit card")
                .accessibilityIdentifier("kanban-card-edit-\(task.id)")
            Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 11)) }
                .help("Delete card")
                .accessibilityLabel("Delete card")
                .accessibilityIdentifier("kanban-card-delete-\(task.id)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
