import SwiftUI
import AppKit

/// A board card, in the planner row's visual language (design 01 §5): Critical flag,
/// priority glyph, title, then labels, due date, estimate, Jira key, blocked and
/// dependency glyphs, notes and the subtask count.
struct KanbanCardView: View {
    let task: KanbanTask
    let project: KanbanProject
    var isSelected = false
    var onOpen: () -> Void = {}
    @Environment(AppState.self) private var app
    @AppStorage("compactView") private var compact = false

    private var priority: TaskPriority { TaskPriority(rawValue: min(max(task.priority, 0), 2)) ?? .low }

    var body: some View {
        let _ = app.kanbanClock   // due-date colours follow the day
        let highlighted = app.highlightedKanbanTaskID == task.id
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if task.isCritical {
                    Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(.red)
                        .accessibilityLabel("Critical")
                }
                Image(systemName: priority.symbol).font(.system(size: 11)).foregroundStyle(priority.tint)
                    .accessibilityLabel("\(priority.label) priority")
                Text(task.title)
                    .font(.system(size: 13))
                    .lineLimit(compact ? 2 : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !task.labels.isEmpty { labels }
            metadata
        }
        .padding(.vertical, compact ? 4 : 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(highlighted || isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                                                lineWidth: highlighted || isSelected ? 2 : 1))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeInOut(duration: 0.2), value: highlighted)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Edit", onOpen)
        .accessibilityIdentifier("kanban-card-\(task.title)")
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
            || !task.notes.isEmpty || !subtasks.isEmpty || (project.loadMeasure == .hours && task.estimateHours != nil)
        if hasAny {
            HStack(spacing: 6) {
                if let due = task.dueDate { dueLabel(due) }
                if project.loadMeasure == .hours, let hours = task.estimateHours {
                    Text("\(hours.formatted(.number.precision(.fractionLength(0...1))))h").monospacedDigit()
                }
                if let key = task.jiraKey { jiraChip(key) }
                if task.isBlocked {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                        .help(task.blockedReason.map { "Blocked: \($0)" } ?? "Blocked")
                        .accessibilityLabel("Blocked")
                }
                if !task.dependsOn.isEmpty {
                    Image(systemName: "link").help("Depends on \(task.dependsOn.map(\.title).joined(separator: ", "))")
                        .accessibilityLabel("Has dependencies")
                }
                Spacer(minLength: 0)
                if !task.notes.isEmpty {
                    Image(systemName: "note.text").accessibilityLabel("Has notes")
                }
                if !subtasks.isEmpty {
                    Text("\(subtasks.filter(\.isDone).count)/\(subtasks.count)")
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(.quaternary))
                        .accessibilityLabel("\(subtasks.filter(\.isDone).count) of \(subtasks.count) subtasks done")
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
        let color: Color = !open ? .secondary : days < 0 ? .red : days <= project.dueSoonThresholdDays ? .orange : .secondary
        return Label(due.formatted(.dateTime.month(.abbreviated).day()), systemImage: "calendar")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .accessibilityLabel(open && days < 0 ? "Overdue, due \(due.formatted(date: .abbreviated, time: .omitted))"
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
        .help("Open \(key) in Jira")
        .accessibilityLabel("Jira issue \(key)")
        .accessibilityAddTraits(.isButton)
    }
}
