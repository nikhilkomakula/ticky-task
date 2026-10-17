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
        let flow = app.kanbanMetrics.flow(of: project, key: key, calendar: calendar)   // cached, for both history charts
        let hours = s.loadMeasure == .hours
        let names = Dictionary(s.cards.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let columns = Dictionary(s.columns.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let members = KanbanUI.uniqueNames(s.members.map { ($0.id, $0.name) })
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 12, alignment: .top)], spacing: 12) {
                DashboardCard(title: "Load vs capacity", id: "load") {
                    LoadChart(s: s, members: members, styleMap: columnStyleMap(s), open: { id in open { $0.openOnly = true; if let id { $0.resourceIDs = [id] } else { $0.unassigned = true } } })
                }
                DashboardCard(title: "Capacity, next 12 weeks", id: "heatmap") {
                    HeatmapChart(s: s, members: members, open: { id in open { $0.openOnly = true; $0.resourceIDs = [id] } })
                }
                DashboardCard(title: hours ? "Hours by column" : "Tasks by column", id: "columns") {
                    ColumnsChart(s: s, styleMap: columnStyleMap(s), open: { id in open { $0.columnIDs = [id] } })
                }
                DashboardCard(title: "Unassigned backlog", id: "backlog", action: {
                    open { filter in filter.unassigned = true; filter.columnIDs = Set(s.columns.filter { $0.kind == .backlog }.map(\.id)) }
                }) {
                    BacklogSummary(backlog: KanbanMetrics.unassignedBacklog(s), names: names, hours: hours)
                }
                DashboardCard(title: "Due dates", id: "due", action: { open { $0.openOnly = true; $0.due = .overdue } }) {
                    DueSummary(due: KanbanMetrics.dueBuckets(s), names: names)
                }
                DashboardCard(title: "Team", id: "composition") { CompositionSummary(c: KanbanMetrics.composition(s), members: members) }
                DashboardCard(title: hours ? "Priority by column (hours)" : "Priority by column", id: "priority") {
                    PriorityGrid(s: s, hours: hours, open: { row in
                        open { filter in
                            if row == .critical { filter.criticalOnly = true } else { filter.priorities = [row.priority]; filter.excludeCritical = true }
                        }
                    })
                }
                DashboardCard(title: hours ? "Hours with label" : "Tasks with label", id: "labels") {
                    LabelMixChart(s: s, labels: labelNames, hours: hours, open: { id in open { $0.labelIDs = [id] } })
                }
                DashboardCard(title: "Blocked", id: "blocked", action: { open { $0.openOnly = true; $0.blockedOnly = true } }) {
                    BlockedList(blocked: KanbanMetrics.blockedTasks(s), names: names)
                }
                DashboardCard(title: "Cumulative flow, 90 days", id: "cfd") { FlowChart(days: flow, s: s, project: project, hours: hours) }
                DashboardCard(title: "Completed work (by latest completion)", id: "throughput",
                              subtitle: "Reopened work moves out of earlier weeks") { ThroughputChart(weeks: app.kanbanMetrics.throughput(of: project, key: key, calendar: calendar)) }
                DashboardCard(title: "Age of work in progress", id: "aging") {
                    AgingList(aging: app.kanbanMetrics.aging(of: project, key: key, calendar: calendar), names: names, columns: columns,
                              open: { id in app.revealKanban(taskID: id, projectID: project.id) })
                }
                DashboardCard(title: "Burn-up, 90 days", id: "burnup") { BurnUpChart(points: KanbanReplay.burnUp(flow, hours: hours), hours: hours) }
                DashboardCard(title: "Hygiene", id: "hygiene") { HygieneList(h: KanbanMetrics.hygieneReport(s), hours: hours, open: open) }
            }
            .padding(12)
        }
        .accessibilityIdentifier("kanban-dashboard")
    }

    private var labelNames: [UUID: String] {
        Dictionary(project.labels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Builds a map from column display name to its effective accent colour.
    private func columnStyleMap(_ snapshot: MetricsSnapshot) -> [String: Color] {
        let names = KanbanUI.uniqueNames(snapshot.columns.map { ($0.id, $0.name) }, reserved: [])
        let liveColumns = Dictionary(project.orderedColumns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var map: [String: Color] = [:]
        for column in snapshot.columns {
            let displayName = names[column.id] ?? column.name
            let liveColumn = liveColumns[column.id]
            let style = KanbanColumnStyle(kind: column.kind, customColorHex: liveColumn?.colorHex)
            map[displayName] = style.effectiveAccent
        }
        return map
    }

    /// Opens the board with a filter for what the chart counts. The metrics count live cards
    /// only, so archived ones are hidden.
    private func open(_ filter: (inout KanbanCardFilter) -> Void) {
        app.updateBoardState(project, context: context) { state in
            state.view = .board
            state.showArchived = false
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
    let members: [UUID: String]
    let styleMap: [String: Color]
    var open: (UUID?) -> Void

    struct Bar: Identifiable {
        let id: String
        let person: String
        let column: String
        let load: Double
    }

    private func label(_ row: KanbanMetrics.LoadRow) -> String { row.memberID.flatMap { members[$0] } ?? "Unassigned" }

    var body: some View {
        // The Unassigned row shows its load with no target.
        let rows = KanbanMetrics.loadVsCapacity(s).filter { $0.memberID != nil || $0.load > 0 }
        let columns = KanbanUI.uniqueNames(s.columns.map { ($0.id, $0.name) }, reserved: [])
        let bars = rows.flatMap { row in
            row.segments.filter { $0.load > 0 }.map { segment in
                Bar(id: "\(row.memberID?.uuidString ?? "unassigned")-\(segment.column)", person: label(row),
                    column: columns[segment.column] ?? "", load: segment.load)
            }
        }
        if rows.isEmpty {
            Empty(text: "No open work and no people on this board yet.")
        } else {
            Chart(bars) { bar in
                BarMark(x: .value("Load", bar.load), y: .value("Person", bar.person))
                    .foregroundStyle(by: .value("Column", bar.column))
            }
            .chartForegroundStyleScale(domain: styleMap.keys.sorted(), range: styleMap.keys.sorted().map { styleMap[$0] ?? .gray })
            .frame(height: CGFloat(max(rows.count, 2)) * 28 + 30)
            ForEach(rows, id: \.memberID) { row in
                Button { open(row.memberID) } label: {
                    HStack {
                        Circle().fill(KanbanUI.utilisationColor(row.utilisation)).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(label(row))
                        Spacer()
                        Text(KanbanUI.loadText(load: row.load, target: row.target, utilisation: row.utilisation, hours: s.loadMeasure == .hours))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let weeks = row.backlogCoverageWeeks {
                            Text("· backlog \(weeks.formatted(oneDecimal)) wk").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .help("Show \(label(row))'s open cards")
                .accessibilityLabel("\(label(row)), load \(KanbanUI.loadText(load: row.load, target: row.target, utilisation: row.utilisation, hours: s.loadMeasure == .hours))")
            }
        }
    }
}

// MARK: - (2) Heatmap

private struct HeatmapChart: View {
    let s: MetricsSnapshot
    let members: [UUID: String]
    var open: (UUID) -> Void

    enum State { case band(KanbanMetrics.Band), offBoardWithWork, offBoard, noWorkDays }

    struct Cell: Identifiable {
        let id: String
        let person: String
        let week: Date
        let value: Double?
        let load: Double
        let state: State
    }

    private static func color(_ state: State) -> Color {
        switch state {
        case let .band(band): KanbanUI.bandColor(band)
        case .offBoardWithWork: .red
        case .offBoard, .noWorkDays: Color.gray.opacity(0.25)
        }
    }

    private static func describe(_ cell: Cell) -> String {
        switch cell.state {
        case .band: cell.value.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
        case .offBoardWithWork: "not on the board, but holds \(cell.load.formatted(oneDecimal))"
        case .offBoard: "not on the board"
        case .noWorkDays: "no work days"
        }
    }

    var body: some View {
        let rows = KanbanMetrics.capacityHeatmap(s, weeks: 12)
        let week0 = s.weekStart(s.today)
        let cells: [Cell] = rows.flatMap { row in
            row.weeks.enumerated().map { index, heat in
                let week = s.addDays(7 * index, to: week0)
                let id = "\(row.memberID)-\(index)", person = members[row.memberID] ?? row.name
                switch heat {
                case let .ratio(load, target, band): return Cell(id: id, person: person, week: week, value: load / target, load: load, state: .band(band))
                case let .unavailable(load): return Cell(id: id, person: person, week: week, value: nil, load: load, state: load > 0 ? .offBoardWithWork : .offBoard)
                case .noCapacity: return Cell(id: id, person: person, week: week, value: nil, load: 0, state: .noWorkDays)
                }
            }
        }
        if rows.isEmpty {
            Empty(text: "No people on this board yet.")
        } else {
            Chart(cells) { cell in
                RectangleMark(x: .value("Week", cell.week, unit: .weekOfYear), y: .value("Person", cell.person))
                    .foregroundStyle(Self.color(cell.state))
                    .opacity(cell.value.map { min(max($0, 0.25), 1) } ?? 1)
                    .accessibilityLabel("\(cell.person), week of \(cell.week.formatted(.dateTime.month().day()))")
                    .accessibilityValue(Self.describe(cell))
            }
            .frame(height: CGFloat(max(rows.count, 2)) * 26 + 30)
            HStack(spacing: 10) {
                ForEach(rows, id: \.memberID) { row in
                    Button(members[row.memberID] ?? row.name) { open(row.memberID) }.buttonStyle(.link)
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - (4) By column

private struct ColumnsChart: View {
    let s: MetricsSnapshot
    let styleMap: [String: Color]
    var open: (UUID) -> Void

    struct Bar: Identifiable {
        let id: UUID
        let name: String
        let value: Double
    }

    var body: some View {
        let hours = s.loadMeasure == .hours
        let names = KanbanUI.uniqueNames(s.columns.map { ($0.id, $0.name) }, reserved: [])   // columns may share a name
        let bars = KanbanMetrics.tasksByColumn(s).map { Bar(id: $0.column, name: names[$0.column] ?? "", value: hours ? $0.load : Double($0.count)) }
        if bars.allSatisfy({ $0.value == 0 }) {
            Empty(text: "No cards yet.")
        } else {
            Chart(bars) { bar in
                BarMark(x: .value("Column", bar.name), y: .value(hours ? "Hours" : "Cards", bar.value))
                    .foregroundStyle(styleMap[bar.name] ?? .gray)
                    .annotation(position: .top) { Text("\(bar.value.formatted(oneDecimal))\(hours ? "h" : "")").font(.caption2) }
            }
            .frame(height: 160)
            HStack(spacing: 10) {
                ForEach(bars) { bar in Button(bar.name) { open(bar.id) }.buttonStyle(.link) }
            }
            .font(.caption)
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
    let hours: Bool
    var open: (KanbanMetrics.PriorityRow) -> Void

    var body: some View {
        let matrix = KanbanMetrics.priorityMatrix(s)
        let unit = hours ? "h" : ""
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("")
                ForEach(s.columns, id: \.id) { Text($0.name).bold().lineLimit(1) }
            }
            ForEach(KanbanMetrics.PriorityRow.allCases, id: \.self) { row in
                GridRow {
                    Button(row.rawValue) { open(row) }.buttonStyle(.link).bold()
                    ForEach(s.columns, id: \.id) { column in
                        Text("\((matrix[row]?[column.id] ?? 0).formatted(oneDecimal))\(unit)").monospacedDigit()
                    }
                }
            }
        }
        .font(.caption)
    }
}

private struct LabelMixChart: View {
    let s: MetricsSnapshot
    let labels: [UUID: String]
    let hours: Bool
    var open: (UUID) -> Void

    struct Bar: Identifiable {
        let id: String
        let column: String
        let label: String
        let value: Double
    }

    var body: some View {
        let mix = KanbanMetrics.labelMix(s)
        let columnNames = KanbanUI.uniqueNames(s.columns.map { ($0.id, $0.name) }, reserved: [])
        let labelNames = KanbanUI.uniqueNames(labels.sorted { $0.value < $1.value }.map { ($0.key, $0.value) }, reserved: ["No label"])
        let bars: [Bar] = s.columns.flatMap { column in
            (mix[column.id] ?? [:]).map { label, value in
                Bar(id: "\(column.id)-\(label?.uuidString ?? "none")", column: columnNames[column.id] ?? column.name,
                    label: label.flatMap { labelNames[$0] } ?? "No label", value: value)
            }
        }
        let used = Set(s.cards.filter { !$0.archived }.flatMap(\.labels))
        if bars.isEmpty {
            Empty(text: "No cards yet.")
        } else {
            Chart(bars) { bar in
                BarMark(x: .value("Column", bar.column), y: .value(hours ? "Hours with label" : "Tasks with label", bar.value))
                    .foregroundStyle(by: .value("Label", bar.label))
            }
            .frame(height: 170)
            HStack(spacing: 10) {
                ForEach(labels.filter { used.contains($0.key) }.sorted { $0.value < $1.value }, id: \.key) { label in
                    Button(label.value) { open(label.key) }.buttonStyle(.link)
                }
            }
            .font(.caption)
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
    var open: ((inout KanbanCardFilter) -> Void) -> Void

    struct Check: Identifiable {
        let id: String
        let count: Int
        let filter: ((inout KanbanCardFilter) -> Void)?
    }

    var body: some View {
        let checks: [Check] = [
            Check(id: "No due date", count: h.missingDue.count, filter: { $0.openOnly = true; $0.due = KanbanCardFilter.Due.none }),
            Check(id: "No Jira link", count: h.missingJira.count, filter: { $0.openOnly = true; $0.hasJira = false }),
            Check(id: "All steps done but not in Done", count: h.subtasksDoneNotDone.count, filter: nil),
            Check(id: "Done with open steps", count: h.doneWithOpenSubtasks.count, filter: nil),
            Check(id: "People with no open work", count: h.idleResources.count, filter: nil),
            Check(id: "Past their end date, still holding work", count: h.pastEndHoldingWork.count, filter: nil),
        ] + (hours ? [Check(id: "No estimate", count: h.missingEstimate.count, filter: { $0.openOnly = true; $0.hasEstimate = false })] : [])
        ForEach(checks) { check in
            HStack {
                Image(systemName: check.count == 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(check.count == 0 ? Color.green : Color.orange)
                    .help(check.count == 0 ? "Passed" : "Warning")
                    .accessibilityLabel(check.count == 0 ? "Passed" : "Warning")
                if let filter = check.filter, check.count > 0 {
                    Button(check.id) { open(filter) }.buttonStyle(.link)
                } else {
                    Text(check.id)
                }
                Spacer()
                Text("\(check.count)").monospacedDigit()
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(check.count == 0 ? "Passed" : "Warning") - \(check.id): \(check.count)")
        }
    }
}

// MARK: - (10) CFD, (11) throughput and aging, (12) burn-up

private struct FlowChart: View {
    let days: [KanbanReplay.Day]
    let s: MetricsSnapshot
    let project: KanbanProject
    let hours: Bool

    struct Point: Identifiable {
        let id: String
        let day: Date
        let band: String
        let value: Double
    }

    var body: some View {
        // One label per column id (names may repeat), with deleted columns marked and grey.
        var seen = Set<UUID>(), columns: [(id: UUID, name: String, deleted: Bool)] = []
        for band in (days.last?.bands ?? []) + days.flatMap(\.bands) where seen.insert(band.columnID).inserted {
            columns.append((band.columnID, band.isDeleted ? "\(band.name) (deleted)" : band.name, band.isDeleted))
        }
        let labels = KanbanUI.uniqueNames(columns.map { ($0.id, $0.name) }, reserved: [])
        let domain = columns.map { labels[$0.id] ?? $0.name }

        // Build colour map from live columns or grey for deleted.
        let liveColumns = Dictionary(project.orderedColumns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let metricColumns = Dictionary(s.columns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let range = columns.map { column -> Color in
            if column.deleted {
                return Color.gray.opacity(0.5)
            } else {
                let liveColumn = liveColumns[column.id]
                let metricColumn = metricColumns[column.id]
                let kind = metricColumn?.kind ?? .backlog
                let style = KanbanColumnStyle(kind: kind, customColorHex: liveColumn?.colorHex)
                return style.effectiveAccent
            }
        }

        // Every column on every day (zero when it has no cards), so a band drops to zero
        // instead of bridging the days it was empty.
        let points: [Point] = days.flatMap { day in
            let values = Dictionary(day.bands.map { ($0.columnID, hours ? $0.load : Double($0.count)) }, uniquingKeysWith: +)
            return columns.map { column in
                Point(id: "\(day.day.timeIntervalSince1970)-\(column.id)", day: day.day, band: labels[column.id] ?? column.name,
                      value: values[column.id] ?? 0)
            }
        }
        return Group {
            if points.allSatisfy({ $0.value == 0 }) {
                Empty(text: "History appears as cards move.")
            } else {
                Chart(points) { point in
                    AreaMark(x: .value("Day", point.day, unit: .day), y: .value(hours ? "Hours" : "Cards", point.value), stacking: .standard)
                        .foregroundStyle(by: .value("Column", point.band))
                }
                .chartForegroundStyleScale(domain: domain, range: range)
                .frame(height: 180)
            }
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
    var open: (UUID) -> Void

    var body: some View {
        if aging.isEmpty {
            Empty(text: "No work in progress.")
        } else {
            ForEach(aging.prefix(8), id: \.cardID) { item in
                HStack {
                    Button(names[item.cardID] ?? "") { open(item.cardID) }.buttonStyle(.link)
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

private extension KanbanMetrics.PriorityRow {
    /// The stored priority for High/Medium/Low (Critical is its own flag).
    var priority: Int {
        switch self {
        case .critical, .high: TaskPriority.high.rawValue
        case .medium: TaskPriority.medium.rawValue
        case .low: TaskPriority.low.rawValue
        }
    }
}
