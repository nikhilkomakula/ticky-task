import SwiftUI
import SwiftData

/// Full task editor presented as a sheet: title, Markdown details (edit/preview),
/// time, priority, color, and subtasks. Edits bind directly to the model and are
/// saved on Done.
struct TaskEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var task: TaskItem

    @State private var notesText = AttributedString()
    /// The last notes value loaded or persisted. Assigning `notesText` in
    /// `onAppear` triggers `onChange`; this guard keeps opening a task from
    /// rewriting its legacy Markdown source or bumping `updatedAt`.
    @State private var persistedNotes = AttributedString()
    @State private var newSubtask = ""

    // Recurrence editing state — mirrors `task.recurrence`, applied on Done so the
    // series isn't regenerated on every keystroke. The "Repeat" section is shown
    // only for a day task that can own a rule (not a generated occurrence).
    @State private var repeatEnabled = false
    @State private var frequency: RecurrenceFrequency = .daily
    @State private var interval = 1
    @State private var weekdays: Set<Int> = []
    @State private var endMode: RecurrenceEndMode = .never
    @State private var endCount = 10
    @State private var endDate = Date()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                titleSection
                notesSection
                attributesSection
                if canRepeat { recurrenceSection }
                subtasksSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 580)
        .onAppear {
            let resolved = NotesAttributedString.attributedString(
                from: NotesCodec.resolved(fromRich: task.notesRich, markdown: task.notes)
            )
            notesText = resolved
            persistedNotes = resolved
            loadRecurrence()
        }
        .onChange(of: notesText) { _, newValue in
            // Skip the load-induced change (and any no-op) so opening a task never
            // rewrites its notes or timestamp — only genuine edits persist.
            guard newValue != persistedNotes else { return }
            let document = NotesAttributedString.document(from: newValue)
            task.notesRich = try? NotesCodec.encode(document)
            task.notes = document.plainText
            task.updatedAt = Date()
            persistedNotes = newValue
        }
    }

    private var header: some View {
        HStack {
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
            TextField("Title", text: $task.title, axis: .vertical)
                .font(.system(size: 20, weight: .semibold))
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("editor-title")
        }
    }

    private var notesSection: some View {
        Section("Details") {
            RichNotesEditor(text: $notesText)
        }
    }

    private var attributesSection: some View {
        Section {
            Toggle("Set time", isOn: timeEnabled)
            if task.timeMinutes != nil {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                Toggle("Remind me at this time", isOn: $task.alarmEnabled)
            }
            Picker("Priority", selection: priorityBinding) {
                ForEach(TaskPriority.allCases) { priority in
                    Label(priority.label, systemImage: priority.symbol).tag(priority)
                }
            }
            Toggle(isOn: $task.isCritical) {
                Label("Critical", systemImage: "flag.fill")
            }
            .help("Mark this task critical — shown with a red flag before its priority, independent of the priority level.")
        }
    }

    /// Only a day task that isn't itself a generated occurrence can own a rule —
    /// an occurrence's schedule is controlled by its template.
    private var canRepeat: Bool { task.dayKey != nil && task.templateID == nil }

    private var recurrenceSection: some View {
        Section("Repeat") {
            Toggle("Repeat this task", isOn: $repeatEnabled)
                .accessibilityIdentifier("repeat-toggle")

            if repeatEnabled {
                Picker("Frequency", selection: $frequency) {
                    ForEach(RecurrenceFrequency.editableCases) { freq in
                        Text(freq.editorLabel).tag(freq)
                    }
                }

                if frequency != .weekdays {
                    Stepper(value: $interval, in: 1...365) {
                        Text("Every \(interval) \(frequency.unitLabel(interval))")
                    }
                }

                if frequency == .weekly {
                    weekdayPicker
                }

                Picker("Ends", selection: $endMode) {
                    Text("Never").tag(RecurrenceEndMode.never)
                    Text("After a number of times").tag(RecurrenceEndMode.after)
                    Text("On a date").tag(RecurrenceEndMode.on)
                }

                switch endMode {
                case .never:
                    EmptyView()
                case .after:
                    Stepper(value: $endCount, in: 1...999) {
                        Text("\(endCount) time\(endCount == 1 ? "" : "s")")
                    }
                case .on:
                    DatePicker("End date", selection: $endDate, displayedComponents: .date)
                }
            }
        }
    }

    private var weekdayPicker: some View {
        // Calendar weekday convention: 1 = Sunday … 7 = Saturday.
        let symbols = Calendar.current.shortWeekdaySymbols
        return HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                let on = weekdays.contains(day)
                Button(symbols[day - 1]) {
                    if on { weekdays.remove(day) } else { weekdays.insert(day) }
                }
                .buttonStyle(.bordered)
                .tint(on ? .accentColor : nil)
                .accessibilityIdentifier("weekday-\(day)")
            }
        }
    }

    private var subtasksSection: some View {
        Section("Subtasks") {
            ForEach(task.subtasks.sorted(by: { $0.sortIndex < $1.sortIndex })) { subtask in
                SubtaskRow(subtask: subtask) { delete(subtask) }
            }
            HStack {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("Add subtask", text: $newSubtask)
                    .onSubmit(addSubtask)
            }
        }
    }

    // MARK: - Bindings

    private var timeEnabled: Binding<Bool> {
        Binding(
            get: { task.timeMinutes != nil },
            set: { on in task.timeMinutes = on ? (task.timeMinutes ?? 9 * 60) : nil }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let minutes = task.timeMinutes ?? 9 * 60
                return Calendar.current.date(
                    bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                task.timeMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            }
        )
    }

    private var priorityBinding: Binding<TaskPriority> {
        Binding(get: { task.priorityLevel }, set: { task.priorityLevel = $0 })
    }

    // MARK: - Actions

    private func addSubtask() {
        let title = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        DataService(context).addSubtask(to: task, title: title)
        newSubtask = ""
    }

    private func delete(_ subtask: Subtask) {
        context.delete(subtask)
    }

    // MARK: - Recurrence

    /// Populate the editor's recurrence state from `task.recurrence`. Imported
    /// `.customWeekdays` / `.daysOfMonth` rules are shown as their closest editable
    /// frequency (weekly / monthly); the engine still honors the stored form.
    private func loadRecurrence() {
        guard let rule = task.recurrence else {
            // Sensible default weekday for a fresh weekly rule = the task's own day.
            if let day = task.dayKey.flatMap({ WeekMath.date(fromDayKey: $0) }) {
                weekdays = [Calendar.current.component(.weekday, from: day)]
            }
            return
        }
        repeatEnabled = true
        frequency = rule.frequency.editableEquivalent
        interval = rule.interval
        weekdays = rule.weekdays.isEmpty
            ? [Calendar.current.component(.weekday, from: rule.startDate)]
            : rule.weekdays
        switch rule.end {
        case .never: endMode = .never
        case .afterCount(let n): endMode = .after; endCount = max(1, n)
        case .until(let date): endMode = .on; endDate = date
        }
    }

    private func buildRule() -> RecurrenceRule {
        let start = task.recurrence?.startDate
            ?? task.dayKey.flatMap { WeekMath.date(fromDayKey: $0) }
            ?? Calendar.current.startOfDay(for: task.createdAt)
        let end: RecurrenceEnd
        switch endMode {
        case .never: end = .never
        case .after: end = .afterCount(max(1, endCount))
        case .on: end = .until(endDate)
        }
        let days: Set<Int> = frequency == .weekly
            ? (weekdays.isEmpty ? [Calendar.current.component(.weekday, from: start)] : weekdays)
            : []
        return RecurrenceRule(
            frequency: frequency,
            interval: frequency == .weekdays ? 1 : max(1, interval),
            weekdays: days,
            monthDays: [],
            end: end,
            startDate: start
        )
    }

    /// Apply recurrence edits when they actually changed, then regenerate the
    /// series (or detach it when repeat was turned off). The rule change and the
    /// (re)generation commit together: the materializer saves, and on failure we
    /// roll back so the rule never persists alongside stale occurrences. Callers
    /// must persist unrelated edits (title/notes) *before* this, since a rollback
    /// reverts every pending change in the context.
    private func applyRecurrence() {
        guard canRepeat else { return }
        let newRule = repeatEnabled ? buildRule() : nil
        guard newRule != task.recurrence else { return }
        let hadRule = task.recurrence != nil
        task.recurrence = newRule
        task.updatedAt = Date()

        let todayKey = WeekMath.dayKey(for: Date())
        let horizon = Calendar.current.date(
            byAdding: .day, value: RecurrenceMaterializer.defaultHorizonDays, to: Date()
        ) ?? Date()
        do {
            if newRule != nil {
                try RecurrenceMaterializer.regenerateFuture(
                    for: task, todayKey: todayKey, through: horizon, context: context
                )
            } else if hadRule {
                try RecurrenceMaterializer.removeRecurrence(from: task, context: context)
            } else {
                try context.save()
            }
        } catch {
            context.rollback()
            NSLog("TickyTask: applying recurrence failed: \(error.localizedDescription)")
        }
    }

    private func finish() {
        task.updatedAt = Date()
        // Persist title/notes/attribute edits first, so a recurrence-regeneration
        // failure (which rolls the context back) can't discard them.
        try? context.save()
        applyRecurrence()
        // Reconcile per-task reminders so enabling/disabling/rescheduling an
        // alarm takes effect immediately, not just on next launch.
        Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
        dismiss()
    }
}

/// How a recurrence stops, as three flat editor choices (the model's associated-
/// value `RecurrenceEnd` is rebuilt from these on save).
private enum RecurrenceEndMode: Hashable { case never, after, on }

private extension RecurrenceFrequency {
    /// The frequencies offered in the editor. `.customWeekdays` and `.daysOfMonth`
    /// only arrive via legacy import and are edited as weekly / monthly.
    static var editableCases: [RecurrenceFrequency] { [.daily, .weekdays, .weekly, .monthly, .yearly] }

    /// Map a stored frequency to the editable one that represents it.
    var editableEquivalent: RecurrenceFrequency {
        switch self {
        case .customWeekdays: return .weekly
        case .daysOfMonth: return .monthly
        default: return self
        }
    }

    var editorLabel: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays: return "Every weekday (Mon–Fri)"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .customWeekdays: return "Weekly"
        case .daysOfMonth: return "Monthly"
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

/// A single editable subtask row inside the editor.
private struct SubtaskRow: View {
    @Bindable var subtask: Subtask
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
