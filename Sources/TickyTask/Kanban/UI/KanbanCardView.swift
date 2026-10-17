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
    @Environment(\.colorScheme) private var colorScheme

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

    /// What the combined card element says beyond what's visible: the blocked reason and what
    /// it depends on.
    private var spokenDetails: String {
        var parts: [String] = []
        if task.isBlocked, let reason = task.blockedReason, !reason.isEmpty { parts.append("Blocked: \(reason)") }
        if !task.dependsOn.isEmpty { parts.append("Depends on \(task.dependsOn.map(\.title).joined(separator: ", "))") }
        return parts.joined(separator: ", ")
    }

    private var cardContent: some View {
        let highlighted = app.highlightedKanbanTaskID == task.id

        // One spacing scale (4 / 6 / 8): 8 around the content, 6 between title, tags and
        // markers (4 in compact view); empty sections take no space.
        return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            title
            if !task.labels.isEmpty { labels }
            metadata
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanbanCardFill(highlighted: highlighted, shape: RoundedRectangle(cornerRadius: 6)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(highlighted || isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                lineWidth: highlighted || isSelected ? 2 : 1))
        .onTapGesture(perform: onOpen)
    }

    /// The Critical flag and the priority glyph (as in the planner) sit on the title's first line.
    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if task.isCritical {
                Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(KanbanCardPalette.red)
                    .help("Critical")
                    .accessibilityLabel("Critical")
            }
            Image(systemName: priority.symbol).font(.system(size: 10)).foregroundStyle(KanbanCardPalette.priority(priority))
                .help("\(priority.label) priority")
                .accessibilityLabel("\(priority.label) priority")
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)   // the full title, wrapped
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(task.title)   // what the hover buttons cover, while they show
        }
        // As tall as the hover buttons, so they line up with a one-line title.
        .frame(minHeight: 24, alignment: .leading)
    }

    /// Every label as a small tag in its colour, wrapping onto more lines as needed.
    private var labels: some View {
        let dark = colorScheme == .dark
        return FlowLayout(spacing: 4) {
            ForEach(task.labels.sorted { $0.sortIndex < $1.sortIndex }) { label in
                let color = KanbanUI.color(label.colorHex) ?? .gray
                Text(label.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)   // a very long name wraps inside its tag
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)   // off the 4 / 6 / 8 scale on purpose: tags read smaller than the title
                    .background(Capsule().fill(color.opacity(dark ? 0.2 : 0.12)))
                    .overlay(Capsule().strokeBorder(color.opacity(dark ? 0.4 : 0.3), lineWidth: 0.5))
                    .help("Label")
            }
        }
    }

    /// Only what's set, right-aligned below the title and tags: due, estimate, Jira, blocked,
    /// dependencies, notes, steps. A marker that doesn't fit moves to the next line whole.
    @ViewBuilder
    private var metadata: some View {
        let subtasks = task.subtasks
        let hasAny = task.dueDate != nil || task.isBlocked || !task.dependsOn.isEmpty || task.jiraKey != nil
            || task.hasNotes || !subtasks.isEmpty || (project.loadMeasure == .hours && task.estimateHours != nil)
        if hasAny {
            FlowLayout(spacing: 8, lineSpacing: 4, trailing: true) {
                if let due = task.dueDate { dueLabel(due) }
                if project.loadMeasure == .hours, let hours = task.estimateHours {
                    Text("\(hours.formatted(.number.precision(.fractionLength(0...1))))h").monospacedDigit()
                        .help("Estimate")
                }
                if let key = task.jiraKey { jiraChip(key) }
                if task.isBlocked {
                    Image(systemName: "hand.raised.fill").foregroundStyle(KanbanCardPalette.red)
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
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
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
        let color: Color = isOverdue ? KanbanCardPalette.red : isDueSoon ? KanbanCardPalette.amber : .secondary
        let helpText = isOverdue ? "Overdue" : isDueSoon ? "Due soon" : "Due date"
        let icon = isOverdue ? "exclamationmark.circle.fill" : isDueSoon ? "clock.fill" : "calendar"
        // The date stays primary; only the glyph carries the warning colour.
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
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
    var highlighted = false
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var target: Target?

    private enum Target { case edit, delete }

    var body: some View {
        HStack(spacing: 4) {
            button("pencil", .edit, help: "Edit card", id: "kanban-card-edit-\(task.id)", action: onEdit)
            button("trash", .delete, help: "Delete card", id: "kanban-card-delete-\(task.id)", action: onDelete)
        }
        .background(alignment: .leading) {
            // Native backing with a short leading fade, so a long title fades out under the buttons.
            // The card's own fill (highlight included), so the backing never shows as a patch.
            KanbanCardFill(highlighted: highlighted, shape: RoundedRectangle(cornerRadius: 4))
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 12)
                        Color.black
                    }
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
                .frame(width: 24, height: 24)
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

/// Warning colours that keep their contrast on the card in light and dark appearance.
enum KanbanCardPalette {
    static let red = adaptive(light: "#B42318", dark: "#FF8A80")
    static let amber = adaptive(light: "#8A4B00", dark: "#F6C66A")

    /// The planner's priority colours, adjusted to 3:1 or more on the card in either appearance.
    static func priority(_ priority: TaskPriority) -> Color {
        switch priority {
        case .low: lowPriority
        case .medium: mediumPriority
        case .high: highPriority
        }
    }
    private static let lowPriority = KanbanContrast.accent("#34C759")
    private static let mediumPriority = KanbanContrast.accent("#FF9500")
    private static let highPriority = KanbanContrast.accent("#FF3B30")

    private static func adaptive(light: String, dark: String) -> Color {
        let light = NSColor(Color(hex: light) ?? .red), dark = NSColor(Color(hex: dark) ?? .red)
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

/// A card's background: the native control colour, tinted while a reveal highlights it.
struct KanbanCardFill<S: Shape>: View {
    let highlighted: Bool
    let shape: S

    var body: some View {
        shape.fill(Color(nsColor: .controlBackgroundColor))
            .overlay { if highlighted { shape.fill(Color.accentColor.opacity(0.18)) } }
    }
}
