import SwiftUI
import SwiftData

/// Full task editor presented as a sheet: title, rich details, time, priority,
/// Critical, repeat, and subtasks. Every field is edited as a draft and committed
/// in one transaction on Done (`TaskEditCommit`); Cancel or Esc discards it all.
///
/// On a recurring series, title, time, reminder, priority, and Critical are shared:
/// changing one updates every occurrence. Details and subtasks belong to the opened
/// occurrence only, and the repeat rule can be changed or stopped from any of them.
struct TaskEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let task: TaskItem

    @State private var shared: SharedAttributes
    @State private var originalShared: SharedAttributes
    @State private var notesText: AttributedString
    @State private var loadedNotes: AttributedString
    @State private var subtasks: [SubtaskDraft]
    @State private var originalSubtasks: [SubtaskDraft]
    @State private var newSubtask = ""

    /// The owning series' rule when `task` is an occurrence; `nil` for a one-off.
    @State private var seriesRule: RecurrenceRule?
    @State private var repeatEnabled = false
    @State private var rule: RecurrenceDraft
    @State private var loadedRule: RecurrenceDraft
    @State private var saveError: String?

    init(task: TaskItem) {
        self.task = task
        let attributes = SharedAttributes(task)
        _shared = State(initialValue: attributes)
        _originalShared = State(initialValue: attributes)
        let notes = NotesAttributedString.attributedString(
            from: NotesCodec.resolved(fromRich: task.notesRich, markdown: task.notes))
        _notesText = State(initialValue: notes)
        _loadedNotes = State(initialValue: notes)
        let drafts = SubtaskDraft.drafts(of: task)
        _subtasks = State(initialValue: drafts)
        _originalSubtasks = State(initialValue: drafts)

        let definition = task.modelContext.flatMap { try? RecurrenceMaterializer.definition(for: task, context: $0) }
        let existing = definition?.recurrence
        _seriesRule = State(initialValue: existing)
        let draft = existing.map { RecurrenceDraft(rule: $0) }
            ?? RecurrenceDraft(newOn: task.dayKey.flatMap { WeekMath.date(fromDayKey: $0) })
        _rule = State(initialValue: draft)
        _loadedRule = State(initialValue: draft)
    }

    /// An occurrence of a series (it shares attributes and has a rule to edit).
    private var isSeriesOccurrence: Bool { seriesRule != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                titleSection
                notesSection
                attributesSection
                if isSeriesOccurrence || task.dayKey != nil { recurrenceSection }
                subtasksSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 580)
        .alert("Couldn’t save the task", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your changes are still here. \(saveError ?? "")")
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("editor-cancel")
            Spacer()
            Text("Edit Task").font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Done") { finish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("editor-done")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var titleSection: some View {
        Section {
            // A vertical-axis TextField only grows to show wrapped lines when given
            // a line-limit RANGE; without it the field stays one line tall and the
            // second line is clipped. `fixedSize(vertical:)` makes the row adopt the
            // field's full height (same pattern TaskRowView uses for wrapped titles).
            TextField("Title", text: $shared.title, axis: .vertical)
                .font(.system(size: 20, weight: .semibold))
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("editor-title")
        }
    }

    private var notesSection: some View {
        Section {
            RichNotesEditor(text: $notesText)
        } header: {
            Text("Details")
        } footer: {
            if isSeriesOccurrence {
                caption("Only this occurrence. Other repeats start with empty notes.", id: "caption-details")
            }
        }
    }

    private var attributesSection: some View {
        Section {
            Toggle("Set time", isOn: timeEnabled)
                .accessibilityIdentifier("editor-time-toggle")
            if shared.timeMinutes != nil {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                Toggle("Remind me at this time", isOn: $shared.alarmEnabled)
                    .accessibilityIdentifier("editor-reminder-toggle")
            }
            Picker("Priority", selection: priorityBinding) {
                ForEach(TaskPriority.allCases) { priority in
                    Label(priority.label, systemImage: priority.symbol).tag(priority)
                }
            }
            Toggle(isOn: $shared.isCritical) {
                Label("Critical", systemImage: "flag.fill")
            }
            .help("Mark this task critical — shown with a red flag before its priority, independent of the priority level.")
        } footer: {
            if isSeriesOccurrence {
                caption("Title, time, reminder, priority, and Critical apply to every occurrence, including completed ones.",
                        id: "caption-shared")
            }
        }
    }

    private var recurrenceSection: some View {
        Section {
            if isSeriesOccurrence {
                ruleControls
                if !draftHasEnded {
                    Button("Stop Repeating", role: .destructive) {
                        rule.endMode = .on
                        rule.endDate = Calendar.current.startOfDay(for: Date())
                    }
                    .accessibilityIdentifier("repeat-stop")
                }
            } else {
                Toggle("Repeat this task", isOn: $repeatEnabled)
                    .accessibilityIdentifier("repeat-toggle")
                if repeatEnabled { ruleControls }
            }
        } header: {
            Text("Repeat")
        } footer: {
            if isSeriesOccurrence {
                caption(draftHasEnded
                        ? "Stopped repeating. Past, completed, and changed occurrences are kept; untouched future ones are removed."
                        : "Schedule changes apply after today. Past, completed, and changed occurrences are kept.",
                        id: "caption-repeat")
            }
        }
    }

    @ViewBuilder private var ruleControls: some View {
        Picker("Frequency", selection: $rule.frequency) {
            ForEach(RecurrenceFrequency.editableCases) { freq in
                Text(freq.editorLabel).tag(freq)
            }
        }
        .accessibilityIdentifier("repeat-frequency")

        if rule.frequency != .weekdays {
            Stepper(value: $rule.interval, in: 1...365) {
                Text("Every \(rule.interval) \(rule.frequency.unitLabel(rule.interval))")
            }
        }

        if rule.frequency == .weekly {
            weekdayPicker
        }

        // An imported "1st and 15th" rule keeps its day numbers unless the frequency changes.
        if rule.frequency == .monthly, let original = seriesRule, original.frequency == .daysOfMonth {
            Text("On days \(Set(original.monthDays).sorted().map(String.init).joined(separator: ", ")) of the month")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("repeat-month-days")
        }

        Picker("Ends", selection: $rule.endMode) {
            Text("Never").tag(RecurrenceDraft.EndMode.never)
            Text("After a number of times").tag(RecurrenceDraft.EndMode.after)
            Text("On a date").tag(RecurrenceDraft.EndMode.on)
        }

        switch rule.endMode {
        case .never:
            EmptyView()
        case .after:
            Stepper(value: $rule.endCount, in: 1...999) {
                Text("\(rule.endCount) time\(rule.endCount == 1 ? "" : "s")")
            }
        case .on:
            DatePicker("End date", selection: $rule.endDate, displayedComponents: .date)
        }
    }

    private var weekdayPicker: some View {
        // Calendar weekday convention: 1 = Sunday … 7 = Saturday.
        let symbols = Calendar.current.shortWeekdaySymbols
        return HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                let on = rule.weekdays.contains(day)
                Button(symbols[day - 1]) {
                    if on { rule.weekdays.remove(day) } else { rule.weekdays.insert(day) }
                }
                .buttonStyle(.bordered)
                .tint(on ? .accentColor : nil)
                .accessibilityIdentifier("weekday-\(day)")
            }
        }
    }

    private var subtasksSection: some View {
        Section {
            ForEach($subtasks) { $draft in
                SubtaskRow(subtask: $draft) { subtasks.removeAll { $0.id == draft.id } }
            }
            HStack {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("Add subtask", text: $newSubtask)
                    .onSubmit(addSubtask)
                    .accessibilityIdentifier("editor-add-subtask")
            }
        } header: {
            Text("Subtasks")
        } footer: {
            if isSeriesOccurrence { caption("Only this occurrence.", id: "caption-subtasks") }
        }
    }

    private func caption(_ text: String, id: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(id)
    }

    // MARK: - Bindings

    private var timeEnabled: Binding<Bool> {
        Binding(
            get: { shared.timeMinutes != nil },
            set: { on in
                shared.timeMinutes = on ? (shared.timeMinutes ?? 9 * 60) : nil
                // A reminder needs a time: never leave a bell on an untimed task.
                if !on { shared.alarmEnabled = false }
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let minutes = shared.timeMinutes ?? 9 * 60
                return Calendar.current.date(
                    bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                shared.timeMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            }
        )
    }

    private var priorityBinding: Binding<TaskPriority> {
        Binding(get: { TaskPriority(rawValue: min(max(shared.priority, 0), 2)) ?? .low },
                set: { shared.priority = $0.rawValue })
    }

    private var draftHasEnded: Bool {
        rule.endMode == .on && Calendar.current.startOfDay(for: rule.endDate) <= Calendar.current.startOfDay(for: Date())
    }

    // MARK: - Actions

    private func addSubtask() {
        let title = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let next = (subtasks.map(\.sortIndex).max() ?? 0) + 1
        subtasks.append(SubtaskDraft(id: UUID(), title: title, isDone: false, sortIndex: next))
        newSubtask = ""
    }

    private var ruleChange: TaskEdit.RuleChange {
        if let seriesRule {
            guard !rule.isEquivalent(to: loadedRule) else { return .unchanged }
            return .replace(rule.rule(replacing: seriesRule, startDate: seriesRule.startDate))
        }
        guard repeatEnabled, let day = task.dayKey.flatMap({ WeekMath.date(fromDayKey: $0) }) else { return .unchanged }
        return .startSeries(rule.rule(replacing: nil, startDate: day))
    }

    private func finish() {
        let edit = TaskEdit(
            originalShared: originalShared,
            editedShared: shared,
            notes: notesText == loadedNotes ? nil : NotesAttributedString.document(from: notesText),
            subtasks: subtasks == originalSubtasks ? nil : subtasks,
            rule: ruleChange
        )
        let horizon = Calendar.current.date(byAdding: .day, value: RecurrenceMaterializer.defaultHorizonDays,
                                            to: Date()) ?? Date()
        #if DEBUG
        if UITestSupport.failNextTaskSave {
            UITestSupport.failNextTaskSave = false
            PersistenceFaults.armed.insert(.transaction)
        }
        #endif
        do {
            let scheduleChanged = try TaskEditCommit.commit(edit, to: task, context: context, horizon: horizon)
            if scheduleChanged { NotificationCenter.default.post(name: .tickyTaskSeriesChanged, object: nil) }
            if !edit.isEmpty {
                Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
            }
            dismiss()
        } catch {
            NSLog("TickyTask: saving task edits failed: \(error.localizedDescription)")
            saveError = error.localizedDescription
        }
    }
}

private extension RecurrenceFrequency {
    var editorLabel: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays: return "Every weekday (Mon–Fri)"
        case .weekly, .customWeekdays: return "Weekly"
        case .monthly, .daysOfMonth: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    /// The unit noun for the "Every N …" stepper, pluralized for `count`.
    func unitLabel(_ count: Int) -> String {
        let unit: String
        switch self {
        case .daily: unit = "day"
        case .weekly, .customWeekdays: unit = "week"
        case .monthly, .daysOfMonth: unit = "month"
        case .yearly: unit = "year"
        case .weekdays: unit = "week"
        }
        return count == 1 ? unit : unit + "s"
    }
}

/// A single editable subtask draft inside the editor.
private struct SubtaskRow: View {
    @Binding var subtask: SubtaskDraft
    var onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack {
            Button { subtask.isDone.toggle() } label: {
                Image(systemName: subtask.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(subtask.isDone ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 20)
            .accessibilityIdentifier("subtask-toggle-\(subtask.title)")

            TextField("Subtask", text: $subtask.title)
                .strikethrough(subtask.isDone)

            if isHovering {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
