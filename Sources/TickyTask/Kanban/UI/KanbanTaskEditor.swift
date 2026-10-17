import SwiftUI
import SwiftData

/// The card editor (design 01 §5, D4): the planner editor's title, notes, priority,
/// Critical and checklist pieces, plus the Kanban fields. Edits are drafts until Done,
/// which validates everything first, then applies the move, the field edit, labels,
/// dependencies and steps through `KanbanService`.
struct KanbanTaskEditor: View {
    let task: KanbanTask
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    struct StepDraft: Identifiable, Equatable {
        let id: UUID
        var title: String
        var isDone: Bool
        var isNew = false
    }

    @State private var title = ""
    @State private var notes = AttributedString()
    @State private var loadedNotes = AttributedString()
    @State private var priority = TaskPriority.low
    @State private var isCritical = false
    @State private var columnID: UUID?
    @State private var row = KanbanRowKey.unassigned
    @State private var labelIDs: Set<UUID> = []
    @State private var hasStart = false
    @State private var start = Date()
    @State private var hasDue = false
    @State private var due = Date()
    @State private var hasEstimate = false
    @State private var estimate = 4.0
    @State private var jiraURL = ""
    @State private var isBlocked = false
    @State private var blockedReason = ""
    @State private var dependencyIDs: Set<UUID> = []
    @State private var steps: [StepDraft] = []
    @State private var newStep = ""
    @State private var error: String?
    @State private var suggestDone = false
    @State private var confirmDelete = false

    private var project: KanbanProject? { task.project }
    private var trimmedJira: String { jiraURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.system(size: 20, weight: .semibold))
                        .textFieldStyle(.plain)
                        .lineLimit(1...10)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("kanban-editor-title")
                }
                Section("Details") { RichNotesEditor(text: $notes) }
                placementSection
                attributesSection
                datesSection
                linksSection
                stepsSection
                historySection
            }
            .formStyle(.grouped)
            footer
        }
        .frame(minWidth: 580, minHeight: 640)
        .onAppear(perform: load)
        .alert("Couldn’t save the card", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your changes are still here. \(error ?? "")")
        }
        .alert("All steps are done", isPresented: $suggestDone) {
            Button("Move to Done") { moveToDone() }
            Button("Not now", role: .cancel) { dismiss() }
        } message: {
            Text("Move “\(task.title)” to Done?")
        }
        .confirmationDialog("Delete “\(task.title)”?", isPresented: $confirmDelete) {
            Button("Delete Card", role: .destructive) { perform { try $0.deleteTask(task) } }
        } message: {
            Text("You can bring it back from the Change Log.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("kanban-editor-cancel")
            Spacer()
            Text(project?.name ?? "").font(.headline)
            Spacer()
            Button("Done", action: save)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("kanban-editor-done")
        }
        .padding(12)
    }

    private var placementSection: some View {
        Section("On the board") {
            Picker("Column", selection: $columnID) {
                ForEach(project?.orderedColumns ?? []) { Text($0.name).tag(Optional($0.id)) }
            }
            .accessibilityIdentifier("kanban-editor-column")
            Picker("Assignee", selection: $row) {
                Text("Unassigned").tag(KanbanRowKey.unassigned)
                ForEach(activeMemberships) { Text($0.displayName).tag(KanbanRowKey.resource($0.id)) }
            }
            .accessibilityIdentifier("kanban-editor-assignee")
            if let labels = project?.labels.sorted(by: { $0.sortIndex < $1.sortIndex }), !labels.isEmpty {
                LabeledContent("Labels") {
                    FlowChips(items: labels.map { ($0.id, $0.name, KanbanUI.color($0.colorHex) ?? .gray) }, selected: $labelIDs)
                }
            }
        }
    }

    private var attributesSection: some View {
        Section {
            PriorityPicker(selection: $priority)
            CriticalToggle(isOn: $isCritical, help: "Mark this card critical — shown with a red flag before its priority.")
            Toggle("Blocked", isOn: $isBlocked)
                .accessibilityIdentifier("kanban-editor-blocked")
            if isBlocked {
                TextField("Why is it blocked?", text: $blockedReason)
                    .accessibilityIdentifier("kanban-editor-blocked-reason")
            }
        }
    }

    private var datesSection: some View {
        Section("Schedule") {
            Toggle("Start date", isOn: $hasStart)
            if hasStart { DatePicker("Starts", selection: $start, displayedComponents: .date) }
            Toggle("Due date", isOn: $hasDue)
                .accessibilityIdentifier("kanban-editor-due-toggle")
            if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
            Toggle("Estimate", isOn: $hasEstimate)
            if hasEstimate {
                TextField("Hours", value: $estimate, format: .number)
                    .accessibilityIdentifier("kanban-editor-estimate")
            }
        }
    }

    private var linksSection: some View {
        Section {
            TextField("Jira link", text: $jiraURL, prompt: Text("https://…/browse/KEY-123"))
                .accessibilityIdentifier("kanban-editor-jira")
            if !trimmedJira.isEmpty {
                if !KanbanMetrics.isWebURL(trimmedJira) {
                    Text("Enter a web address (http or https).").font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("kanban-editor-jira-error")
                } else if let key = jiraKey(trimmedJira) {
                    Text("Key: \(key)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Depends on") {
                Menu(dependencyIDs.isEmpty ? "None" : dependencyTitles) {
                    ForEach(otherCards) { card in
                        Toggle(card.title, isOn: Binding(
                            get: { dependencyIDs.contains(card.id) },
                            set: { if $0 { dependencyIDs.insert(card.id) } else { dependencyIDs.remove(card.id) } }))
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("kanban-editor-dependencies")
            }
        }
    }

    private var stepsSection: some View {
        Section("Subtasks") {
            ForEach(orderedSteps) { step in
                if let index = steps.firstIndex(where: { $0.id == step.id }) {
                    ChecklistRow(title: $steps[index].title, isDone: $steps[index].isDone,
                                 toggleIdentifier: "kanban-step-toggle-\(step.title)") {
                        steps.removeAll { $0.id == step.id }
                    }
                }
            }
            HStack {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("Add subtask", text: $newStep)
                    .onSubmit(addStep)
                    .accessibilityIdentifier("kanban-editor-add-subtask")
            }
        }
    }

    /// This card's change-log entries, newest first, each with Revert.
    private var historySection: some View {
        let entries = (project?.activities ?? []).filter { $0.taskIDs.contains(task.id) }.sorted { $0.seq > $1.seq }
        return Section("History") {
            if entries.isEmpty {
                Text("No changes yet.").foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(20)) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary)
                        Text(entry.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.revertedByActivityID != nil {
                        Text("Reverted").font(.caption).foregroundStyle(.secondary)
                    } else if entry.seq > (project?.historyBoundarySeq ?? 0) {
                        Button("Revert") { revert(entry) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("kanban-editor-revert-\(entry.seq)")
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Archive") { perform { try $0.archiveTask(task) } }
                .accessibilityIdentifier("kanban-editor-archive")
            Button("Delete…", role: .destructive) { confirmDelete = true }
                .accessibilityIdentifier("kanban-editor-delete")
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Data

    private var activeMemberships: [KanbanResource] {
        (project?.resources ?? []).filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    private var otherCards: [KanbanTask] {
        (project?.tasks ?? []).filter { $0.id != task.id && $0.archivedAt == nil }.sorted { $0.title < $1.title }
    }

    private var dependencyTitles: String {
        otherCards.filter { dependencyIDs.contains($0.id) }.map(\.title).joined(separator: ", ")
    }

    /// Unfinished steps first, then finished ones (they sink), each in their order.
    private var orderedSteps: [StepDraft] { steps.filter { !$0.isDone } + steps.filter(\.isDone) }

    private func jiraKey(_ url: String) -> String? {
        url.range(of: #"[A-Z][A-Z0-9]+-\d+"#, options: .regularExpression).map { String(url[$0]) }
    }

    private func load() {
        title = task.title
        let document = NotesCodec.resolved(fromRich: task.notesRich, markdown: task.notes)
        notes = NotesAttributedString.attributedString(from: document)
        loadedNotes = notes
        priority = TaskPriority(rawValue: min(max(task.priority, 0), 2)) ?? .low
        isCritical = task.isCritical
        columnID = task.column?.id
        row = task.resource.flatMap { $0.archivedAt == nil ? .resource($0.id) : nil } ?? .unassigned
        labelIDs = Set(task.labels.map(\.id))
        hasStart = task.startDate != nil
        start = task.startDate ?? Date()
        hasDue = task.dueDate != nil
        due = task.dueDate ?? Date()
        hasEstimate = task.estimateHours != nil
        estimate = task.estimateHours ?? (project?.defaultEstimateHours ?? 4)
        jiraURL = task.jiraURL ?? ""
        isBlocked = task.isBlocked
        blockedReason = task.blockedReason ?? ""
        dependencyIDs = Set(task.dependsOn.map(\.id))
        steps = KanbanService.orderedSubtasks(task).map { StepDraft(id: $0.id, title: $0.title, isDone: $0.isDone) }
    }

    private func addStep() {
        let text = newStep.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        steps.append(StepDraft(id: UUID(), title: text, isDone: false, isNew: true))
        newStep = ""
    }

    /// Checks every draft value before anything is saved.
    private func problem() -> String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "A card needs a title." }
        if !trimmedJira.isEmpty, !KanbanMetrics.isWebURL(trimmedJira) { return "The Jira link must be a web address." }
        if hasEstimate, !(estimate.isFinite && estimate >= 0) { return "An estimate can't be negative." }
        if steps.contains(where: { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }) { return "Every subtask needs a title." }
        return nil
    }

    private func save() {
        if let problem = problem() { error = problem; return }
        guard let project else { return dismiss() }
        let service = app.kanbanService(context)
        let day = Calendar.current.startOfDay
        let currentRow: KanbanRowKey = task.resource.flatMap { $0.archivedAt == nil ? .resource($0.id) : nil } ?? .unassigned
        do {
            // The move first: a blocking WIP limit refuses it before anything else is saved.
            if let columnID, columnID != task.column?.id || row != currentRow {
                try service.move(.cards([task.id], to: .cell(columnID: columnID, row: row, beforeCardID: nil)), in: project)
            }
            var values: [KanbanService.TaskField: KanbanValue?] = [
                .title: .string(title.trimmingCharacters(in: .whitespaces)),
                .priority: .int(priority.rawValue),
                .isCritical: .bool(isCritical),
                .startDate: hasStart ? .date(day(start)) : nil,
                .dueDate: hasDue ? .date(day(due)) : nil,
                .estimateHours: hasEstimate ? .double(estimate) : nil,
                .jiraURL: trimmedJira.isEmpty ? nil : .string(trimmedJira),
                .isBlocked: .bool(isBlocked),
                .blockedReason: isBlocked && !blockedReason.trimmingCharacters(in: .whitespaces).isEmpty
                    ? .string(blockedReason.trimmingCharacters(in: .whitespaces)) : nil,
            ]
            if notes != loadedNotes {
                let document = NotesAttributedString.document(from: notes)
                values[.notesRich] = .data(try NotesCodec.encode(document))
                values[.notes] = .string(document.plainText)
            }
            try service.edit(task, values)
            if labelIDs != Set(task.labels.map(\.id)) {
                try service.setLabels(task, project.labels.filter { labelIDs.contains($0.id) })
            }
            if dependencyIDs != Set(task.dependsOn.map(\.id)) {
                try service.setDependencies(task, project.tasks.filter { dependencyIDs.contains($0.id) })
            }
            let suggest = try saveSteps(service)
            if suggest, task.column?.kind != .done { suggestDone = true } else { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Applies step deletions, renames, ticks and additions; returns whether to suggest Done.
    private func saveSteps(_ service: KanbanService) throws -> Bool {
        var suggest = false
        let kept = Set(steps.map(\.id))
        for subtask in task.subtasks where !kept.contains(subtask.id) { try service.deleteSubtask(subtask) }
        for draft in steps {
            let subtask: KanbanSubtask
            if draft.isNew {
                subtask = try service.addSubtask(to: task, title: draft.title.trimmingCharacters(in: .whitespaces))
            } else {
                guard let existing = task.subtasks.first(where: { $0.id == draft.id }) else { continue }
                subtask = existing
                try service.renameSubtask(subtask, draft.title)
            }
            if subtask.isDone != draft.isDone, try service.setSubtaskDone(subtask, draft.isDone) { suggest = true }
        }
        return suggest
    }

    private func moveToDone() {
        guard let project, let done = project.orderedColumns.first(where: { $0.kind == .done }) else { return dismiss() }
        let row: KanbanRowKey = task.resource.flatMap { $0.archivedAt == nil ? .resource($0.id) : nil } ?? .unassigned
        perform { try $0.move(.cards([task.id], to: .cell(columnID: done.id, row: row, beforeCardID: nil)), in: project) }
    }

    private func revert(_ entry: KanbanActivity) {
        do {
            _ = try app.kanbanService(context).revert(entry)
            load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func perform(_ change: (KanbanService) throws -> Void) {
        do {
            try change(app.kanbanService(context))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Toggleable chips that wrap onto new lines.
struct FlowChips: View {
    let items: [(id: UUID, name: String, color: Color)]
    @Binding var selected: Set<UUID>

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(items, id: \.id) { item in
                let on = selected.contains(item.id)
                Button {
                    if on { selected.remove(item.id) } else { selected.insert(item.id) }
                } label: {
                    Text(item.name)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(item.color.opacity(on ? 0.45 : 0.12)))
                        .overlay(Capsule().strokeBorder(on ? item.color : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("kanban-editor-label-\(item.name)")
            }
        }
    }
}

/// A simple wrapping row layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
