import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// A board's Availability tab (design 03): a row per member, a column per Monday–Sunday week
/// from the board's start to its end, each cell the member's available days after recorded
/// time off, coloured by the share of the week's possible days. Card filters don't apply.
struct KanbanAvailabilityView: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(KanbanBoardDefaults.showAllocationKey) private var showAllocation = false
    @Query(sort: \KanbanHoliday.day) private var allHolidays: [KanbanHoliday]
    @State private var shift = 0
    @State private var scrollX: CGFloat = 0
    @State private var popover: CellID?
    @State private var timeOffFor: KanbanPerson?
    @State private var newTimeOff: KanbanTimeOffDraft?
    @State private var holidaysEditor: Bool = false
    @State private var assistant: AssistantInput?
    @FocusState private var focus: CellID?

    struct CellID: Hashable {
        let resourceID: UUID
        let week: KanbanDay
    }

    /// Opens Update availability, with any screenshots dropped on the grid.
    struct AssistantInput: Identifiable {
        let id = UUID()
        var images: [URL] = []
    }

    struct Row: Identifiable {
        let resource: KanbanResource
        let cells: [KanbanAvailability.Cell]
        let holidays: [String]  // Holiday names for each cell
        var id: UUID { resource.id }
    }

    static let headerWidth: CGFloat = 230
    static let weekWidth: CGFloat = 88

    var body: some View {
        let _ = app.kanbanClock   // this week moves at midnight on Monday
        let today = KanbanDay.today()
        let board = KanbanAvailability.Board(project)
        let weeks = KanbanAvailability.window(board: board, today: today, shift: shift)
        let members = project.resources.filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
        let holidays = KanbanAvailability.Holidays(allHolidays)
        let holidaysByID = Dictionary(allHolidays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let holidaysByWeek = Dictionary(grouping: allHolidays) { holiday in
            KanbanDay(key: holiday.day)?.monday ?? KanbanDay.today()
        }
        let holidayNamesPerWeek = holidaysByWeek.mapValues { holidays in holidays.map { $0.name } }
        let rows = members.map { resource in
            let member = KanbanAvailability.Member(resource)
            let cells = weeks.map { KanbanAvailability.cell(week: $0, board: board, member: member, holidays: holidays) }
            // Map cells to holiday names for VoiceOver; one name per cell for the spoken format
            let holidayNames = cells.map { cell in
                cell.holidayIDs.compactMap { holidaysByID[$0]?.name }.first ?? ""
            }
            return Row(resource: resource, cells: cells, holidays: holidayNames)
        }
        VStack(spacing: 0) {
            KanbanAvailabilityToolbar(project: project, board: board, today: today, weeks: weeks, shift: $shift,
                                      onAddTimeOff: { newTimeOff = KanbanTimeOffDraft(person: members.first?.person, week: today.monday) },
                                      onUpdate: { assistant = AssistantInput() },
                                      onHolidays: { holidaysEditor = true })
            Divider()
            if members.isEmpty {
                ContentUnavailableView("Add resources to see weekly availability", systemImage: "person.2",
                                       description: Text("Availability is worked out for each resource on the board."))
            } else {
                grid(rows: rows, weeks: weeks, today: today, holidaysByWeek: holidayNamesPerWeek, rawHolidaysByWeek: holidaysByWeek)
            }
            Divider()
            KanbanAvailabilityLegend(hasTimeOff: members.contains { !($0.person?.timeOff.isEmpty ?? true) })
        }
        // A container, so its id doesn't replace the toolbar's and cells' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban-availability")
        .sheet(item: $timeOffFor) { KanbanTimeOffSheet(person: $0, project: project) }
        .sheet(item: $newTimeOff) { KanbanTimeOffEditor(draft: $0, project: project) }
        .sheet(isPresented: $holidaysEditor) { KanbanHolidaysSheet(project: project) }
        .sheet(item: $assistant) { KanbanAvailabilityAssistantSheet(project: project, window: weeks, images: $0.images) }
        // Dropping screenshots opens Update availability with them; nothing is sent until Extract.
        .dropDestination(for: URL.self) { urls, _ in
            let pictures = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            guard !pictures.isEmpty else { return false }
            assistant = AssistantInput(images: pictures)
            return true
        }
    }

    private func grid(rows: [Row], weeks: [KanbanDay], today: KanbanDay, holidaysByWeek: [KanbanDay: [String]], rawHolidaysByWeek: [KanbanDay: [KanbanHoliday]]) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            memberRow(row, weeks: weeks, today: today, holidaysByWeek: holidaysByWeek, rawHolidaysByWeek: rawHolidaysByWeek)
                            Divider()
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 0) {
                            KanbanAvailabilityHeader(weeks: weeks, today: today, scrollX: scrollX, holidays: allHolidays)
                            Divider()
                            weeklyAvailabilityRow(rows: rows, weeks: weeks, today: today)
                        }
                    }
                }
            }
            .defaultScrollAnchor(.topLeading)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x + $0.contentInsets.leading } action: { _, x in scrollX = max(0, x) }
            .task(id: weeks.first) {
                // The current week, or the board's first or last week when today is outside it.
                let target = weeks.first { $0 == today.monday } ?? (today < (weeks.first ?? today) ? weeks.first : weeks.last)
                // Centred, so the frozen resource column never covers it.
                if let target { proxy.scrollTo(target, anchor: .center) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanAvailabilityToday)) { _ in
                if weeks.contains(today.monday) { withAnimation { proxy.scrollTo(today.monday, anchor: .center) } }
            }
        }
    }

    private func accessibility(total: (available: Int, possible: Int)?, percentage: Int) -> String {
        guard let total else { return "No working days" }
        return "\(percentage) percent, \(KanbanAvailability.days(total.available)) of \(KanbanAvailability.days(total.possible)) days available"
    }

    @ViewBuilder
    private func weeklyAvailabilityContent(total: (available: Int, possible: Int)?, percentage: Int, band: KanbanAvailability.Band?) -> some View {
        let textColor = band.flatMap { KanbanAvailabilityPalette.text($0) } ?? KanbanAvailabilityPalette.inactiveText
        VStack(spacing: 2) {
            if let total {
                Text("\(percentage)%")
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                Text("\(KanbanAvailability.days(total.available)) days")
                    .font(.system(size: 10).monospacedDigit())
            } else {
                Text("—")
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(textColor)
        .frame(width: 80, height: 48)
        .background(RoundedRectangle(cornerRadius: 6).fill(band.map(KanbanAvailabilityPalette.fill) ?? KanbanAvailabilityPalette.inactiveFill))
    }

    private func weeklyAvailabilityRow(rows: [Row], weeks: [KanbanDay], today: KanbanDay) -> some View {
        HStack(spacing: 0) {
            Text("Weekly availability")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Self.headerWidth - 16, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 56)
                .background(Color(nsColor: .windowBackgroundColor))
                .offset(x: scrollX)
                .zIndex(1)
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                let total = KanbanAvailability.total(rows.map { $0.cells[index] })
                let band: KanbanAvailability.Band? = total.flatMap { KanbanAvailability.teamBand(available: $0.available, possible: $0.possible) }
                let percentage = total.map { KanbanAvailability.percent($0.available, of: $0.possible) } ?? 0
                ZStack {
                    if week == today.monday {
                        Color.accentColor.opacity(0.1)
                    }
                    weeklyAvailabilityContent(total: total, percentage: percentage, band: band)
                }
                .frame(width: Self.weekWidth, height: 56)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Weekly availability, week of \(KanbanAvailabilityFormat.long(week))")
                .accessibilityValue(accessibility(total: total, percentage: percentage))
                .accessibilityIdentifier("kanban-availability-weekly-\(week.key)")
            }
        }
    }

    private func memberRow(_ row: Row, weeks: [KanbanDay], today: KanbanDay, holidaysByWeek: [KanbanDay: [String]], rawHolidaysByWeek: [KanbanDay: [KanbanHoliday]]) -> some View {
        HStack(spacing: 0) {
            KanbanAvailabilityRowHeader(resource: row.resource, showAllocation: showAllocation)
                .frame(width: Self.headerWidth, height: 60, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
                .contextMenu {
                    if let person = row.resource.person {
                        Button("Time off…") { timeOffFor = person }
                        Button("Add time off…") { newTimeOff = KanbanTimeOffDraft(person: person, week: today.monday) }
                    }
                }
                .offset(x: scrollX)
                .zIndex(1)
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                let id = CellID(resourceID: row.resource.id, week: week)
                ZStack {
                    if week == today.monday {
                        Color.accentColor.opacity(0.08)
                    }
                    KanbanAvailabilityCellView(cell: row.cells[index], focused: focus == id)
                }
                .frame(width: Self.weekWidth, height: 60)
                .contentShape(Rectangle())
                .focusable()
                .focused($focus, equals: id)
                .onTapGesture { focus = id; popover = id }
                .onKeyPress(.return) { popover = id; return .handled }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    move(from: id, press.key, weeks: weeks)
                    return .handled
                }
                .popover(isPresented: Binding(get: { popover == id }, set: { if !$0 { popover = nil } }), arrowEdge: .bottom) {
                    KanbanAvailabilityCellPopover(resource: row.resource, week: week, cell: row.cells[index],
                                                  holidays: rawHolidaysByWeek[week] ?? [],
                                                  onTimeOff: { popover = nil; timeOffFor = row.resource.person },
                                                  onAddTimeOff: { popover = nil; newTimeOff = KanbanTimeOffDraft(person: row.resource.person, week: week) })
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.resource.displayName), week of \(KanbanAvailabilityFormat.long(week))")
                .accessibilityValue(KanbanAvailabilityFormat.spoken(row.cells[index], timeOff: row.resource.person?.timeOff ?? [],
                                                                    holidays: row.holidays[index].isEmpty ? [] : [row.holidays[index]]))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("kanban-availability-\(row.resource.displayName)-\(week.key)")
            }
        }
    }

    private func move(from id: CellID, _ key: KeyEquivalent, weeks: [KanbanDay]) {
        let members = project.resources.filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }.map(\.id)
        guard let row = members.firstIndex(of: id.resourceID), let column = weeks.firstIndex(of: id.week) else { return }
        switch key {
        case .leftArrow where column > 0: focus = CellID(resourceID: id.resourceID, week: weeks[column - 1])
        case .rightArrow where column < weeks.count - 1: focus = CellID(resourceID: id.resourceID, week: weeks[column + 1])
        case .upArrow where row > 0: focus = CellID(resourceID: members[row - 1], week: id.week)
        case .downArrow where row < members.count - 1: focus = CellID(resourceID: members[row + 1], week: id.week)
        default: break
        }
    }
}

extension Notification.Name {
    /// The Availability toolbar's Today button.
    static let kanbanAvailabilityToday = Notification.Name("kanbanAvailabilityToday")
}

// MARK: - Toolbar, header, legend

/// The date range (opens Board settings), the window arrows for an undated side, Today, Add time off.
struct KanbanAvailabilityToolbar: View {
    let project: KanbanProject
    let board: KanbanAvailability.Board
    let today: KanbanDay
    let weeks: [KanbanDay]
    @Binding var shift: Int
    var onAddTimeOff: () -> Void
    var onUpdate: () -> Void
    var onHolidays: () -> Void
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Button { app.kanbanBoardSettingsProjectID = project.id } label: {
                Label(rangeText, systemImage: "calendar")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .help("Board dates (Board settings)")
            .accessibilityIdentifier("kanban-availability-dates")
            if board.start == nil || board.end == nil {
                Button { shift -= 4 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Earlier weeks")
                    .accessibilityLabel("Earlier weeks")
                Button { shift += 4 } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .help("Later weeks")
                    .accessibilityLabel("Later weeks")
                Text("Set board dates to show the whole board.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Today") {
                shift = 0
                NotificationCenter.default.post(name: .kanbanAvailabilityToday, object: nil)
            }
            .buttonStyle(.borderless)
            Spacer()
            Text("Weeks run Monday to Sunday")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onAddTimeOff) { Label("Add time off", systemImage: "plus") }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("kanban-availability-add-time-off")
            Button(action: onUpdate) { Label("Update availability…", systemImage: "sparkles") }
                .buttonStyle(.borderedProminent)
                .help("Paste text or screenshots of your team's PTO list; review Codex's suggestions before applying")
                .accessibilityIdentifier("kanban-availability-update")
            Menu {
                Button("Public holidays…", action: onHolidays)
                    .accessibilityIdentifier("kanban-availability-holidays-menu")
                Button("Export availability CSV…") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.commaSeparatedText]
                    panel.nameFieldStringValue = "\(project.name) availability.csv"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    app.runKanban { try Data(KanbanAvailabilityCSV.csv(project, weeks: weeks, calendar: .current).utf8).write(to: url, options: .atomic) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("More")
                .accessibilityIdentifier("kanban-availability-more")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var rangeText: String {
        switch (board.start, board.end) {
        case let (start?, end?): "\(KanbanAvailabilityFormat.short(start)) – \(KanbanAvailabilityFormat.short(end))"
        case let (start?, nil): "From \(KanbanAvailabilityFormat.short(start))"
        case let (nil, end?): "Until \(KanbanAvailabilityFormat.short(end))"
        case (nil, nil): "Set board dates"
        }
    }
}

/// The frozen header: a month band over each week's dates; this week underlined.
struct KanbanAvailabilityHeader: View {
    let weeks: [KanbanDay]
    let today: KanbanDay
    let scrollX: CGFloat
    let holidaysByWeek: [KanbanDay: [String]]  // Holiday names per week

    init(weeks: [KanbanDay], today: KanbanDay, scrollX: CGFloat, holidays: [KanbanHoliday] = []) {
        self.weeks = weeks
        self.today = today
        self.scrollX = scrollX
        // Group holidays by week Monday
        var byWeek: [KanbanDay: [String]] = [:]
        for holiday in holidays {
            if let day = KanbanDay(key: holiday.day) {
                let monday = day.monday
                byWeek[monday, default: []].append(holiday.name)
            }
        }
        self.holidaysByWeek = byWeek
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("Resource")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: KanbanAvailabilityView.headerWidth - 16, height: 64, alignment: .bottomLeading)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .background(Color(nsColor: .windowBackgroundColor))
                .offset(x: scrollX)
                .zIndex(1)
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                let firstOfMonth = index == 0 || weeks[index - 1].month != week.month
                let hasHoliday = !(holidaysByWeek[week]?.isEmpty ?? true)
                VStack(spacing: 0) {
                    // A month starts with its name and a rule at its left edge.
                    Text(firstOfMonth ? KanbanAvailabilityFormat.month(week) : "")
                        .font(.caption.weight(.semibold))
                        .padding(.leading, 8)
                        .frame(width: KanbanAvailabilityView.weekWidth, height: 24, alignment: .leading)
                        .overlay(alignment: .leading) {
                            if firstOfMonth && index > 0 { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
                        }
                    HStack(spacing: 4) {
                        VStack(spacing: week == today.monday ? 1 : 2) {
                            if week == today.monday {
                                Text("This week")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            Text(KanbanAvailabilityFormat.week(week))
                                .font(.system(size: week.month == week.adding(days: 6).month ? 12 : 11,
                                              weight: week == today.monday ? .semibold : .regular).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Rectangle()
                                .fill(week == today.monday ? Color.accentColor : .clear)
                                .frame(width: 40, height: 2)
                        }
                        if hasHoliday {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Includes \(holidaysByWeek[week]?.joined(separator: ", ") ?? "")")
                                .accessibilityLabel("Includes \(holidaysByWeek[week]?.joined(separator: ", ") ?? "")")
                        }
                    }
                    .frame(width: KanbanAvailabilityView.weekWidth, height: 40)
                }
                .id(week)
                .overlay(alignment: .center) {
                    if week == today.monday {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                            .padding(2)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Week of \(KanbanAvailabilityFormat.long(week))\(week == today.monday ? ", this week" : "")\(hasHoliday ? ", includes \(holidaysByWeek[week]?.joined(separator: ", ") ?? "")" : "")")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The colour key, in words, and what an empty record means.
struct KanbanAvailabilityLegend: View {
    let hasTimeOff: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Available days").font(.caption.weight(.semibold))
                ForEach([(KanbanAvailability.Band.green, "> 60%"), (.yellow, "60%"), (.red, "< 60%")], id: \.1) { band, text in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(KanbanAvailabilityPalette.fill(band)).frame(width: 14, height: 10)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(KanbanAvailabilityPalette.text(band), lineWidth: 0.5))
                        Text(text).font(.caption)
                    }
                }
                Text("(on a five-day week: more than 3 / exactly 3 / fewer than 3)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !hasTimeOff {
                    Text("No PTO recorded; assumes no time off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Text("Weekly availability").font(.caption.weight(.semibold))
                ForEach([(KanbanAvailability.Band.green, "80% or more"), (.yellow, "60–79%"), (.red, "below 60%")], id: \.1) { band, text in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(KanbanAvailabilityPalette.fill(band)).frame(width: 14, height: 10)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(KanbanAvailabilityPalette.text(band), lineWidth: 0.5))
                        Text(text).font(.caption)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows and cells

struct KanbanAvailabilityRowHeader: View {
    let resource: KanbanResource
    let showAllocation: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(resource.initials.isEmpty ? String(resource.displayName.prefix(2)).uppercased() : resource.initials)
                .font(.caption.weight(.bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill((KanbanUI.color(resource.person?.colorHex) ?? .accentColor).opacity(0.25)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if showAllocation {
                    Text("\(resource.allocationPercent)% on this board")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .help(resource.displayName)
    }
}

/// One week: the available days centred, in the band's colours; "—" when they can't work that
/// week. A pencil marks an override, a warning one that needs review.
struct KanbanAvailabilityCellView: View {
    let cell: KanbanAvailability.Cell
    let focused: Bool

    var body: some View {
        let band = cell.band
        let isHolidayCell = cell.isAllHoliday
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isHolidayCell ? KanbanAvailabilityPalette.inactiveFill
                    : band.map(KanbanAvailabilityPalette.fill) ?? KanbanAvailabilityPalette.inactiveFill)
            if isHolidayCell {
                VStack(spacing: 2) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Holiday")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(KanbanAvailabilityPalette.inactiveText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(cell.isActive ? KanbanAvailability.days(cell.effectiveHalfDays) : "—")
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(band.map(KanbanAvailabilityPalette.text) ?? KanbanAvailabilityPalette.inactiveText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !isHolidayCell {
                if cell.isOverridden {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(band.map(KanbanAvailabilityPalette.text) ?? KanbanAvailabilityPalette.inactiveText)
                        .padding(4)
                } else if cell.overrideNeedsReview {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(KanbanAvailabilityPalette.text(.yellow))
                        .padding(4)
                }
            }
        }
        .frame(width: 80, height: 52)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: focused ? 2 : 0))
        .frame(width: KanbanAvailabilityView.weekWidth, height: 60)
    }
}

// MARK: - Palette and wording

/// Named availability colours (design 03), light and dark; each text colour is ≥ 4.5:1 on its fill.
enum KanbanAvailabilityPalette {
    static func fill(_ band: KanbanAvailability.Band) -> Color {
        switch band {
        case .green: dynamic(0xE9F5EC, 0x173C29)
        case .yellow: dynamic(0xFFF4D6, 0x463515)
        case .red: dynamic(0xFDEDEB, 0x462421)
        }
    }

    static func text(_ band: KanbanAvailability.Band) -> Color {
        switch band {
        case .green: dynamic(0x176B3A, 0x93DCAF)
        case .yellow: dynamic(0x8A4B00, 0xF6C66A)
        case .red: dynamic(0xB42318, 0xFF8A80)
        }
    }

    static let inactiveFill = dynamic(0xF0F1F3, 0x292B30)
    static let inactiveText = dynamic(0x5B606B, 0xB2B8C2)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let (l, d) = (color(light), color(dark))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l })
    }
}

/// Dates for the tab: a civil day, formatted in UTC so it never shifts.
enum KanbanAvailabilityFormat {
    private static let utc = TimeZone(identifier: "UTC")!
    /// Gregorian month names to go with the Gregorian day numbers, whatever calendar the Mac uses.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// "19–25 Oct", or "28 Sep – 4 Oct" across months.
    static func week(_ monday: KanbanDay) -> String {
        let sunday = monday.adding(days: 6)
        let month = Date.FormatStyle(calendar: calendar, timeZone: utc).month(.abbreviated)
        if sunday.month == monday.month { return "\(monday.day)–\(sunday.day) \(monday.utcDate.formatted(month))" }
        return "\(monday.day) \(monday.utcDate.formatted(month)) – \(sunday.day) \(sunday.utcDate.formatted(month))"
    }

    /// "Oct 2026".
    static func month(_ day: KanbanDay) -> String {
        day.utcDate.formatted(Date.FormatStyle(calendar: calendar, timeZone: utc).month(.abbreviated).year())
    }

    /// "19 Oct 2026".
    static func short(_ day: KanbanDay) -> String {
        day.utcDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar, timeZone: utc))
    }

    /// "19 October 2026".
    static func long(_ day: KanbanDay) -> String {
        day.utcDate.formatted(Date.FormatStyle(date: .long, time: .omitted, calendar: calendar, timeZone: utc))
    }

    /// "3 of 5 days available. 2 days off (PTO); 1 public holiday excluded (Thanksgiving). Manually overridden."
    static func spoken(_ cell: KanbanAvailability.Cell, timeOff: [KanbanTimeOff], holidays: [String] = []) -> String {
        if cell.isAllHoliday { return "Public holiday all week" }
        guard cell.isActive else { return "Not working this week" }
        var parts = ["\(KanbanAvailability.days(cell.effectiveHalfDays)) of \(KanbanAvailability.days(cell.possibleHalfDays)) days available"]
        if cell.absentHalfDays > 0 || cell.holidayHalfDays > 0 {
            var fragments: [String] = []
            if cell.absentHalfDays > 0 {
                let kinds = Set(timeOff.filter { cell.absenceIDs.contains($0.id) }.map(\.kind.label)).sorted().joined(separator: ", ")
                fragments.append("\(KanbanAvailability.days(cell.absentHalfDays)) days off (\(kinds))")
            }
            if !holidays.isEmpty {
                let count = holidays.count
                let holidayText = count == 1 ? "half a day" : "\(count) public holiday\(count > 1 ? "s" : "")"
                fragments.append("\(holidayText) excluded (\(holidays.joined(separator: ", ")))")
            }
            parts.append(fragments.joined(separator: "; "))
        }
        if cell.isOverridden { parts.append("Manually overridden") }
        if cell.overrideNeedsReview { parts.append("Override needs review") }
        return parts.joined(separator: ". ")
    }
}
