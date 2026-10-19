import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Board export, CSV export and import (design 01 §7), with the import preview.
@MainActor
enum KanbanTransferUI {
    static var boardType: UTType { UTType(filenameExtension: KanbanBoardTransfer.fileExtension) ?? .json }

    static func exportBoard(_ project: KanbanProject, context: ModelContext, app: AppState) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [boardType]
        panel.nameFieldStringValue = "\(project.name).\(KanbanBoardTransfer.fileExtension)"
        // A board without both dates: choose which time off to include, before saving.
        var range: (start: String, end: String)?
        if project.startDay == nil || project.endDay == nil {
            guard let chosen = chooseTimeOffRange(project) else { return }
            range = chosen
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.runKanban { try KanbanBoardTransfer.export([project], context: context, timeOffRange: range).write(to: url, options: .atomic) }
    }

    /// From–to pickers, defaulting to `KanbanBoardTransfer.defaultTimeOffRange`; nil on Cancel.
    private static func chooseTimeOffRange(_ project: KanbanProject) -> (start: String, end: String)? {
        let initial = KanbanBoardTransfer.defaultTimeOffRange(startDay: project.startDay, endDay: project.endDay)
        func picker(_ key: String) -> NSDatePicker {
            let picker = NSDatePicker()
            picker.datePickerElements = .yearMonthDay
            picker.datePickerStyle = .textFieldAndStepper
            picker.dateValue = KanbanDay(key: key)?.date() ?? Date()
            return picker
        }
        let from = picker(initial.start), to = picker(initial.end)
        let row = NSStackView(views: [NSTextField(labelWithString: "From"), from, NSTextField(labelWithString: "to"), to])
        row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        let alert = NSAlert()
        alert.messageText = "Which time off should the file include?"
        alert.informativeText = "This board doesn't have both a start and an end date. Time off for its people that overlaps this range is included whole, even where it runs past it. It applies to those people on every board they're on after import."
        alert.accessoryView = row
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let start = KanbanDay(from.dateValue), end = max(KanbanDay(to.dateValue), start)
        return (start.key, end.key)
    }

    static func exportCSV(_ project: KanbanProject, app: AppState) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(project.name).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.runKanban { try Data(KanbanBoardTransfer.csv(project).utf8).write(to: url, options: .atomic) }
    }

    /// Picks a file and returns its plan for the preview, or nil (cancelled or refused).
    static func pickImport(context: ModelContext, app: AppState) -> KanbanImportRequest? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [boardType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let plan = try KanbanBoardTransfer.plan(try Data(contentsOf: url), context: context)
            return KanbanImportRequest(plan: plan, fileName: url.lastPathComponent)
        } catch {
            app.kanbanError = error.localizedDescription
            return nil
        }
    }
}

struct KanbanImportRequest: Identifiable {
    let id = UUID()
    var plan: KanbanBoardTransfer.Plan
    let fileName: String
}

/// What an import will do, with the choices: each board new or merged into an existing
/// one, each person linked to someone here or created.
struct KanbanImportSheet: View {
    @State var request: KanbanImportRequest
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KanbanProject.sortIndex) private var projects: [KanbanProject]
    @Query(sort: \KanbanPerson.name) private var people: [KanbanPerson]
    @Query private var holidays: [KanbanHoliday]
    @State private var error: String?

    private var repairs: [String] {
        let r = request.plan.report
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var lines: [String] = []
        if r.droppedDependencyEdges > 0 { lines.append("\(plural(r.droppedDependencyEdges, "dependency", "dependencies")) that formed a loop won’t be imported.") }
        if r.unassignedFromArchivedMemberships > 0 { lines.append("\(plural(r.unassignedFromArchivedMemberships, "card", "cards")) on archived memberships will be Unassigned.") }
        if r.repairedCompletions > 0 { lines.append("\(plural(r.repairedCompletions, "card", "cards")) will have completion matched to their column.") }
        return lines
    }

    /// " · 4 time-off entries (applies to those people on every board)".
    private var availabilityText: String {
        let timeOff = request.plan.kanban.timeOff?.count ?? 0
        let overrides = request.plan.kanban.availabilityOverrides?.count ?? 0
        guard timeOff + overrides > 0 else { return "" }
        var parts: [String] = []
        if timeOff > 0 { parts.append("\(timeOff) time-off \(timeOff == 1 ? "entry" : "entries") (for those people on every board; ones already here are skipped)") }
        if overrides > 0 { parts.append("\(overrides) availability \(overrides == 1 ? "override" : "overrides")") }
        return " · " + parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import “\(request.fileName)”").font(.headline)
            Text("\(request.plan.boards.count) board\(request.plan.boards.count == 1 ? "" : "s") · \(request.plan.kanban.tasks.count) cards · \(request.plan.people.count) resources\(availabilityText). Imported boards start a fresh history.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                let conflicts = request.plan.availabilityConflicts(projects: projects, people: people)
                let holidayChanges = request.plan.holidayChanges(here: holidays, people: people)
                if holidayChanges.adds + holidayChanges.differs > 0 {
                    Section("Public holidays") {
                        Toggle("Import public holidays: adds \(holidayChanges.adds)\(holidayChanges.differs > 0 ? ", \(holidayChanges.differs) differ" : "")",
                               isOn: $request.plan.importHolidays)
                            .accessibilityIdentifier("kanban-import-holidays")
                        if holidayChanges.differs > 0 && request.plan.importHolidays {
                            Toggle("Use the file's version of \(holidayChanges.differs) that differ from what's here", isOn: $request.plan.useIncomingHolidays)
                        }
                        Text("Holidays apply to everyone on every board.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if conflicts.timeOff + conflicts.overrides > 0 {
                    Section("Availability") {
                        if conflicts.timeOff > 0 {
                            Toggle("Use the file's version of \(conflicts.timeOff) time-off \(conflicts.timeOff == 1 ? "entry" : "entries") that differ from what's recorded",
                                   isOn: $request.plan.useIncomingTimeOff)
                        }
                        if conflicts.overrides > 0 {
                            Toggle("Use the file's value for \(conflicts.overrides) \(conflicts.overrides == 1 ? "week" : "weeks") already overridden here",
                                   isOn: $request.plan.useIncomingOverrides)
                        }
                        Text("Otherwise what's recorded here is kept.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Boards") {
                    ForEach($request.plan.boards) { $board in
                        Picker(board.name, selection: $board.mergeInto) {
                            Text(board.keyWasTaken ? "New board (key \(board.key))" : "New board").tag(UUID?.none)
                            ForEach(projects.filter { $0.archivedAt == nil }) { Text("Merge into \($0.name)").tag(Optional($0.id)) }
                        }
                        .accessibilityIdentifier("kanban-import-board-\(board.name)")
                        if board.mergeInto != nil, let file = request.plan.kanban.projects.first(where: { $0.id == board.id }),
                           file.startDay != nil || file.endDay != nil {
                            Toggle("Use the file's board dates", isOn: $board.useImportedDates)
                                .help("Otherwise this board keeps its own start and end dates")
                        }
                        let reused = request.plan.reusedMemberships(projects: projects, people: people)[board.id] ?? []
                        if !reused.isEmpty {
                            Text("One membership per resource on a board, so these join an existing one and keep its allocation, role and dates: \(reused.joined(separator: ", ")).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Resources") {
                    ForEach($request.plan.people) { $person in
                        Picker(person.name, selection: $person.linkTo) {
                            Text("Add as a new resource").tag(UUID?.none)
                            ForEach(people.filter { $0.archivedAt == nil || $0.id == person.linkTo }) { Text("Same as \($0.name)").tag(Optional($0.id)) }
                        }
                        if let linked = person.linkTo.flatMap({ id in people.first { $0.id == id } }), linked.archivedAt != nil {
                            Text("\(linked.name) is archived here: their memberships arrive archived and their cards Unassigned.")
                                .font(.caption).foregroundStyle(.orange)
                        } else if person.linkTo == nil, request.plan.kanban.people.first(where: { $0.id == person.id })?.archivedAt != nil {
                            Text("\(person.name) is archived in the file: they arrive archived, with their cards Unassigned.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if !repairs.isEmpty {
                    Section("Repairs") {
                        ForEach(repairs, id: \.self) { Text($0).font(.callout) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 460, height: 320)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    do {
                        let boards = try KanbanBoardTransfer.apply(request.plan, fileName: request.fileName, context: context)
                        app.kanbanHistory.clear()   // undo doesn't reach past an import (design 01 §2.4)
                        app.kanbanGeneration.bump()
                        if let first = boards.first {
                            app.module = .kanban
                            app.kanban.selection = .project(first.id)
                        }
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("kanban-import-confirm")
            }
        }
        .padding(20)
    }
}

/// The Kanban Summary sheet with a fresh session per opening; the same generator and
/// model catalog as the Weekly Summary (stubs under `-uitest`).
struct KanbanSummaryPresenter: View {
    let project: KanbanProject
    @State private var session: KanbanSummarySession

    init(project: KanbanProject) {
        self.project = project
        let dependencies = WeeklySummaryDependencies.make()
        _session = State(initialValue: KanbanSummarySession(generator: dependencies.generator, catalog: dependencies.catalog))
    }

    var body: some View {
        KanbanSummarySheet(session: session, project: project)
    }
}
