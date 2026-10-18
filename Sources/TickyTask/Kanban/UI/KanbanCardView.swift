import SwiftUI
import AppKit
import SwiftData

/// A board card, in the planner row's visual language (design 01 §5): Critical flag,
/// priority glyph, title, then labels and an icon for each piece of information that's set
/// (dates, estimate, complexity, Jira, blocked, dependencies, notes, steps, archived).
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
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Edit", onOpen)
        .accessibilityAction(named: "Delete") { onDelete?() }
        .accessibilityIdentifier("kanban-card-\(task.title)")
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
                    .font(.system(size: 9))   // for information only: as small as stays legible
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)   // a very long name wraps inside its tag
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)   // off the 4 / 6 / 8 scale on purpose: tags read smaller than the title
                    .background(Capsule().fill(color.opacity(dark ? 0.2 : 0.12)))
                    .overlay(Capsule().strokeBorder(color.opacity(dark ? 0.4 : 0.3), lineWidth: 0.5))
                    .help(label.name)   // the full name, for when the small type is hard to read
            }
        }
    }

    /// Only what's set, right-aligned below the title and tags, risks first so a reviewer sees
    /// them at once: blocked, overdue, waiting on prerequisites, due, a start still to come,
    /// estimate, complexity, steps, Jira, notes, archived (design agreed with Codex). Risks and
    /// dates say what they are in words; a marker that doesn't fit moves to the next line whole.
    @ViewBuilder
    private var metadata: some View {
        let subtasks = task.subtasks
        let complexity = task.complexity.flatMap(KanbanComplexity.init(rawValue:))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // A finished or archived card raises no alerts and colours no dates.
        let live = task.archivedAt == nil && task.column?.kind != .done
        let futureStart = task.startDate.flatMap { live && calendar.startOfDay(for: $0) > today ? $0 : nil }
        // As the backlog reads readiness: a prerequisite counts once it's done and not archived.
        let waitingOn = live ? task.dependsOn.filter { $0.archivedAt != nil || $0.column?.kind != .done } : []
        let blocked = live && task.isBlocked
        let overdue = live && task.dueDate.map { calendar.startOfDay(for: $0) < today } == true
        let notes = task.hasNotes   // cache computed property to avoid double-eval
        let hasAny = blocked || task.dueDate != nil || !waitingOn.isEmpty || futureStart != nil || task.estimateHours != nil
            || complexity != nil || !subtasks.isEmpty || task.jiraKey != nil || notes || task.archivedAt != nil
        if hasAny {
            FlowLayout(spacing: 8, lineSpacing: 4, trailing: true) {
                if blocked {
                    let reason = task.blockedReason.flatMap { $0.isEmpty ? nil : $0 }
                    marker("hand.raised.fill", "Blocked", tint: KanbanCardPalette.red, spoken: reason.map { "Blocked: \($0)." } ?? "Blocked.")
                }
                // Overdue is a risk and goes before Waiting; any other due date after it.
                if let due = task.dueDate, overdue { dueLabel(due, live: live) }
                if !waitingOn.isEmpty { waitingLabel(waitingOn) }
                if let due = task.dueDate, !overdue { dueLabel(due, live: live) }
                if let start = futureStart {
                    marker("calendar.badge.clock", "Start \(start.formatted(.dateTime.month(.abbreviated).day()))",
                           spoken: "Starts \(start.formatted(date: .long, time: .omitted)).")
                }
                if let hours = task.estimateHours {
                    let amount = hours.formatted(.number.precision(.fractionLength(0...1)))
                    marker("timer", "\(amount)h", spoken: "Estimated effort: \(amount) \(hours == 1 ? "hour" : "hours").")
                }
                if let complexity {
                    // Bars filled to the level, as a signal meter reads.
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "cellularbars", variableValue: complexity.barsFilled)
                        Text(complexity.shortLabel)
                    }
                        .help("Complexity: \(complexity.label).")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Complexity: \(complexity.label).")
                }
                if !subtasks.isEmpty {
                    let done = subtasks.filter(\.isDone).count
                    marker("checklist", "\(done)/\(subtasks.count)", spoken: "\(done) of \(subtasks.count) steps complete.")
                }
                if let key = task.jiraKey { jiraChip(key) }
                if notes {
                    Image(systemName: "note.text")
                        .help("Has notes.")
                        .accessibilityLabel("Has notes")
                        .accessibilityIdentifier("kanban-notes-\(task.id)")
                }
                if task.archivedAt != nil {
                    Image(systemName: "archivebox")
                        .help("Archived.")
                        .accessibilityLabel("Archived")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Red "Overdue 2d" when past due, amber "Due today" / "Due Oct 20" within the board's
    /// threshold, otherwise "Due Oct 28"; by calendar day, and never coloured once finished.
    private func dueLabel(_ due: Date, live: Bool) -> some View {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: due)).day ?? 0
        let isOverdue = live && days < 0
        let isDueSoon = live && days >= 0 && days <= project.dueSoonThresholdDays
        let long = due.formatted(date: .long, time: .omitted)
        let text = isOverdue ? "Overdue \(-days)d" : days == 0 && live ? "Due today" : "Due \(due.formatted(.dateTime.month(.abbreviated).day()))"
        let spoken = isOverdue ? "Overdue by \(-days) \(days == -1 ? "day" : "days"). Due \(long)."
            : isDueSoon ? "Due soon. Due \(long)." : "Due \(long)."
        return marker(isOverdue ? "exclamationmark.circle.fill" : isDueSoon ? "clock.fill" : "calendar", text,
                      tint: isOverdue ? KanbanCardPalette.red : isDueSoon ? KanbanCardPalette.amber : nil, spoken: spoken)
    }

    /// Amber "Waiting on n" while prerequisites are open or archived; the tooltip names them.
    private func waitingLabel(_ waitingOn: [KanbanTask]) -> some View {
        let open = waitingOn.filter { $0.archivedAt == nil }.map(\.title)
        let archived = waitingOn.filter { $0.archivedAt != nil }.map(\.title)
        var names = open
        if !archived.isEmpty { names.append("archived: \(archived.joined(separator: ", "))") }
        let noun = task.dependsOn.count == 1 ? "prerequisite" : "prerequisites"
        return marker("arrow.triangle.branch", "Waiting on \(waitingOn.count)", tint: KanbanCardPalette.amber,
                      spoken: "Waiting on \(waitingOn.count) of \(task.dependsOn.count) \(noun): \(names.joined(separator: "; ")).")
    }

    /// An icon and its short text, with one spoken label (also the tooltip). A tinted marker is
    /// a warning: its glyph takes the colour and its words read in the primary colour.
    private func marker(_ symbol: String, _ text: String, tint: Color? = nil, spoken: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            Text(text).monospacedDigit().foregroundStyle(tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .help(spoken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func jiraChip(_ key: String) -> some View {
        Button {
            if let text = task.jiraURL, let url = URL(string: text.trimmingCharacters(in: .whitespaces)) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "link")
                Text(key).font(.system(size: 11).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 80)
            }
        }
        .buttonStyle(.plain)
        .help("Open Jira issue \(key).")
        .accessibilityLabel("Open Jira issue \(key)")
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
