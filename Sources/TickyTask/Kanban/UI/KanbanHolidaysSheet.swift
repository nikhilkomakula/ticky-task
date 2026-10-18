import SwiftUI
import SwiftData

/// Public holidays for everyone on every board: add, edit, delete with work exceptions (design 04).
struct KanbanHolidaysSheet: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KanbanHoliday.day) private var allHolidays: [KanbanHoliday]
    @Query(sort: \KanbanPerson.name) private var allPeople: [KanbanPerson]
    @State private var editing: KanbanHolidayDraft?
    @State private var showPast = false

    var body: some View {
        let today = KanbanDay.today()
        let holidays = allHolidays.sorted { $0.day < $1.day }
        let displayed = showPast ? holidays : holidays.filter { (KanbanDay(key: $0.day) ?? today) >= today }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Public holidays").font(.headline)
                Text("Applies to everyone on every board. People who work a holiday are listed beside it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if displayed.isEmpty {
                Text(showPast ? "No public holidays recorded." : "No upcoming public holidays.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                List(displayed) { holiday in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                if let day = KanbanDay(key: holiday.day) {
                                    Text(KanbanAvailabilityFormat.short(day)).monospacedDigit()
                                } else {
                                    Text(holiday.day).monospacedDigit()
                                }
                                Text(holiday.name)
                                if holiday.portion != .full {
                                    Text(holiday.portion.label).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !(holiday.workedBy?.isEmpty ?? true) {
                                let names = (holiday.workedBy ?? []).compactMap { id in
                                    allPeople.first { $0.id == id }?.name
                                }.sorted().joined(separator: ", ")
                                Text("Works it: \(names)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Edit") { editing = KanbanHolidayDraft(holiday) }.buttonStyle(.borderless)
                        Button(role: .destructive) {
                            app.runKanban { try app.kanbanService(context).deleteHolidays([holiday], on: project) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove \(holiday.name)")
                    }
                    .accessibilityIdentifier("kanban-holiday-\(holiday.day)")
                }
                .frame(minHeight: 200)
            }
            HStack(spacing: 8) {
                Toggle("Show past", isOn: $showPast)
                Spacer()
                Button("Add", action: { editing = KanbanHolidayDraft() })
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("kanban-holidays-add")
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 400)
        .sheet(item: $editing) { draft in
            KanbanHolidayEditor(draft: .init(get: { editing }, set: { editing = $0 }), project: project, people: allPeople)
        }
        .accessibilityIdentifier("kanban-holidays-sheet")
    }
}

/// What the holiday editor is editing: a new holiday or an existing one.
struct KanbanHolidayDraft: Identifiable {
    let id = UUID()
    var holiday: KanbanHoliday?
    var day: Date
    var name: String = ""
    var portion: KanbanTimeOffPortion = .full
    var workedBy: [UUID] = []

    init() {
        self.holiday = nil
        day = Date()
    }

    init(_ holiday: KanbanHoliday) {
        self.holiday = holiday
        day = KanbanDay(key: holiday.day)?.date() ?? Date()
        name = holiday.name
        portion = holiday.portion
        workedBy = holiday.workedBy ?? []
    }
}

/// Adds or edits one public holiday.
struct KanbanHolidayEditor: View {
    @Binding var draft: KanbanHolidayDraft?
    let project: KanbanProject
    let people: [KanbanPerson]
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        guard var draft = draft else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.holiday == nil ? "Add public holiday" : "Edit public holiday").font(.headline)
                Form {
                    DatePicker("Date", selection: Binding(
                        get: { draft.day },
                        set: { draft.day = $0; self.draft?.day = $0 }
                    ), displayedComponents: .date)
                        .accessibilityIdentifier("kanban-holiday-date")
                    TextField("Name", text: Binding(
                        get: { draft.name },
                        set: { draft.name = $0; self.draft?.name = $0 }
                    ))
                        .accessibilityIdentifier("kanban-holiday-name")
                    Picker("Duration", selection: Binding(
                        get: { draft.portion },
                        set: { draft.portion = $0; self.draft?.portion = $0 }
                    )) {
                        ForEach(KanbanTimeOffPortion.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("People who work it").font(.callout.weight(.semibold))
                        ForEach(people.sorted { $0.name < $1.name }) { person in
                            Toggle(isOn: Binding(
                                get: { draft.workedBy.contains(person.id) },
                                set: { newValue in
                                    if newValue && !draft.workedBy.contains(person.id) {
                                        draft.workedBy.append(person.id)
                                        self.draft?.workedBy = draft.workedBy
                                    } else if !newValue {
                                        draft.workedBy.removeAll { $0 == person.id }
                                        self.draft?.workedBy = draft.workedBy
                                    }
                                }
                            )) {
                                Text(person.name)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 400)
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(draft.holiday == nil ? "Add" : "Save", action: { save(draft) })
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("kanban-holiday-save")
                }
            }
            .padding(20)
        )
    }

    private func save(_ draft: KanbanHolidayDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let day = KanbanDay(draft.day)
        let dto = KanbanHolidayDTO(id: draft.holiday?.id ?? UUID(), day: day.key, name: name, portion: draft.portion,
                                   workedBy: draft.workedBy)
        do {
            let service = app.kanbanService(context)
            if let holiday = draft.holiday {
                try service.editHoliday(holiday, to: dto, on: project)
            } else {
                try service.addHoliday(dto, on: project)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
