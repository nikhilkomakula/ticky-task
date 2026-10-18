import SwiftUI
import SwiftData

/// A board's name and optional dates (design 03); the dates bound the Availability tab. Saved
/// as one undoable change; Cancel changes nothing.
struct KanbanBoardSettingsSheet: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var dates = KanbanBoardDatesDraft()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Board settings").font(.headline)
            Form {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("kanban-board-settings-name")
                KanbanBoardDatesFields(dates: $dates)
            }
            .formStyle(.grouped)
            .frame(width: 420)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || dates.problem != nil)
                    .accessibilityIdentifier("kanban-board-settings-save")
            }
        }
        .padding(20)
        .onAppear {
            name = project.name
            dates = KanbanBoardDatesDraft(startDay: project.startDay, endDay: project.endDay)
        }
    }

    private func save() {
        do {
            try app.kanbanService(context).editBoardDetails(project, name: name, startDay: dates.startDay, endDay: dates.endDay)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Optional start and end dates as the date pickers edit them.
struct KanbanBoardDatesDraft: Equatable {
    var hasStart = false
    var start = Date()
    var hasEnd = false
    var end = Date()

    init() {}

    init(startDay: String?, endDay: String?) {
        let today = Calendar.current.startOfDay(for: Date())
        hasStart = startDay != nil
        start = startDay.flatMap(KanbanDay.init(key:))?.date() ?? today
        hasEnd = endDay != nil
        end = endDay.flatMap(KanbanDay.init(key:))?.date() ?? Calendar.current.date(byAdding: .month, value: 3, to: today) ?? today
    }

    var startDay: String? { hasStart ? KanbanDay(start).key : nil }
    var endDay: String? { hasEnd ? KanbanDay(end).key : nil }

    var problem: String? {
        guard hasStart, hasEnd, KanbanDay(end) < KanbanDay(start) else { return nil }
        return "The end date is before the start."
    }
}

/// Starts on / Ends on, each optional; shared by New board and Board settings.
struct KanbanBoardDatesFields: View {
    @Binding var dates: KanbanBoardDatesDraft

    var body: some View {
        Section {
            Toggle("Starts on", isOn: $dates.hasStart)
                .accessibilityIdentifier("kanban-board-start-toggle")
            if dates.hasStart {
                DatePicker("Start", selection: $dates.start, displayedComponents: .date)
                    .accessibilityIdentifier("kanban-board-start")
            }
            Toggle("Ends on", isOn: $dates.hasEnd)
                .accessibilityIdentifier("kanban-board-end-toggle")
            if dates.hasEnd {
                DatePicker("End", selection: $dates.end, displayedComponents: .date)
                    .accessibilityIdentifier("kanban-board-end")
            }
        } header: {
            Text("Dates")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let problem = dates.problem { Text(problem).foregroundStyle(.red) }
                Text("Both are optional. The Availability tab shows the weeks between them.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}
