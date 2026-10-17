import SwiftUI

/// All projects: a card per board, and a People tab that adds each person up across
/// every board they're on (design 01 §5, 02 §1 (3b)).
struct KanbanAllProjectsView: View {
    let projects: [KanbanProject]
    @Environment(AppState.self) private var app
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @State private var tab = Tab.boards

    enum Tab: String, CaseIterable { case boards = "Boards", people = "People" }

    var body: some View {
        let calendar = KanbanUI.calendar(weekStartsMonday: weekStartsMonday)
        let key = app.kanbanMetricsKey(weekStartsMonday: weekStartsMonday)
        let live = projects.filter { $0.archivedAt == nil }
        let snapshots = live.map { app.kanbanMetrics.snapshot(of: $0, key: key, calendar: calendar) }
        VStack(alignment: .leading, spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(12)
            .accessibilityIdentifier("kanban-all-tabs")
            Divider()
            if live.isEmpty {
                ContentUnavailableView("No boards yet", systemImage: "square.grid.3x2",
                                       description: Text("Create one with New board in the sidebar."))
            } else {
                switch tab {
                case .boards: boards(zip(live, snapshots).map { ($0, $1) })
                case .people: people(KanbanMetrics.peopleRollup(snapshots), snapshots: snapshots)
                }
            }
        }
    }

    private func boards(_ entries: [(KanbanProject, MetricsSnapshot)]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(entries, id: \.0.id) { project, snapshot in
                    let summary = KanbanMetrics.summary(snapshot)
                    Button { app.kanban.selection = .project(project.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: project.symbolName).foregroundStyle(KanbanUI.color(project.colorHex) ?? .accentColor)
                                    .accessibilityHidden(true)
                                Text(project.name).font(.headline)
                                Spacer()
                            }
                            Label(KanbanUI.loadText(load: summary.load, target: summary.target, utilisation: summary.utilisation,
                                                    hours: snapshot.loadMeasure == .hours),
                                  systemImage: "gauge.medium")
                                .foregroundStyle(KanbanUI.bandColor(summary.utilisation.band))
                            Text("\(summary.openCards) open · \(summary.doneCards) done")
                            HStack(spacing: 10) {
                                if summary.overdue > 0 { Label("\(summary.overdue) overdue", systemImage: "calendar").foregroundStyle(.red) }
                                if summary.rollingOffWithin30Days > 0 {
                                    Label("\(summary.rollingOffWithin30Days) rolling off", systemImage: "calendar.badge.exclamationmark")
                                        .foregroundStyle(.orange)
                                }
                                if summary.membersOverCapacity > 0 {
                                    Label("\(summary.membersOverCapacity) over capacity", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                            .font(.caption)
                        }
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("kanban-project-card-\(project.name)")
                }
            }
            .padding(12)
        }
    }

    private func people(_ rows: [KanbanMetrics.PersonRow], snapshots: [MetricsSnapshot]) -> some View {
        let hoursBoards = Set(snapshots.filter { $0.loadMeasure == .hours }.map(\.projectID))
        return List(rows, id: \.personID) { person in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(KanbanUI.utilisationColor(person.headline))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(person.name).font(.headline)
                    Text("\(person.totalAllocation)% allocated").foregroundStyle(person.overAllocated ? .red : .secondary)
                    if person.overAllocated {
                        Label("Over-allocated", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("kanban-overallocated-\(person.name)")
                    }
                    Spacer()
                    Text(combined(person)).monospacedDigit()
                }
                Text(person.boards.map { cell in
                    let unit = hoursBoards.contains(cell.projectID) ? "h" : ""
                    let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
                    return "\(cell.projectName): \(cell.row.load.formatted(format))/\((cell.row.target ?? 0).formatted(format))\(unit)"
                }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            // `.contain`, not `.combine`: a combined element drops the over-allocation badge's identifier.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kanban-person-\(person.name)")
        }
    }

    private func combined(_ person: KanbanMetrics.PersonRow) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        let count = "\(person.count.load.formatted(format))/\(person.count.target.formatted(format)) tasks"
        guard let hours = person.hours else { return count }
        return "\(hours.load.formatted(format))/\(hours.target.formatted(format))h · \(count)"
    }
}

/// Across every board: overdue, due soon, blocked, Critical, and unassigned High or
/// Critical cards, grouped by board. Clicking one opens the board on the card.
struct KanbanAttentionView: View {
    let projects: [KanbanProject]
    @Environment(AppState.self) private var app

    struct Item: Identifiable {
        let task: KanbanTask
        let reasons: [String]
        var id: UUID { task.id }
    }

    static func items(_ project: KanbanProject, now: Date = Date(), calendar: Calendar = .current) -> [Item] {
        let today = calendar.startOfDay(for: now)
        return project.tasks.compactMap { task -> Item? in
            guard task.archivedAt == nil, let column = task.column, column.kind != .done else { return nil }
            var reasons: [String] = []
            if let due = task.dueDate {
                let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day ?? 0
                if days < 0 { reasons.append("Overdue") } else if days <= project.dueSoonThresholdDays { reasons.append("Due soon") }
            }
            if task.isBlocked { reasons.append("Blocked") }
            if task.isCritical { reasons.append("Critical") }
            if task.resource == nil, task.isCritical || task.priority == TaskPriority.high.rawValue { reasons.append("Unassigned") }
            return reasons.isEmpty ? nil : Item(task: task, reasons: reasons)
        }
        .sorted { ($0.task.resource?.displayName ?? "", $0.task.dueDate ?? .distantFuture, $0.task.title)
            < ($1.task.resource?.displayName ?? "", $1.task.dueDate ?? .distantFuture, $1.task.title) }
    }

    var body: some View {
        let _ = app.kanbanClock   // recompute at midnight and on a time-zone change
        let groups = projects.map { ($0, Self.items($0)) }.filter { !$0.1.isEmpty }
        if groups.isEmpty {
            ContentUnavailableView("Nothing needs attention", systemImage: "checkmark.circle",
                                   description: Text("No overdue, blocked or unassigned urgent cards."))
        } else {
            List {
                ForEach(groups, id: \.0.id) { project, items in
                    Section(project.name) {
                        // Grouped by person within each board (design 01 §5).
                        let byPerson = Dictionary(grouping: items) { $0.task.resource?.id }
                        let labels = KanbanUI.uniqueNames(project.resources.sorted { $0.sortIndex < $1.sortIndex }.map { ($0.id, $0.displayName) })
                        let order = byPerson.keys.sorted { (labels[$0 ?? UUID()] ?? "") < (labels[$1 ?? UUID()] ?? "") }
                        ForEach(order, id: \.self) { person in
                            Text(person.flatMap { labels[$0] } ?? "Unassigned").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(byPerson[person] ?? []) { item in
                            Button { app.revealKanban(taskID: item.task.id, projectID: project.id) } label: {
                                HStack {
                                    Text(item.task.title)
                                    Spacer()
                                    Text(item.task.resource?.displayName ?? "Unassigned").foregroundStyle(.secondary)
                                    Text(item.reasons.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(item.reasons.contains("Overdue") || item.reasons.contains("Blocked") ? .red : .orange)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("kanban-attention-\(item.task.title)")
                            }
                        }
                    }
                }
            }
        }
    }
}
