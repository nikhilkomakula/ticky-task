import SwiftUI

/// A board row's header (design 01 §5): avatar, name, employment and assignment icons,
/// the load gauge, a roll-off badge, a cross-board badge and the collapse chevron.
struct KanbanRowHeader: View {
    let project: KanbanProject
    let row: KanbanRowSnapshot
    let resource: KanbanResource?
    let load: KanbanMetrics.LoadRow?
    let person: KanbanMetrics.PersonRow?
    let collapsed: Bool
    var drag: BoardDragController?
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onRemove: () -> Void
    @Environment(AppState.self) private var app

    var body: some View {
        let _ = app.kanbanClock   // the roll-off badge counts days from today
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Expand row" : "Collapse row")
            .accessibilityLabel(collapsed ? "Expand \(row.name)" : "Collapse \(row.name)")
            .accessibilityIdentifier("kanban-row-toggle-\(row.name)")

            avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(row.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let resource { icons(resource) }
                }
                if let load { gauge(load) }
                badges
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban-rowhdr-\(row.name)")
        .contextMenu {
            if resource != nil {
                Button("Edit membership…", action: onEdit)
                Button("Remove from board…", role: .destructive, action: onRemove)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if resource == nil {
            Image(systemName: "tray")
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Text(resource?.initials.isEmpty == false ? resource!.initials : String(row.name.prefix(2)).uppercased())
                .font(.caption.weight(.bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill((KanbanUI.color(resource?.person?.colorHex) ?? .accentColor).opacity(0.25)))
                .accessibilityHidden(true)
        }
    }

    private func icons(_ resource: KanbanResource) -> some View {
        let contractor = resource.person?.employment == .contractor
        let partTime = resource.effectiveAssignment == .partTime
        let employment = contractor ? "Contractor" : "Employee"
        let assignment = partTime ? "Part-time" : "Full-time"
        let allocation = resource.allocationPercent < 100 ? ", \(resource.allocationPercent)%" : ""
        return HStack(spacing: 3) {
            Image(systemName: contractor ? "person.badge.clock" : "person.badge.shield.checkmark")
                .help(employment)
                .accessibilityHidden(true)
            Image(systemName: partTime ? "circle.lefthalf.filled" : "circle.fill")
                .help("Allocation")
                .accessibilityHidden(true)
            if resource.allocationPercent < 100 {
                Text("\(resource.allocationPercent)%").monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(employment), \(assignment)\(allocation)")
    }

    /// A bar filled to the utilisation (capped at the bar's end), coloured by band.
    private func gauge(_ load: KanbanMetrics.LoadRow) -> some View {
        let hours = project.loadMeasure == .hours
        let text = KanbanUI.loadText(load: load.load, target: load.target, utilisation: load.utilisation, hours: hours)
        let fill: Double = switch load.utilisation {
        case let .ratio(u, _)?: min(u, 1)
        case let .noCapacity(l)?: l > 0 ? 1 : 0
        case nil: 0
        }
        let color = KanbanUI.utilisationColor(load.utilisation)
        // A narrow People column drops the bar before the numbers.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                if load.target != nil { bar(fill: fill, color: color) }
                loadLabel(load, hours: hours)
            }
            loadLabel(load, hours: hours)
        }
        .help(text + (load.backlogCoverageWeeks.map { " · backlog covers \($0.formatted(.number.precision(.fractionLength(1)))) weeks" } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Load: \(text)")
        .accessibilityIdentifier("kanban-gauge-\(row.name)")
    }

    private func bar(fill: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: geo.size.width * fill)
            }
        }
        .frame(minWidth: 24, idealWidth: 24, maxWidth: 70)
        .frame(height: 6)
    }

    @ViewBuilder
    private func loadLabel(_ load: KanbanMetrics.LoadRow, hours: Bool) -> some View {
        if let projection = resource.flatMap({ drag?.projected[$0.id] }) {
            // While a drag hovers: "4 → 6/5".
            let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
            Text("\(projection.before.formatted(format)) → \(projection.after.formatted(format))/\(projection.target.formatted(format))\(hours ? "h" : "")")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(KanbanUI.utilisationColor(projection.utilisation))
                .fixedSize()
                .accessibilityIdentifier("kanban-projected-\(row.name)")
        } else {
            Text(shortLoad(load, hours: hours))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func shortLoad(_ load: KanbanMetrics.LoadRow, hours: Bool) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        let unit = hours ? "h" : ""
        guard let target = load.target else { return "\(load.load.formatted(format))\(unit)" }
        return "\(load.load.formatted(format))/\(target.formatted(format))\(unit)"
    }

    @ViewBuilder
    private var badges: some View {
        let endsSoon: Int? = resource?.endDate.map { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                                                    to: Calendar.current.startOfDay(for: $0)).day ?? 0 }
        let crossBoard = person.map { $0.overAllocated || ($0.boards.count > 1 && $0.headline.isOverCapacity) } ?? false
        if (endsSoon.map { (0...30).contains($0) } ?? false) || crossBoard {
            HStack(spacing: 6) {
                if let days = endsSoon, (0...30).contains(days) {
                    Label(days == 0 ? "Ends today" : "Ends in \(days)d", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("kanban-rolloff-\(row.name)")
                }
                if crossBoard, let person {
                    Label(person.overAllocated ? "\(person.totalAllocation)%" : "Over", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help(crossBoardHelp(person))
                        .accessibilityLabel(crossBoardHelp(person))
                        .accessibilityIdentifier("kanban-crossboard-\(row.name)")
                }
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
    }

    private func crossBoardHelp(_ person: KanbanMetrics.PersonRow) -> String {
        let others = person.boards.filter { $0.projectID != project.id }
            .map { "\($0.projectName): \(shortLoad($0.row, hours: false))" }
        let lead = person.overAllocated ? "Allocated \(person.totalAllocation)% across boards" : "Over capacity across boards"
        return ([lead] + others).joined(separator: "\n")
    }
}
