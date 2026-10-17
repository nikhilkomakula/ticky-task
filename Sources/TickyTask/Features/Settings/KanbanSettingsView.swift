import SwiftUI
import SwiftData

/// Settings › Kanban (design 01 §7): which modules show and which opens first, defaults for
/// new boards, due-date notifications, auto-archive, saved templates and the demo board.
struct KanbanSettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(ModulePolicy.showPlannerKey) private var showPlanner = true
    @AppStorage(ModulePolicy.showKanbanKey) private var showKanban = true
    @AppStorage("defaultModule") private var defaultModule = AppModule.planner.rawValue
    @AppStorage(KanbanBoardDefaults.weightedLoadKey) private var weightedLoad = false
    @AppStorage(KanbanBoardDefaults.wipPolicyKey) private var wipPolicy = KanbanWIPPolicy.warn.rawValue
    @AppStorage(KanbanBoardDefaults.loadMeasureKey) private var loadMeasure = KanbanLoadMeasure.taskCount.rawValue
    @AppStorage(KanbanBoardDefaults.openTaskTargetKey) private var openTaskTarget = 5.0
    @AppStorage(KanbanBoardDefaults.dueSoonKey) private var dueSoon = 3
    @AppStorage(KanbanBoardDefaults.suggestDoneKey) private var suggestDone = true
    @AppStorage(KanbanBoardDefaults.showAllocationKey) private var showAllocation = true
    @AppStorage("kanban.notifyDueDates") private var notifyDueDates = false
    @AppStorage("kanban.notifyDueMinutes") private var notifyDueMinutes = 9 * 60
    @AppStorage(KanbanBoardDefaults.autoArchiveEnabledKey) private var autoArchive = false
    @AppStorage(KanbanBoardDefaults.autoArchiveDaysKey) private var autoArchiveDays = 30
    @AppStorage(KanbanPopover.projectKey) private var popoverProjectID = ""
    @Query(sort: \KanbanProject.sortIndex) private var projects: [KanbanProject]
    @State private var templates = KanbanTemplateStore.saved()
    @State private var message: String?
    @State private var showDefaultLabelsSheet = false

    var body: some View {
        let policy = ModulePolicy(showPlanner: showPlanner, showKanban: showKanban)
        Form {
            Section("Modules") {
                Toggle("Show the Planner", isOn: $showPlanner).disabled(policy.isLocked(.planner))
                Toggle("Show Kanban", isOn: $showKanban).disabled(policy.isLocked(.kanban))
                    .accessibilityIdentifier("settings-show-kanban")
                Picker("Open at launch", selection: $defaultModule) {
                    ForEach(policy.visible) { Text($0.label).tag($0.rawValue) }
                }
                Text("At least one module stays on. Hiding the planner also turns off quick capture; carry-forward, recurrence and reminders keep running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Boards") {
                Toggle("Show allocation in row headers", isOn: $showAllocation)
                    .accessibilityIdentifier("settings-show-allocation")
                Text("The part-time icon and percentage beside each name. Allocation still sets capacity and stays in Edit membership.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("New boards") {
                Picker("Measure load in", selection: $loadMeasure) {
                    Text("Open tasks").tag(KanbanLoadMeasure.taskCount.rawValue)
                    Text("Hours").tag(KanbanLoadMeasure.hours.rawValue)
                }
                TextField("Open-task target per resource", value: $openTaskTarget, format: .number)
                Toggle("Weight Critical and High cards", isOn: $weightedLoad)
                Picker("Over a WIP limit", selection: $wipPolicy) {
                    Text("Warn").tag(KanbanWIPPolicy.warn.rawValue)
                    Text("Block the move").tag(KanbanWIPPolicy.block.rawValue)
                }
                Stepper("Due soon: within \(dueSoon) day\(dueSoon == 1 ? "" : "s")", value: $dueSoon, in: 0...30)
                Toggle("Offer to move a card to Done when its steps are done", isOn: $suggestDone)
                HStack {
                    Text("Default labels for new boards")
                    Spacer()
                    Button("Edit…", action: { showDefaultLabelsSheet = true })
                        .accessibilityIdentifier("settings-kanban-default-labels")
                }
            }
            Section("Menu bar") {
                Picker("Quick add files cards in", selection: $popoverProjectID) {
                    Text("The last opened board").tag("")
                    ForEach(projects.filter { $0.archivedAt == nil || $0.id.uuidString == popoverProjectID }) {
                        Text($0.name).tag($0.id.uuidString)
                    }
                }
                Text("New cards go to the board's backlog, Unassigned, due on the day picked in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Notify on Kanban due dates", isOn: $notifyDueDates)
                    .onChange(of: notifyDueDates) { _, isOn in
                        Task {
                            // Turning it on asks for permission (once); the reminders follow either way.
                            if isOn { _ = await NotificationService.requestAuthorization() }
                            await NotificationService.syncKanbanReminders(context: context)
                        }
                    }
                if notifyDueDates {
                    DatePicker("At", selection: Binding(get: { Self.time(notifyDueMinutes) }, set: { notifyDueMinutes = Self.minutes($0) }),
                               displayedComponents: .hourAndMinute)
                    .onChange(of: notifyDueMinutes) { _, _ in Task { await NotificationService.syncKanbanReminders(context: context) } }
                }
            }
            Section("Archive") {
                Toggle("Archive finished cards automatically", isOn: $autoArchive)
                if autoArchive {
                    Stepper("After \(autoArchiveDays) days in Done", value: $autoArchiveDays, in: 1...365)
                }
                Text("Archived cards stay in the store and can be shown with Show Archived; nothing is deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Templates") {
                if templates.isEmpty {
                    Text("Save a board's columns and labels as a template from its menu in the sidebar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(templates) { template in
                    HStack {
                        Text(template.name)
                        Text(template.columns.map(\.name).joined(separator: " → ")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete", role: .destructive) {
                            try? KanbanTemplateStore.delete(template.id)
                            templates = KanbanTemplateStore.saved()
                        }
                    }
                }
            }
            Section("Demo") {
                Button("Load demo board") {
                    do {
                        let project = try KanbanDemoSeed.load(into: context)
                        app.kanbanGeneration.bump()
                        app.module = .kanban
                        app.kanban.selection = .project(project.id)
                        message = "Added “Demo board”."
                    } catch {
                        message = error.localizedDescription
                    }
                }
                .accessibilityIdentifier("settings-load-demo-board")
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { templates = KanbanTemplateStore.saved() }
        .sheet(isPresented: $showDefaultLabelsSheet) {
            KanbanLabelManagerSheet(defaults: ())
        }
    }

    private static func time(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
    }
}
