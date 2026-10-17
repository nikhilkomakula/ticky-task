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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.runKanban { try KanbanBoardTransfer.export([project], context: context).write(to: url, options: .atomic) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import “\(request.fileName)”").font(.headline)
            Text("\(request.plan.boards.count) board\(request.plan.boards.count == 1 ? "" : "s") · \(request.plan.kanban.tasks.count) cards · \(request.plan.people.count) people. Imported boards start a fresh history.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                Section("Boards") {
                    ForEach($request.plan.boards) { $board in
                        Picker(board.name, selection: $board.mergeInto) {
                            Text(board.keyWasTaken ? "New board (key \(board.key))" : "New board").tag(UUID?.none)
                            ForEach(projects.filter { $0.archivedAt == nil }) { Text("Merge into \($0.name)").tag(Optional($0.id)) }
                        }
                        .accessibilityIdentifier("kanban-import-board-\(board.name)")
                        let reused = request.plan.reusedMemberships(projects: projects, people: people)[board.id] ?? []
                        if !reused.isEmpty {
                            Text("One membership per person on a board, so these join an existing one and keep its allocation, role and dates: \(reused.joined(separator: ", ")).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("People") {
                    ForEach($request.plan.people) { $person in
                        Picker(person.name, selection: $person.linkTo) {
                            Text("Add as a new person").tag(UUID?.none)
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
