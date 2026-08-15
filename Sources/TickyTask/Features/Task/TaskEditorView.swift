import SwiftUI
import SwiftData

/// Full task editor presented as a sheet: title, Markdown details (edit/preview),
/// time, priority, color, and subtasks. Edits bind directly to the model and are
/// saved on Done.
struct TaskEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var task: TaskItem

    @State private var notesMode: NotesMode = .edit
    @State private var newSubtask = ""

    enum NotesMode: String, CaseIterable, Identifiable {
        case edit = "Edit"
        case preview = "Preview"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                titleSection
                notesSection
                attributesSection
                subtasksSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 580)
    }

    private var header: some View {
        HStack {
            Text("Edit Task").font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Done") { finish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
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
            Picker("Notes mode", selection: $notesMode) {
                ForEach(NotesMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            if notesMode == .edit {
                TextEditor(text: $task.notes)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    }
                Text("Markdown supported — **bold**, *italic*, `code`, [links](https://…)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                MarkdownText(task.notes)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }
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

    private func finish() {
        task.updatedAt = Date()
        try? context.save()
        // Reconcile per-task reminders so enabling/disabling/rescheduling an
        // alarm takes effect immediately, not just on next launch.
        Task { @MainActor in await NotificationService.syncTaskReminders(context: context) }
        dismiss()
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
