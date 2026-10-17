import SwiftUI
import SwiftData

/// Attention and All projects first, then pinned boards, the other boards (drag to
/// reorder) and archived boards (design 01 §5).
struct KanbanSidebar: View {
    let projects: [KanbanProject]
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @State private var isCreating = false
    @State private var prompt: KanbanTextPrompt?
    @State private var pendingDelete: KanbanProject?
    @State private var importing: KanbanImportRequest?

    private var live: [KanbanProject] { projects.filter { $0.archivedAt == nil } }
    private var pinned: [KanbanProject] { live.filter(\.isPinned) }
    private var unpinned: [KanbanProject] { live.filter { !$0.isPinned } }
    private var archived: [KanbanProject] { projects.filter { $0.archivedAt != nil } }

    var body: some View {
        let selection = Binding<KanbanSidebarItem?>(get: { app.kanban.selection }, set: { if let item = $0 { app.kanban.selection = item } })
        let calendar = KanbanUI.calendar(weekStartsMonday: weekStartsMonday)
        let key = app.kanbanMetricsKey(weekStartsMonday: weekStartsMonday)
        let summaries = Dictionary(live.map { ($0.id, app.kanbanMetrics.summary(of: $0, key: key, calendar: calendar)) },
                                   uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            List(selection: selection) {
                Section {
                    Label("Attention", systemImage: "exclamationmark.circle")
                        .tag(KanbanSidebarItem.attention)
                        .accessibilityIdentifier("kanban-sidebar-attention")
                    Label("All projects", systemImage: "square.grid.2x2")
                        .tag(KanbanSidebarItem.allProjects)
                        .accessibilityIdentifier("kanban-sidebar-all")
                }
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { row($0, summaries[$0.id]) }
                    }
                }
                Section("Boards") {
                    ForEach(unpinned) { row($0, summaries[$0.id]) }
                        .onMove { from, to in
                            var order = unpinned
                            order.move(fromOffsets: from, toOffset: to)
                            app.runKanban { try app.kanbanService(context).reorderProjects(pinned + order + archived) }
                        }
                }
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { row($0, nil) }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { isCreating = true } label: {
                    Label("New board", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("kanban-new-board")
                Button { importing = KanbanTransferUI.pickImport(context: context, app: app) } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Import a board…")
                .accessibilityLabel("Import a board")
                .accessibilityIdentifier("kanban-import-board")
            }
            .padding(10)
        }
        .sheet(isPresented: $isCreating) { KanbanNewBoardSheet() }
        .sheet(item: $importing) { KanbanImportSheet(request: $0) }
        .sheet(item: $prompt) { KanbanTextPromptSheet(prompt: $0) }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Board", role: .destructive) {
                guard let project = pendingDelete else { return }
                if app.kanban.selection == .project(project.id) { app.kanban.selection = .allProjects }
                app.runKanban { try app.kanbanService(context).deleteProject(project) }
            }
        } message: {
            Text("Its cards, rows and history are deleted permanently. People stay in the directory.")
        }
    }

    private func row(_ project: KanbanProject, _ summary: KanbanMetrics.ProjectSummary?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: project.symbolName)
                .foregroundStyle(KanbanUI.color(project.colorHex) ?? .accentColor)
                .accessibilityHidden(true)
            Text(project.name).lineLimit(1)
            Spacer(minLength: 4)
            if let summary {
                if summary.membersOverCapacity > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help("\(summary.membersOverCapacity) over capacity")
                        .accessibilityLabel("\(summary.membersOverCapacity) over capacity")
                }
                Text("\(summary.openCards)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(summary.openCards) open")
            }
        }
        .tag(KanbanSidebarItem.project(project.id))
        .accessibilityIdentifier("kanban-sidebar-\(project.name)")
        .contextMenu { menu(project) }
    }

    @ViewBuilder
    private func menu(_ project: KanbanProject) -> some View {
        let service = app.kanbanService(context)
        Button("Rename…") {
            prompt = .init(title: "Rename board", initial: project.name) { name in
                try service.editProject(project, [.name: .string(name)])
            }
        }
        if project.archivedAt == nil {
            Button(project.isPinned ? "Unpin" : "Pin") {
                app.runKanban { try service.editProject(project, [.isPinned: .bool(!project.isPinned)]) }
            }
            Menu("Colour") {
                ForEach(TaskColor.allCases) { color in
                    Button(String(describing: color).capitalized) { app.runKanban { try service.editProject(project, [.colorHex: .string(color.hex)]) } }
                }
            }
            Button("Duplicate structure…") {
                prompt = .init(title: "New board with this structure", initial: project.name + " copy") { name in
                    let copy = try service.duplicateStructure(of: project, name: name, key: KanbanNewBoardSheet.key(from: name))
                    app.kanban.selection = .project(copy.id)
                }
            }
            Button("Save as template…") {
                prompt = .init(title: "Template name", initial: project.name) { name in
                    _ = try service.saveAsTemplate(project, name: name)
                }
            }
            Divider()
            Button("Export board…") { KanbanTransferUI.exportBoard(project, context: context, app: app) }
            Button("Export as CSV…") { KanbanTransferUI.exportCSV(project, app: app) }
            Divider()
            Button("Archive") { app.runKanban { try service.setProjectArchived(project, true) } }
        } else {
            Button("Restore") { app.runKanban { try service.setProjectArchived(project, false) } }
        }
        Button("Delete…", role: .destructive) { pendingDelete = project }
    }
}

/// A one-field sheet: a title, a text field and an action that may refuse the value.
struct KanbanTextPrompt: Identifiable {
    let id = UUID()
    var title: String
    var initial = ""
    var placeholder = ""
    /// Whether an empty value is allowed (e.g. "no WIP limit").
    var allowsEmpty = false
    var apply: (String) throws -> Void
}

struct KanbanTextPromptSheet: View {
    let prompt: KanbanTextPrompt
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title).font(.headline)
            TextField(prompt.placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(save)
                .accessibilityIdentifier("kanban-prompt-field")
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!prompt.allowsEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("kanban-prompt-ok")
            }
        }
        .padding(20)
        .onAppear { text = prompt.initial }
    }

    private func save() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard prompt.allowsEmpty || !value.isEmpty else { return }
        do {
            try prompt.apply(value)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Name, key and template for a new board.
struct KanbanNewBoardSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key = ""
    @State private var keyEdited = false
    @State private var templateID = KanbanTemplate.standard.id
    @State private var error: String?

    /// Up to five capital letters from the name, e.g. "Platform Core" → "PLATF".
    static func key(from name: String) -> String {
        String(name.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(5))
    }

    var body: some View {
        let templates = KanbanTemplateStore.all()
        VStack(alignment: .leading, spacing: 12) {
            Text("New board").font(.headline)
            Form {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("kanban-new-board-name")
                    .onChange(of: name) { _, value in if !keyEdited { key = Self.key(from: value) } }
                TextField("Key", text: Binding(get: { key }, set: { key = $0; keyEdited = true }))
                    .accessibilityIdentifier("kanban-new-board-key")
                Picker("Template", selection: $templateID) {
                    ForEach(templates) { template in
                        Text("\(template.name) — \(template.columns.map(\.name).joined(separator: " → "))").tag(template.id)
                    }
                }
            }
            .frame(width: 420)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create(templates) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("kanban-new-board-create")
            }
        }
        .padding(20)
    }

    private func create(_ templates: [KanbanTemplate]) {
        let template = templates.first { $0.id == templateID } ?? .standard
        do {
            let project = try app.kanbanService(context).createProject(
                name: name.trimmingCharacters(in: .whitespaces), key: key.isEmpty ? Self.key(from: name) : key, template: template,
                defaults: KanbanBoardDefaults(UserDefaults.standard))
            app.kanban.selection = .project(project.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
