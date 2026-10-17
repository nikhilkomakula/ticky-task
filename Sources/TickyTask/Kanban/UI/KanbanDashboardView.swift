import SwiftUI
import SwiftData
import Charts

/// A board's dashboard (design 01 §6, formulas in 02-metrics.md): one card per chart, in
/// the design's order, each with an empty state and its numbers as text. Clicking a chart
/// that maps to a filter opens the board filtered to it.
struct KanbanDashboardView: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true

    var body: some View {
        let calendar = KanbanUI.calendar(weekStartsMonday: weekStartsMonday)
        let key = app.kanbanMetricsKey(weekStartsMonday: weekStartsMonday)
        let s = app.kanbanMetrics.snapshot(of: project, key: key, calendar: calendar)
        let log = app.kanbanMetrics.activities(of: project, key: key)
        let names = Dictionary(s.cards.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let columns = Dictionary(s.columns.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let members = Dictionary(s.members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 12, alignment: .top)], spacing: 12) {
                DashboardCard(title: "Load vs capacity", id: "load") { LoadChart(s: s) }
                DashboardCard(title: "Capacity, next 12 weeks", id: "heatmap") { HeatmapChart(s: s) }
                DashboardCard(title: "Tasks by column", id: "columns") { ColumnsChart(s: s) }
                DashboardCard(title: "Unassigned backlog", id: "backlog", action: { open { $0.unassigned = true } }) {
                    BacklogSummary(backlog: KanbanMetrics.unassignedBacklog(s), names: names, hours: s.loadMeasure == .hours)
                }
                DashboardCard(title: "Due dates", id: "due", action: { open { $0.due = .overdue } }) {
                    DueSummary(due: KanbanMetrics.dueBuckets(s), names: names)
                }
                DashboardCard(title: "Team", id: "composition") { CompositionSummary(c: KanbanMetrics.composition(s), members: members) }
                DashboardCard(title: "Priority by column", id: "priority") { PriorityGrid(s: s, columns: columns) }
                DashboardCard(title: "Tasks with label", id: "labels") { LabelMixChart(s: s, columns: columns, labels: labelNames) }
                DashboardCard(title: "Blocked", id: "blocked", action: { open { $0.blockedOnly = true } }) {
                    BlockedList(blocked: KanbanMetrics.blockedTasks(s), names: names)
                }
                DashboardCard(title: "Cumulative flow, 90 days", id: "cfd") { FlowChart(days: KanbanReplay.cfd(s, activities: log), hours: s.loadMeasure == .hours) }
                DashboardCard(title: "Completed work (by latest completion)", id: "throughput",
                              subtitle: "Reopened work moves out of earlier weeks") { ThroughputChart(weeks: KanbanReplay.throughput(s, activities: log)) }
                DashboardCard(title: "Age of work in progress", id: "aging") { AgingList(aging: KanbanReplay.agingWIP(s, activities: log), names: names, columns: columns) }
                DashboardCard(title: "Burn-up, 90 days", id: "burnup") { BurnUpChart(points: KanbanReplay.burnUp(s, activities: log), hours: s.loadMeasure == .hours) }
                DashboardCard(title: "Hygiene", id: "hygiene") { HygieneList(h: KanbanMetrics.hygieneReport(s), hours: s.loadMeasure == .hours) }
            }
            .padding(12)
        }
        .accessibilityIdentifier("kanban-dashboard")
    }

    private var labelNames: [UUID: String] {
        Dictionary(project.labels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Opens the board with a filter for what the chart shows.
    private func open(_ filter: (inout KanbanCardFilter) -> Void) {
        app.updateBoardState(project, context: context) { state in
            state.view = .board
            state.filter = KanbanCardFilter()
            filter(&state.filter)
        }
    }
}

// MARK: - Card

private struct DashboardCard<Content: View>: View {
    let title: String
    let id: String
    var subtitle: String?
    var action: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let action {
                    Button("Show on board", action: action)
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityIdentifier("kanban-dash-open-\(id)")
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban-dash-\(id)")
    }
}

private struct Empty: View {
    let text: String
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60) }
}

private let oneDecimal = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))

// MARK: - (1) Load vs capacity

private struct LoadChart: View {
    let s: MetricsSnapshot

    struct Bar: Identifiable {
        let id: String
        let member: String
        let column: String
        let load: Double
    }

    var body: some View {
        let rows = KanbanMetrics.loadVsCapacity(s).filter { $0.memberID != nil }
        let columns = Dictionary(s.columns.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let bars = rows.flatMap { row in
            row.segments.filter { $0.load > 0 }.map { Bar(id: "\(row.name)-\($0.column)", member: row.name, column: columns[$0.column] ?? "", load: $0.load) }
        }
        if rows.isEmpty {
            Empty(text: "Add people to the board to see their load.")
        } else {
            Chart(bars) { bar in
                BarMark(x: .value("Load", bar.load), y: .value("Person", bar.member))
                    .foregroundStyle(by: .value("Column", bar.column))
            }
            .frame(height: CGFloat(max(rows.count, 2)) * 28 + 30)
            ForEach(rows, id: \.name) { row in
                HStack {
                    Circle().fill(KanbanUI.utilisationColor(row.utilisation)).frame(width: 8, height: 8)
                    Text(row.name)
                    Spacer()
                    Text(KanbanUI.loadText(load: row.load, target: row.target, utilisation: row.utilisation, hours: s.loadMeasure == .hours))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let weeks = row.backlogCoverageWeeks {
                        Text("· backlog \(weeks.formatted(oneDecimal)) wk").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - (2) Heatmap

private struct HeatmapChart: View {
    let s: MetricsSnapshot

    struct Cell: Identifiable {
        let id: String
        let member: String
        let week: Date
        let value: Double?
        let band: KanbanMetrics.Band?
    }

    var body: some View {
        let rows = KanbanMetrics.capacityHeatmap(s, weeks: 12)
        let week0 = s.weekStart(s.today)
        let cells: [Cell] = rows.flatMap { row in
            row.weeks.enumerated().map { index, cell in
                let week = s.addDays(7 * index, to: week0)
                switch cell {
                case let .ratio(load, target, band): return Cell(id: "\(row.memberID)-\(index)", member: row.name, week: week, value: load / target, band: band)
                case .unavailable, .noCapacity: return Cell(id: "\(row.memberID)-\(index)", member: row.name, week: week, value: nil, band: nil)
                }
            }
        }
        if rows.isEmpty {
            Empty(text: "No people on this board yet.")
        } else {
            Chart(cells) { cell in
                RectangleMark(x: .value("Week", cell.week, unit: .weekOfYear), y: .value("Person", cell.member))
                    .foregroundStyle(cell.band.map { KanbanUI.bandColor($0) } ?? Color.gray.opacity(0.25))
                    .opacity(cell.value.map { min(max($0, 0.25), 1) } ?? 1)
                    .accessibilityLabel("\(cell.member), week of \(cell.week.formatted(.dateTime.month().day()))")
                    .accessibilityValue(cell.value.map { "\(Int(($0 * 100).rounded()))%" } ?? "not on the board")
            }
            .frame(height: CGFloat(max(rows.count, 2)) * 26 + 30)
        }
    }
}

// MARK: - (4) By column

private struct ColumnsChart: View {
    let s: MetricsSnapshot

    struct Bar: Identifiable {
        let id: UUID
        let name: String
        let count: Int
    }

    var body: some View {
        let names = Dictionary(s.columns.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let bars = KanbanMetrics.tasksByColumn(s).map { Bar(id: $0.column, name: names[$0.column] ?? "", count: $0.count) }
        if bars.allSatisfy({ $0.count == 0 }) {
            Empty(text: "No cards yet.")
        } else {
            Chart(bars) { bar in
                BarMark(x: .value("Column", bar.name), y: .value("Cards", bar.count))
                    .annotation(position: .top) { Text("\(bar.count)").font(.caption2) }
            }
            .frame(height: 160)
        }
    }
}

// MARK: - (5) Backlog, (9) due, (3) team, (6) priority, (7) labels, (8) blocked, (13) hygiene

private struct BacklogSummary: View {
    let backlog: KanbanMetrics.Backlog
    let names: [UUID: String]
    let hours: Bool

    var body: some View {
        if backlog.items.isEmpty {
            Empty(text: "Nothing waiting in the backlog unassigned.")
        } else {
            Text("\(backlog.items.count) unassigned in the backlog · \(backlog.ready.count) ready to pull · \(backlog.unassignedActiveCount) unassigned in progress")
                .font(.callout)
            HStack(spacing: 12) {
                ForEach(KanbanMetrics.PriorityRow.allCases, id: \.self) { row in
                    Text("\(row.rawValue) \((backlog.byPriority[row] ?? 0).formatted(oneDecimal))\(hours ? "h" : "")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(backlog.ready.prefix(5), id: \.self) { id in Label(names[id] ?? "", systemImage: "arrow.down.to.line").font(.caption) }
            if !backlog.waitingOnArchived.isEmpty {
                Text("\(backlog.waitingOnArchived.count) waiting on an archived task").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private struct DueSummary: View {
    let due: KanbanMetrics.Due
    let names: [UUID: String]

    var body: some View {
        HStack(spacing: 16) {
            stat("Overdue", due.overdue.count, .red)
            stat("This week", due.thisWeek.count, .orange)
            stat("Next week", due.nextWeek.count, .secondary)
        }
        ForEach(due.overdue.prefix(5), id: \.self) { id in Label(names[id] ?? "", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading) {
            Text("\(value)").font(.title2.monospacedDigit()).foregroundStyle(value > 0 ? color : .secondary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CompositionSummary: View {
    let c: KanbanMetrics.Composition
    let members: [UUID: String]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow { Text(""); Text("Full-time").bold(); Text("Part-time").bold() }
            GridRow { Text("Employees").bold(); cell(.fte, .fullTime); cell(.fte, .partTime) }
            GridRow { Text("Contractors").bold(); cell(.contractor, .fullTime); cell(.contractor, .partTime) }
        }
        .font(.caption)
        if !c.notStarted.isEmpty {
            Text("Not started yet: \(c.notStarted.compactMap { members[$0] }.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
        }
        ForEach([30, 60, 90], id: \.self) { bucket in
            if let entries = c.rollOff[bucket], !entries.isEmpty {
                Text("Rolling off in \(bucket == 30 ? "0–30" : bucket == 60 ? "31–60" : "61–90") days: "
                     + entries.map { "\(members[$0.memberID] ?? "") (\($0.openCards) open)" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(bucket == 30 ? .orange : .secondary)
            }
        }
    }

    private func cell(_ e: KanbanEmployment, _ a: KanbanAssignment) -> some View {
        let value = c.grid[e]?[a] ?? .init()
        return Text("\(value.count) · \(value.hours.formatted(oneDecimal))h").monospacedDigit()
    }
}

private struct PriorityGrid: View {
    let s: MetricsSnapshot
    let columns: [UUID: String]

    var body: some View {
        let matrix = KanbanMetrics.priorityMatrix(s)
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("")
                ForEach(s.columns, id: \.id) { Text($0.name).bold().lineLimit(1) }
            }
            ForEach(KanbanMetrics.PriorityRow.allCases, id: \.self) { row in
                GridRow {
                    Text(row.rawValue).bold()
                    ForEach(s.columns, id: \.id) { column in
                        Text((matrix[row]?[column.id] ?? 0).formatted(oneDecimal)).monospacedDigit()
                    }
                }
            }
        }
        .font(.caption)
    }
}

private struct LabelMixChart: View {
    let s: MetricsSnapshot
    let columns: [UUID: String]
    let labels: [UUID: String]

    struct Bar: Identifiable {
        let id: String
        let column: String
        let label: String
        let value: Double
    }

    var body: some View {
        let mix = KanbanMetrics.labelMix(s)
        let bars: [Bar] = s.columns.flatMap { column in
            (mix[column.id] ?? [:]).map { label, value in
                Bar(id: "\(column.id)-\(label?.uuidString ?? "none")", column: column.name, label: label.flatMap { labels[$0] } ?? "No label", value: value)
            }
        }
        if bars.isEmpty {
            Empty(text: "No cards yet.")
        } else {
            Chart(bars) { bar in
                BarMark(x: .value("Column", bar.column), y: .value("Tasks with label", bar.value))
                    .foregroundStyle(by: .value("Label", bar.label))
            }
            .frame(height: 170)
        }
    }
}

private struct BlockedList: View {
    let blocked: [KanbanMetrics.Blocked]
    let names: [UUID: String]

    var body: some View {
        if blocked.isEmpty {
            Empty(text: "Nothing is blocked.")
        } else {
            ForEach(blocked.prefix(8), id: \.cardID) { item in
                HStack {
                    Text(names[item.cardID] ?? "")
                    Text(item.reason).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("\(item.ageDays)d").monospacedDigit()
                }
                .font(.caption)
            }
        }
    }
}

private struct HygieneList: View {
    let h: KanbanMetrics.Hygiene
    let hours: Bool

    var body: some View {
        let checks: [(String, Int)] = [
            ("No due date", h.missingDue.count), ("No Jira link", h.missingJira.count),
            ("All steps done but not in Done", h.subtasksDoneNotDone.count), ("Done with open steps", h.doneWithOpenSubtasks.count),
            ("People with no open work", h.idleResources.count), ("Past their end date, still holding work", h.pastEndHoldingWork.count),
        ] + (hours ? [("No estimate", h.missingEstimate.count)] : [])
        ForEach(checks, id: \.0) { check in
            HStack {
                Image(systemName: check.1 == 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(check.1 == 0 ? Color.green : Color.orange)
                Text(check.0)
                Spacer()
                Text("\(check.1)").monospacedDigit()
            }
            .font(.caption)
        }
    }
}

// MARK: - (10) CFD, (11) throughput and aging, (12) burn-up

private struct FlowChart: View {
    let days: [KanbanReplay.Day]
    let hours: Bool

    struct Point: Identifiable {
        let id: String
        let day: Date
        let band: String
        let value: Double
    }

    var body: some View {
        let points: [Point] = days.flatMap { day in
            day.bands.map { Point(id: "\(day.day.timeIntervalSince1970)-\($0.columnID)", day: day.day,
                                  band: $0.isDeleted ? "\($0.name) (deleted)" : $0.name, value: hours ? $0.load : Double($0.count)) }
        }
        if points.allSatisfy({ $0.value == 0 }) {
            Empty(text: "History appears as cards move.")
        } else {
            Chart(points) { point in
                AreaMark(x: .value("Day", point.day, unit: .day), y: .value(hours ? "Hours" : "Cards", point.value), stacking: .standard)
                    .foregroundStyle(by: .value("Column", point.band))
            }
            .frame(height: 180)
        }
    }
}

private struct ThroughputChart: View {
    let weeks: [KanbanReplay.Week]

    var body: some View {
        if weeks.allSatisfy({ $0.completed == 0 && $0.reopened == 0 }) {
            Empty(text: "Completed work appears here week by week.")
        } else {
            Chart {
                ForEach(weeks, id: \.start) { week in
                    BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Completed", week.completed))
                        .foregroundStyle(Color.accentColor.opacity(week.partial ? 0.45 : 1))
                    if week.reopened > 0 {
                        PointMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Reopened", week.reopened))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(height: 160)
            Text("This week so far: \(weeks.last?.completed ?? 0) completed").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AgingList: View {
    let aging: [KanbanReplay.Aging]
    let names: [UUID: String]
    let columns: [UUID: String]

    var body: some View {
        if aging.isEmpty {
            Empty(text: "No work in progress.")
        } else {
            ForEach(aging.prefix(8), id: \.cardID) { item in
                HStack {
                    Text(names[item.cardID] ?? "")
                    Text(columns[item.columnID] ?? "").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(item.ageDays)d").monospacedDigit().foregroundStyle(item.ageDays > 14 ? .orange : .primary)
                }
                .font(.caption)
            }
        }
    }
}

private struct BurnUpChart: View {
    let points: [KanbanReplay.BurnUpPoint]
    let hours: Bool

    var body: some View {
        if points.allSatisfy({ $0.scope == 0 }) {
            Empty(text: "Scope and completed work appear as cards are added and finished.")
        } else {
            Chart {
                ForEach(points, id: \.day) { point in
                    LineMark(x: .value("Day", point.day, unit: .day), y: .value(hours ? "Hours" : "Cards", point.scope))
                        .foregroundStyle(by: .value("Series", "Scope"))
                    LineMark(x: .value("Day", point.day, unit: .day), y: .value(hours ? "Hours" : "Cards", point.completed))
                        .foregroundStyle(by: .value("Series", "Completed"))
                }
            }
            .frame(height: 170)
        }
    }
}
