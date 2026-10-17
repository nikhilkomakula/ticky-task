import SwiftUI
import SwiftData
import Charts

/// A board's Timeline (design 01 §5): one bar per dated card, grouped by person, from its
/// start to its due date; a card with only one date is a one-day bar. Uses the board's
/// filters and Show Archived.
struct KanbanTimelineView: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true

    struct Bar: Identifiable {
        let id: UUID
        let title: String
        let person: String
        let start: Date
        let end: Date
        let column: String
        let columnID: UUID
        let overdue: Bool
    }

    var body: some View {
        let _ = app.kanbanClock   // today's marker and date filters roll over at midnight
        let calendar = KanbanUI.calendar(weekStartsMonday: weekStartsMonday)
        let state = KanbanBoardState.decode(project.boardState)
        let people = KanbanUI.uniqueNames(project.resources.filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
            .map { ($0.id, $0.displayName) })
        let today = calendar.startOfDay(for: Date())
        let cards = project.tasks.filter { (state.showArchived || $0.archivedAt == nil) && state.filter.matches($0, calendar: calendar) }
        let bars: [Bar] = cards.compactMap { task in
            guard let first = task.startDate ?? task.dueDate else { return nil }
            let a = calendar.startOfDay(for: first), b = calendar.startOfDay(for: task.dueDate ?? first)
            let end = calendar.date(byAdding: .day, value: 1, to: max(a, b)) ?? max(a, b)
            let open = task.column?.kind != .done
            return Bar(id: task.id, title: task.title, person: task.resource.flatMap { people[$0.id] } ?? "Unassigned",
                       start: min(a, b), end: end, column: task.column?.name ?? "", columnID: task.column?.id ?? UUID(),
                       overdue: open && (task.dueDate.map { calendar.startOfDay(for: $0) < today } ?? false))
        }
        .sorted { ($0.person, $0.start) < ($1.person, $1.start) }
        let undated = cards.count - bars.count

        // Build column style map for colouring bars.
        // By column id: two columns may share a name.
        let columnStyleMap = Dictionary(project.orderedColumns.map { column in
            (column.id, KanbanColumnStyle(column).effectiveAccent)
        }, uniquingKeysWith: { a, _ in a })

        VStack(alignment: .leading, spacing: 8) {
            if bars.isEmpty {
                ContentUnavailableView("Nothing scheduled", systemImage: "calendar",
                                       description: Text("Give cards a start or due date to see them here."))
            } else {
                ScrollView(.vertical) {
                Chart {
                    RuleMark(x: .value("Today", today)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [3, 3]))
                    ForEach(bars) { bar in
                        BarMark(xStart: .value("Start", bar.start), xEnd: .value("End", bar.end), y: .value("Resource", bar.person))
                            .foregroundStyle(columnStyleMap[bar.columnID] ?? .gray)
                            .opacity(bar.overdue ? 1 : 0.85)
                            .annotation(position: .overlay, alignment: .leading) {
                                Text(bar.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    // A native surface under the title, so it reads on any column colour.
                                    .background(RoundedRectangle(cornerRadius: 2).fill(.regularMaterial))
                            }
                            .accessibilityLabel(bar.title)
                            .accessibilityValue("\(bar.person), \(bar.start.formatted(date: .abbreviated, time: .omitted)) to \(bar.end.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear)) }
                .frame(height: CGFloat(Set(bars.map(\.person)).count) * 44 + 40)
                .padding(12)
                }
            }
            if undated > 0 {
                Text("\(undated) card\(undated == 1 ? "" : "s") without dates not shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("kanban-timeline")
    }
}
