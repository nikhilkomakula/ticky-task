import SwiftUI
import SwiftData

/// A cell's details: what the week could hold, the time off counted, the result and any
/// override, with Override…, Clear override, Add time off… and Time off….
struct KanbanAvailabilityCellPopover: View {
    let resource: KanbanResource
    let week: KanbanDay
    let cell: KanbanAvailability.Cell
    var onTimeOff: () -> Void
    var onAddTimeOff: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var halfDays = 0
    @State private var note = ""

    var body: some View {
        let counted = (resource.person?.timeOff ?? []).filter { cell.absenceIDs.contains($0.id) }.sorted { $0.startDay < $1.startDay }
        let stored = resource.availabilityOverrides.first { $0.weekStart == week.key }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.displayName).font(.headline)
                Text("Week of \(KanbanAvailabilityFormat.long(week))").font(.subheadline).foregroundStyle(.secondary)
            }
            if !cell.isActive {
                Text("No working days this week for \(resource.displayName) on this board (outside the board's or their dates, or not a work day).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Possible"); Text("\(KanbanAvailability.days(cell.possibleHalfDays)) days").monospacedDigit() }
                    GridRow { Text("Time off"); Text("\(KanbanAvailability.days(cell.absentHalfDays)) days").monospacedDigit() }
                    GridRow { Text("Computed").bold(); Text("\(KanbanAvailability.days(cell.computedHalfDays)) days").monospacedDigit().bold() }
                    if let stored {
                        GridRow {
                            Text("Override")
                            Text("\(KanbanAvailability.days(stored.halfDays)) days\(stored.note.map { " · \($0)" } ?? "")").monospacedDigit()
                        }
                    }
                }
                .font(.callout)
                if cell.overrideNeedsReview {
                    Label("The override is more than this week's possible days now, so it isn't used. Change or clear it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(KanbanAvailabilityPalette.text(.yellow)).fixedSize(horizontal: false, vertical: true)
                }
                if !counted.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(counted) { entry in
                            Text("\(KanbanService.span(KanbanTimeOffDTO(entry))) · \(entry.kind.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if counted.count > 1 { Text("Days covered more than once count once.").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                if editing {
                    overrideEditor(stored: stored)
                }
            }
            Divider()
            HStack {
                if cell.isActive, !editing {
                    Button("Override…") {
                        halfDays = min(stored?.halfDays ?? cell.computedHalfDays, cell.possibleHalfDays)
                        note = stored?.note ?? ""
                        editing = true
                    }
                    .accessibilityIdentifier("kanban-availability-override")
                }
                if stored != nil, !editing {
                    Button("Clear override") {
                        app.runKanban { try app.kanbanService(context).setOverride(resource, week: week, halfDays: nil) }
                        dismiss()
                    }
                    .accessibilityIdentifier("kanban-availability-clear-override")
                }
                Spacer()
                if !editing {
                    Button("Add time off…", action: onAddTimeOff)
                    Button("Time off…", action: onTimeOff)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func overrideEditor(stored: KanbanAvailabilityOverride?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Replace this week's available days").font(.callout.weight(.semibold))
            Stepper(value: $halfDays, in: 0...cell.possibleHalfDays) {
                Text("\(KanbanAvailability.days(halfDays)) of \(KanbanAvailability.days(cell.possibleHalfDays)) days").monospacedDigit()
            }
            .accessibilityValue("\(KanbanAvailability.days(halfDays)) days")
            .accessibilityIdentifier("kanban-availability-override-days")
            TextField("Note (optional)", text: $note)
            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                Button("Save") {
                    app.runKanban { try app.kanbanService(context).setOverride(resource, week: week, halfDays: halfDays, note: note) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("kanban-availability-override-save")
            }
        }
    }
}

/// What the time-off editor is editing: a new entry for someone (from a week), or an existing one.
struct KanbanTimeOffDraft: Identifiable {
    let id = UUID()
    var person: KanbanPerson?
    var entry: KanbanTimeOff?
    var start: Date
    var end: Date
    var portion: KanbanTimeOffPortion = .full
    var kind: KanbanTimeOffKind = .pto
    var note = ""

    init(person: KanbanPerson?, week: KanbanDay) {
        self.person = person
        start = week.date()
        end = week.adding(days: 4).date()
    }

    init(_ entry: KanbanTimeOff) {
        person = entry.person
        self.entry = entry
        start = KanbanDay(key: entry.startDay)?.date() ?? Date()
        end = KanbanDay(key: entry.endDay)?.date() ?? Date()
        portion = entry.portion
        kind = entry.kind
        note = entry.note ?? ""
    }
}

/// Adds or edits one time-off entry. A morning or afternoon is a single day.
struct KanbanTimeOffEditor: View {
    @State var draft: KanbanTimeOffDraft
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KanbanPerson.name) private var people: [KanbanPerson]
    @State private var error: String?

    private var singleDay: Bool { KanbanDay(draft.start) == KanbanDay(draft.end) }

    var body: some View {
        let members = Set(project.resources.filter { $0.archivedAt == nil }.compactMap { $0.person?.id })
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.entry == nil ? "Add time off" : "Edit time off").font(.headline)
            Form {
                Picker("Person", selection: Binding(get: { draft.person?.id }, set: { id in draft.person = people.first { $0.id == id } })) {
                    ForEach(people.filter { members.contains($0.id) || $0.id == draft.person?.id }) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(draft.entry != nil)
                .accessibilityIdentifier("kanban-time-off-person")
                DatePicker("From", selection: $draft.start, displayedComponents: .date)
                    .onChange(of: draft.start) { _, start in if draft.end < start { draft.end = start } }
                    .accessibilityIdentifier("kanban-time-off-start")
                DatePicker("To", selection: $draft.end, in: draft.start..., displayedComponents: .date)
                    .accessibilityIdentifier("kanban-time-off-end")
                Picker("Day", selection: $draft.portion) {
                    ForEach(KanbanTimeOffPortion.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(!singleDay)
                .help(singleDay ? "Full day, morning or afternoon" : "A range is whole days; pick one day for a morning or afternoon")
                Picker("Type", selection: $draft.kind) {
                    ForEach(KanbanTimeOffKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Note (optional)", text: $draft.note)
            }
            .formStyle(.grouped)
            .frame(width: 400)
            Text("Time off applies to this person on every board.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.entry == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.person == nil)
                    .accessibilityIdentifier("kanban-time-off-save")
            }
        }
        .padding(20)
        .onChange(of: singleDay) { _, single in if !single { draft.portion = .full } }
    }

    private func save() {
        guard let person = draft.person else { return }
        let note = draft.note.trimmingCharacters(in: .whitespaces)
        let dto = KanbanTimeOffDTO(id: draft.entry?.id ?? UUID(), personId: person.id, startDay: KanbanDay(draft.start).key,
                                   endDay: KanbanDay(draft.end).key, portion: singleDay ? draft.portion : .full, kind: draft.kind,
                                   note: note.isEmpty ? nil : note, origin: draft.entry?.origin ?? .manual)
        do {
            let service = app.kanbanService(context)
            if let entry = draft.entry { try service.editTimeOff(entry, to: dto, on: project) } else { try service.addTimeOff(dto, on: project) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One person's time off across every board: add, edit, remove.
struct KanbanTimeOffSheet: View {
    let person: KanbanPerson
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing: KanbanTimeOffDraft?

    var body: some View {
        let entries = person.timeOff.sorted { ($0.startDay, $0.endDay) < ($1.startDay, $1.endDay) }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Time off: \(person.name)").font(.headline)
                Text("Applies to \(person.name) on every board.").font(.caption).foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                Text("No time off recorded.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(KanbanService.span(KanbanTimeOffDTO(entry))).monospacedDigit()
                            Text([entry.kind.label, entry.note].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.origin == .assistant {
                            Image(systemName: "sparkles").foregroundStyle(.secondary).help("Added from Update availability")
                        }
                        Button("Edit") { editing = KanbanTimeOffDraft(entry) }.buttonStyle(.borderless)
                        Button(role: .destructive) {
                            app.runKanban { try app.kanbanService(context).deleteTimeOff([entry], on: project) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove \(KanbanService.span(KanbanTimeOffDTO(entry)))")
                    }
                }
                .frame(minHeight: 200)
            }
            HStack {
                Button("Add time off…") { editing = KanbanTimeOffDraft(person: person, week: KanbanDay.today().monday) }
                    .accessibilityIdentifier("kanban-time-off-add")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .sheet(item: $editing) { KanbanTimeOffEditor(draft: $0, project: project) }
    }
}

extension KanbanTimeOff {
    var origin: KanbanTimeOffOrigin { KanbanTimeOffOrigin(rawValue: originRaw) ?? .manual }
}
