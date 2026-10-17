import SwiftUI
import SwiftData

/// The card editor (design 01 §5, D4): the planner editor's title, notes, priority,
/// Critical and checklist pieces, plus the Kanban fields. Edits are drafts until Done,
/// which validates everything first, then applies the move, the field edit, labels,
/// dependencies and steps through `KanbanService`.
struct KanbanTaskEditor: View {
    enum Mode {
        case edit(KanbanTask)
        case create(project: KanbanProject, column: UUID?, row: KanbanRowKey)
    }

    let mode: Mode
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    struct StepDraft: Identifiable, Equatable {
        var id: UUID
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
    @State private var schedulingDay: Date?
    @State private var scheduledNote: String?
    @FocusState private var titleFocused: Bool
    @State private var showLabelManager = false

    // MARK: - Initialization

    init(task: KanbanTask) {
        self.mode = .edit(task)
    }

    init(newCardIn project: KanbanProject, column: UUID?, row: KanbanRowKey) {
        self.mode = .create(project: project, column: column ?? project.orderedColumns.first(where: { $0.kind == .backlog })?.id, row: row)
    }

    private var task: KanbanTask? {
        guard case .edit(let t) = mode else { return nil }
        return t
    }

    private var project: KanbanProject? {
        switch mode {
        case .edit(let t): return t.project
        case .create(let p, _, _): return p
        }
    }

    private var isCreateMode: Bool {
        guard case .create = mode else { return false }
        return true
    }

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
                        .focused($titleFocused)
                }
                Section("Details") { RichNotesEditor(text: $notes) }
                placementSection
                attributesSection
                datesSection
                linksSection
                stepsSection
                if !isCreateMode { historySection }
            }
            .formStyle(.grouped)
            if isCreateMode {
                Divider()
            } else {
                footer
            }
        }
        .frame(minWidth: 580, minHeight: 640)
        .onAppear {
            load()
            if isCreateMode {
                titleFocused = true
            }
        }
        .alert("Couldn't save the card", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your changes are still here. \(error ?? "")")
        }
        .alert("All steps are done", isPresented: $suggestDone) {
            Button("Move to Done") { moveToDone() }
            Button("Not now", role: .cancel) { dismiss() }
        } message: {
            if let task { Text("Move \"\(task.title)\" to Done?") }
        }
        .confirmationDialog("Delete card?", isPresented: $confirmDelete) {
            if let task {
                Button("Delete Card", role: .destructive) { perform { try $0.deleteTask(task) } }
            }
        } message: {
            if let task { Text("You can bring it back from the Change Log.") }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("kanban-editor-cancel")
            Spacer()
            Text(isCreateMode ? "New card" : (project?.name ?? "")).font(.headline)
            Spacer()
            Button("Done", action: save)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && isCreateMode)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("kanban-editor-done")
        }
        .padding(12)
    }

    private var placementSection: some View {
        Section("On the board") {
            Picker("Column", selection: $columnID) {
                ForEach(project?.orderedColumns ?? []) { column in
                    let style = KanbanColumnStyle(kind: column.kind, customColorHex: column.colorHex)
                    HStack(spacing: 4) {
                        Image(systemName: style.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(style.effectiveAccent)
                        Text(column.name)
                    }
                    .tag(Optional(column.id))
                }
            }
            .help(project?.orderedColumns.first.map { "Column: \(KanbanColumnStyle(kind: $0.kind, customColorHex: $0.colorHex).kindName)" } ?? "")
            .accessibilityIdentifier("kanban-editor-column")
            Picker("Assignee", selection: $row) {
                Text("Unassigned").tag(KanbanRowKey.unassigned)
                ForEach(activeMemberships) { Text($0.displayName).tag(KanbanRowKey.resource($0.id)) }
            }
            .accessibilityIdentifier("kanban-editor-assignee")
            if let labels = project?.labels.sorted(by: { $0.sortIndex < $1.sortIndex }), !labels.isEmpty {
                LabeledContent("Labels") {
                    VStack(alignment: .leading, spacing: 8) {
                        FlowChips(items: labels.map { ($0.id, $0.name, KanbanUI.color($0.colorHex) ?? .gray) }, selected: $labelIDs)
                        Button("Edit labels…") { showLabelManager = true }
                            .font(.caption)
                            .accessibilityIdentifier("kanban-editor-edit-labels")
                    }
                }
            }
        }
        .sheet(isPresented: $showLabelManager) {
            if let project {
                KanbanLabelManagerSheet(project: project)
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
                        Toggle(displayTitle(card), isOn: Binding(
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
                    } else if KanbanService.offersRevert(entry) {
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
            if let task {
                Button("Archive") { perform { try $0.archiveTask(task) } }
                    .accessibilityIdentifier("kanban-editor-archive")
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("kanban-editor-delete")
                Button("Schedule to day…") { schedulingDay = task.dueDate ?? Date() }
                    .help("Put this card on a day in the planner (once linked, rescheduling moves that task)")
                    .accessibilityIdentifier("kanban-editor-schedule")
                    .popover(isPresented: Binding(get: { schedulingDay != nil }, set: { if !$0 { schedulingDay = nil } })) {
                        VStack(alignment: .leading, spacing: 10) {
                            DatePicker("Day", selection: Binding(get: { schedulingDay ?? Date() }, set: { schedulingDay = $0 } ), displayedComponents: .date)
                                .datePickerStyle(.graphical)
                            Button("Schedule") { schedule() }
                                .keyboardShortcut(.defaultAction)
                                .accessibilityIdentifier("kanban-editor-schedule-confirm")
                        }
                        .padding(12)
                    }
                if let scheduledNote { Text(scheduledNote).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Data

    private var activeMemberships: [KanbanResource] {
        (project?.resources ?? []).filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Live cards, plus archived ones this card still depends on (so they can be removed).
    private var otherCards: [KanbanTask] {
        let taskID = task?.id
        return (project?.tasks ?? []).filter { taskID == nil || ($0.id != taskID && ($0.archivedAt == nil || dependencyIDs.contains($0.id))) }
            .sorted { $0.title < $1.title }
    }

    private func displayTitle(_ card: KanbanTask) -> String { card.archivedAt == nil ? card.title : "\(card.title) (archived)" }

    private var dependencyTitles: String {
        otherCards.filter { dependencyIDs.contains($0.id) }.map(displayTitle).joined(separator: ", ")
    }

    /// Unfinished steps first, then finished ones (they sink), each in their order.
    private var orderedSteps: [StepDraft] { steps.filter { !$0.isDone } + steps.filter(\.isDone) }

    private func jiraKey(_ url: String) -> String? {
        url.range(of: #"[A-Z][A-Z0-9]+-\d+"#, options: .regularExpression).map { String(url[$0]) }
    }

    private func load() {
        if let task {
            // Edit mode: load from existing task
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
        } else {
            // Create mode: use initial values from mode
            if case .create(_, let col, let r) = mode {
                columnID = col
                row = r
            }
            priority = .low
            isCritical = false
            estimate = project?.defaultEstimateHours ?? 4
        }
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

    /// Checks everything first, so no step can be refused once saving starts; each step is
    /// then its own Change Log entry. If a save itself fails, the message says what's saved.
    private func save() {
        if let problem = problem() { error = problem; return }
        guard let project else { return dismiss() }

        if isCreateMode {
            saveCreate(project)
        } else {
            saveEdit(project)
        }
    }

    private func saveCreate(_ project: KanbanProject) {
        let service = app.kanbanService(context)
        let day = Calendar.current.startOfDay

        var draft = KanbanCardDraft()
        draft.title = title.trimmingCharacters(in: .whitespaces)
        draft.columnID = columnID
        draft.row = row
        draft.priority = priority.rawValue
        draft.isCritical = isCritical
        draft.startDate = hasStart ? day(start) : nil
        draft.dueDate = hasDue ? day(due) : nil
        draft.estimateHours = hasEstimate ? estimate : nil
        draft.jiraURL = trimmedJira.isEmpty ? nil : trimmedJira
        draft.isBlocked = isBlocked
        draft.blockedReason = isBlocked && !blockedReason.trimmingCharacters(in: .whitespaces).isEmpty
            ? blockedReason.trimmingCharacters(in: .whitespaces) : nil
        draft.labelIDs = Array(labelIDs)
        draft.dependencyIDs = Array(dependencyIDs)
        draft.steps = steps.map { KanbanCardDraft.Step(title: $0.title, isDone: $0.isDone, assigneeID: nil) }

        if notes != loadedNotes {
            let document = NotesAttributedString.document(from: notes)
            do {
                draft.notesRich = try NotesCodec.encode(document)
                draft.notes = document.plainText
            } catch {
                self.error = error.localizedDescription
                return
            }
        }

        do {
            _ = try service.createCard(draft, in: project)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveEdit(_ project: KanbanProject) {
        guard let task else { return dismiss() }
        let service = app.kanbanService(context)
        let day = Calendar.current.startOfDay
        let currentRow: KanbanRowKey = task.resource.flatMap { $0.archivedAt == nil ? .resource($0.id) : nil } ?? .unassigned
        let move: MoveOp? = columnID.flatMap { id in
            id != task.column?.id || row != currentRow ? .cards([task.id], to: .cell(columnID: id, row: row, beforeCardID: nil)) : nil
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
        let labels = labelIDs != Set(task.labels.map(\.id)) ? project.labels.filter { labelIDs.contains($0.id) } : nil
        let prerequisites = dependencyIDs != Set(task.dependsOn.map(\.id)) ? project.tasks.filter { dependencyIDs.contains($0.id) } : nil
        do {
            if notes != loadedNotes {
                let document = NotesAttributedString.document(from: notes)
                values[.notesRich] = .data(try NotesCodec.encode(document))
                values[.notes] = .string(document.plainText)
            }
            if let move { try service.checkMove(move, in: project) }
            try KanbanService.checkEdit(values)
            if let prerequisites { try service.checkDependencies(task, prerequisites) }
        } catch {
            self.error = error.localizedDescription
            return
        }
        var saved: [String] = []
        do {
            if let move { try service.move(move, in: project); saved.append("the move") }
            try service.edit(task, values)
            saved.append("the details")
            if let labels { try service.setLabels(task, labels); saved.append("labels") }
            if let prerequisites { try service.setDependencies(task, prerequisites); saved.append("dependencies") }
            loadedNotes = notes
            let suggest = try saveSteps(service, saved: &saved)
            if suggest, task.column?.kind != .done { suggestDone = true } else { dismiss() }
        } catch {
            self.error = saved.isEmpty ? error.localizedDescription
                : "\(error.localizedDescription) Already saved: \(saved.joined(separator: ", ")). Press Done to save the rest."
        }
    }

    /// Applies step deletions, renames, ticks and additions. A new step takes its saved id at
    /// once, so pressing Done again never adds it twice. Suggests Done only when a tick
    /// finished the list and every step on the card is done afterwards.
    private func saveSteps(_ service: KanbanService, saved: inout [String]) throws -> Bool {
        guard let task else { return false }
        var ticked = false
        let kept = Set(steps.map(\.id))
        for subtask in task.subtasks where !kept.contains(subtask.id) {
            try service.deleteSubtask(subtask)
            saved.insertIfMissing("subtasks")
        }
        for index in steps.indices {
            let draft = steps[index]
            let subtask: KanbanSubtask
            if draft.isNew {
                subtask = try service.addSubtask(to: task, title: draft.title.trimmingCharacters(in: .whitespaces))
                steps[index] = StepDraft(id: subtask.id, title: subtask.title, isDone: draft.isDone)
                saved.insertIfMissing("subtasks")
            } else {
                guard let existing = task.subtasks.first(where: { $0.id == draft.id }) else { continue }
                subtask = existing
                if subtask.title != draft.title.trimmingCharacters(in: .whitespaces) {
                    try service.renameSubtask(subtask, draft.title)
                    saved.insertIfMissing("subtasks")
                }
            }
            if subtask.isDone != draft.isDone {
                if try service.setSubtaskDone(subtask, draft.isDone) { ticked = true }
                saved.insertIfMissing("subtasks")
            }
        }
        return ticked && !task.subtasks.isEmpty && task.subtasks.allSatisfy(\.isDone)
    }

    private func schedule() {
        guard let day = schedulingDay, let task else { return }
        do {
            try app.kanbanService(context).schedule(task, on: WeekMath.dayKey(for: day))
            scheduledNote = "On the planner for \(day.formatted(date: .abbreviated, time: .omitted))."
            schedulingDay = nil
            Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func moveToDone() {
        guard let project, let done = project.orderedColumns.first(where: { $0.kind == .done }), let task else { return dismiss() }
        let row: KanbanRowKey = task.resource.flatMap { $0.archivedAt == nil ? .resource($0.id) : nil } ?? .unassigned
        perform { try $0.move(.cards([task.id], to: .cell(columnID: done.id, row: row, beforeCardID: nil)), in: project) }
    }

    private func revert(_ entry: KanbanActivity) {
        guard let task else { return }
        let id = task.id, project = self.project
        do {
            _ = try app.kanbanService(context).revert(entry)
            // Reverting the card's creation removes it.
            if task.isDeleted || project?.tasks.contains(where: { $0.id == id }) != true { dismiss() } else { load() }
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

private extension Array where Element == String {
    mutating func insertIfMissing(_ item: String) { if !contains(item) { append(item) } }
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
