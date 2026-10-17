import SwiftUI
import SwiftData

/// Puts an existing person on the board, or creates one (D15: one person directory,
/// with a membership per board).
struct KanbanAddPersonSheet: View {
    let project: KanbanProject
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KanbanPerson.name) private var people: [KanbanPerson]
    @State private var personID: UUID?
    @State private var name = ""
    @State private var initials = ""
    @State private var employment = KanbanEmployment.fte
    @State private var allocation = 100
    @State private var assignment = KanbanAssignment.fullTime
    @State private var error: String?

    private var available: [KanbanPerson] {
        people.filter { person in
            person.archivedAt == nil && !project.resources.contains { $0.person?.id == person.id && $0.archivedAt == nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add person to \(project.name)").font(.headline)
            Form {
                Picker("Person", selection: $personID) {
                    Text("New person…").tag(UUID?.none)
                    ForEach(available) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("kanban-person-picker")
                if personID == nil {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("kanban-person-name")
                        .onChange(of: name) { _, value in initials = Self.initials(value) }
                    TextField("Initials", text: $initials)
                    Picker("Employment", selection: $employment) {
                        Text("Employee").tag(KanbanEmployment.fte)
                        Text("Contractor").tag(KanbanEmployment.contractor)
                    }
                }
                Picker("Assignment", selection: $assignment) {
                    Text("Full-time").tag(KanbanAssignment.fullTime)
                    Text("Part-time").tag(KanbanAssignment.partTime)
                }
                Stepper("Allocation: \(allocation)%", value: $allocation, in: 5...100, step: 5)
            }
            .frame(width: 380)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(personID == nil && name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("kanban-person-add")
            }
        }
        .padding(20)
    }

    static func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    private func add() {
        let service = app.kanbanService(context)
        do {
            let person = try available.first { $0.id == personID }
                ?? service.createPerson(name: name.trimmingCharacters(in: .whitespaces), initials: initials, employment: employment)
            _ = try service.addMembership(person, to: project, allocationPercent: allocation, assignment: assignment)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Edits one membership (undoable, on the board's Change Log) and the person's details
/// (directory-wide, not undoable).
struct KanbanMembershipSheet: View {
    let resource: KanbanResource
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var initials = ""
    @State private var employment = KanbanEmployment.fte
    @State private var role = ""
    @State private var assignment = KanbanAssignment.fullTime
    @State private var allocation = 100
    @State private var hasHours = false
    @State private var hours = 40.0
    @State private var hasTarget = false
    @State private var target = 5.0
    @State private var hasStart = false
    @State private var start = Date()
    @State private var hasEnd = false
    @State private var end = Date()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(resource.displayName) on \(resource.project?.name ?? "")").font(.headline)
            Form {
                Section("Person (every board)") {
                    TextField("Name", text: $name)
                    TextField("Initials", text: $initials)
                    Picker("Employment", selection: $employment) {
                        Text("Employee").tag(KanbanEmployment.fte)
                        Text("Contractor").tag(KanbanEmployment.contractor)
                    }
                }
                Section("On this board") {
                    TextField("Role", text: $role)
                    Picker("Assignment", selection: $assignment) {
                        Text("Full-time").tag(KanbanAssignment.fullTime)
                        Text("Part-time").tag(KanbanAssignment.partTime)
                    }
                    Stepper("Allocation: \(allocation)%", value: $allocation, in: 1...100)
                        .accessibilityIdentifier("kanban-membership-allocation")
                    Toggle("Weekly hours override", isOn: $hasHours)
                    if hasHours { TextField("Hours per week", value: $hours, format: .number) }
                    Toggle("Open-task target override", isOn: $hasTarget)
                    if hasTarget { TextField("Open tasks", value: $target, format: .number) }
                    Toggle("Starts on", isOn: $hasStart)
                    if hasStart { DatePicker("Start", selection: $start, displayedComponents: .date) }
                    Toggle("Ends on", isOn: $hasEnd)
                    if hasEnd { DatePicker("End", selection: $end, displayedComponents: .date) }
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
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("kanban-membership-save")
            }
        }
        .padding(20)
        .onAppear(perform: load)
    }

    private func load() {
        name = resource.person?.name ?? ""
        initials = resource.person?.initials ?? ""
        employment = resource.person?.employment ?? .fte
        role = resource.role ?? ""
        assignment = resource.assignment
        allocation = resource.allocationPercent
        hasHours = resource.capacityHoursPerWeekOverride != nil
        hours = resource.capacityHoursPerWeekOverride ?? 40
        hasTarget = resource.openTaskTargetOverride != nil
        target = resource.openTaskTargetOverride ?? 5
        hasStart = resource.startDate != nil
        start = resource.startDate ?? Date()
        hasEnd = resource.endDate != nil
        end = resource.endDate ?? Date()
    }

    private func save() {
        let service = app.kanbanService(context)
        let day = Calendar.current.startOfDay
        let trimmedRole = role.trimmingCharacters(in: .whitespaces)
        let values: [KanbanService.MembershipField: KanbanValue?] = [
            .role: trimmedRole.isEmpty ? nil : .string(trimmedRole),
            .assignmentRaw: .string(assignment.rawValue),
            .allocationPercent: .int(allocation),
            .capacityHoursPerWeekOverride: hasHours ? .double(hours) : nil,
            .openTaskTargetOverride: hasTarget ? .double(target) : nil,
            .startDate: hasStart ? .date(day(start)) : nil,
            .endDate: hasEnd ? .date(day(end)) : nil,
        ]
        do {
            try service.editMembership(resource, values)
            if let person = resource.person, name != person.name || initials != person.initials || employment != person.employment {
                try service.editPerson(person, name: name, initials: initials, employment: employment)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
