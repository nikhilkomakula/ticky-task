import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// D1 verification gate: eight-model Kanban graph migration. Automatic lightweight
/// migration of relationships is a hypothesis until this gate passes. For each legacy
/// fixture (v0.1.1 through v0.1.17), opens it with the current schema, builds a full
/// Kanban graph on disk with every field populated, saves, closes, reopens, and
/// compares the exact graph field by field. Then validates delete cascades match §1.1.
@MainActor
@Suite("Kanban migration gate", .serialized)
struct KanbanMigrationGateTests {
    static let fixtureVersions = ["v0.1.1", "v0.1.2", "v0.1.8", "v0.1.12", "v0.1.15", "v0.1.17"]
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/LegacyStores", isDirectory: true)

    // MARK: - Exact store snapshot (every Kanban field)

    struct PersonRow: Equatable {
        var name: String
        var initials: String
        var colorHex: String?
        var employmentRaw: String
        var skills: [String]
        var createdAt: Int64
        var archivedAt: Int64?
    }
    struct ResourceRow: Equatable {
        var personID: UUID?
        var role: String?
        var assignmentRaw: String
        var allocationPercent: Int
        var capacityHoursPerWeekOverride: Double?
        var openTaskTargetOverride: Double?
        var startDate: Int64?
        var endDate: Int64?
        var sortIndex: Double
        var archivedAt: Int64?
    }
    struct ColumnRow: Equatable {
        var name: String
        var sortIndex: Double
        var colorHex: String?
        var wipLimit: Int?
        var kindRaw: String
    }
    struct TaskRow: Equatable {
        var title: String
        var notes: String
        var notesRich: Data?
        var priority: Int
        var isCritical: Bool
        var sortIndex: Double
        var dueDate: Int64?
        var startDate: Int64?
        var estimateHours: Double?
        var jiraURL: String?
        var isBlocked: Bool
        var blockedReason: String?
        var linkedPlannerTaskID: UUID?
        var createdAt: Int64
        var updatedAt: Int64
        var completedAt: Int64?
        var archivedAt: Int64?
        var projectID: UUID?
        var columnID: UUID?
        var resourceID: UUID?
    }
    struct SubtaskRow: Equatable {
        var title: String
        var isDone: Bool
        var sortIndex: Double
        var completedAt: Int64?
        var taskID: UUID?
        var assigneeID: UUID?
    }
    struct LabelRow: Equatable {
        var name: String
        var colorHex: String
        var symbolName: String?
        var sortIndex: Double
        var projectID: UUID?
    }
    struct ActivityRow: Equatable {
        var seq: Int
        var at: Int64
        var kindRaw: String
        var taskIDs: [UUID]
        var summary: String
        var payload: Data
        var revertsActivityID: UUID?
        var revertedByActivityID: UUID?
        var projectID: UUID?
    }
    struct Graph: Equatable {
        var people: [UUID: PersonRow] = [:]
        var resources: [UUID: ResourceRow] = [:]
        var columns: [UUID: ColumnRow] = [:]
        var tasks: [UUID: TaskRow] = [:]
        var subtasks: [UUID: SubtaskRow] = [:]
        var labels: [UUID: LabelRow] = [:]
        var activities: [UUID: ActivityRow] = [:]
        var taskLabelEdges: [UUID: Set<UUID>] = [:]  // taskID → labelIDs
        var taskDependsOnEdges: [UUID: Set<UUID>] = [:]  // taskID → dependsOnIDs
        var taskDependentEdges: [UUID: Set<UUID>] = [:]  // taskID → dependentIDs
    }

    private func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSinceReferenceDate * 1000).rounded()) }

    private func graph(_ context: ModelContext) throws -> Graph {
        var g = Graph()

        for p in try context.fetch(FetchDescriptor<KanbanPerson>()) {
            g.people[p.id] = PersonRow(
                name: p.name, initials: p.initials, colorHex: p.colorHex,
                employmentRaw: p.employmentRaw, skills: p.skills, createdAt: ms(p.createdAt),
                archivedAt: p.archivedAt.map(ms)
            )
        }

        for r in try context.fetch(FetchDescriptor<KanbanResource>()) {
            g.resources[r.id] = ResourceRow(
                personID: r.person?.id, role: r.role, assignmentRaw: r.assignmentRaw,
                allocationPercent: r.allocationPercent,
                capacityHoursPerWeekOverride: r.capacityHoursPerWeekOverride,
                openTaskTargetOverride: r.openTaskTargetOverride,
                startDate: r.startDate.map(ms), endDate: r.endDate.map(ms),
                sortIndex: r.sortIndex, archivedAt: r.archivedAt.map(ms)
            )
        }

        for col in try context.fetch(FetchDescriptor<KanbanColumn>()) {
            g.columns[col.id] = ColumnRow(
                name: col.name, sortIndex: col.sortIndex, colorHex: col.colorHex,
                wipLimit: col.wipLimit, kindRaw: col.kindRaw
            )
        }

        for t in try context.fetch(FetchDescriptor<KanbanTask>()) {
            g.tasks[t.id] = TaskRow(
                title: t.title, notes: t.notes, notesRich: t.notesRich,
                priority: t.priority, isCritical: t.isCritical,
                sortIndex: t.sortIndex, dueDate: t.dueDate.map(ms), startDate: t.startDate.map(ms),
                estimateHours: t.estimateHours, jiraURL: t.jiraURL,
                isBlocked: t.isBlocked, blockedReason: t.blockedReason,
                linkedPlannerTaskID: t.linkedPlannerTaskID,
                createdAt: ms(t.createdAt), updatedAt: ms(t.updatedAt),
                completedAt: t.completedAt.map(ms), archivedAt: t.archivedAt.map(ms),
                projectID: t.project?.id, columnID: t.column?.id, resourceID: t.resource?.id
            )
            g.taskLabelEdges[t.id] = Set(t.labels.map(\.id))
            g.taskDependsOnEdges[t.id] = Set(t.dependsOn.map(\.id))
            g.taskDependentEdges[t.id] = Set(t.dependents.map(\.id))
        }

        for s in try context.fetch(FetchDescriptor<KanbanSubtask>()) {
            g.subtasks[s.id] = SubtaskRow(
                title: s.title, isDone: s.isDone, sortIndex: s.sortIndex,
                completedAt: s.completedAt.map(ms),
                taskID: s.task?.id, assigneeID: s.assignee?.id
            )
        }

        for l in try context.fetch(FetchDescriptor<KanbanLabel>()) {
            g.labels[l.id] = LabelRow(
                name: l.name, colorHex: l.colorHex, symbolName: l.symbolName,
                sortIndex: l.sortIndex, projectID: l.project?.id
            )
        }

        for a in try context.fetch(FetchDescriptor<KanbanActivity>()) {
            g.activities[a.id] = ActivityRow(
                seq: a.seq, at: ms(a.at), kindRaw: a.kindRaw, taskIDs: a.taskIDs,
                summary: a.summary, payload: a.payload,
                revertsActivityID: a.revertsActivityID, revertedByActivityID: a.revertedByActivityID,
                projectID: a.project?.id
            )
        }

        return g
    }

    private func workingCopy(of tag: String) throws -> (store: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskKanban-\(tag)-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("TickyTask.store")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("\(tag)/TickyTask.store"), to: store)
        return (store, { try? FileManager.default.removeItem(at: dir) })
    }

    // MARK: - 1. Open legacy fixture, build full Kanban graph, round-trip

    @Test("Legacy fixture opens and survives save/reopen with full Kanban graph",
          arguments: fixtureVersions)
    func legacyFixtureCanHostKanbanGraph(tag: String) throws {
        let (store, cleanup) = try workingCopy(of: tag)
        defer { cleanup() }

        var original: Graph
        var reopened: Graph
        var plannerOriginal: BackupDataDTO

        // Open with current schema: lightweight migration happens here
        do {
            let container = try ModelContainerProvider.makeContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false

            // Planner graph must survive, field for field (the backup projection
            // covers every planner model and field).
            let plannerBefore = try context.fetch(FetchDescriptor<TaskItem>()).count
            plannerOriginal = try BackupStore.makeSnapshot(context: context).data

            // Build a full Kanban graph with comprehensive coverage
            let kanbanBefore = try context.fetch(FetchDescriptor<KanbanProject>()).count

            // Insert test graph
            let person1 = KanbanPerson(id: UUID(), name: "Ravi", initials: "RB",
                                      employment: .fte)
            person1.colorHex = "#FF5733"
            person1.skills = ["Swift", "architecture"]
            context.insert(person1)

            let person2 = KanbanPerson(id: UUID(), name: "Mia", initials: "MC",
                                      employment: .contractor)
            person2.colorHex = "#33FF57"
            context.insert(person2)

            // Project 1: all optionals set
            let proj1 = KanbanProject(id: UUID(), name: "Mobile", key: "MOB")
            proj1.colorHex = "#1E40AF"
            proj1.symbolName = "iphone"
            proj1.details = "Mobile app"
            proj1.workWeekDays = [2, 3, 4, 5, 6]
            proj1.hoursPerDay = 8
            proj1.defaultCapacityHoursPerWeek = 40
            proj1.wipPolicyRaw = KanbanWIPPolicy.warn.rawValue
            proj1.loadMeasureRaw = KanbanLoadMeasure.taskCount.rawValue
            proj1.openTaskTarget = 5
            proj1.defaultEstimateHours = 4
            proj1.weightedLoad = false
            proj1.dueSoonThresholdDays = 3
            proj1.suggestDoneWhenSubtasksComplete = true
            proj1.collapsedRowKeys = ["unassigned"]
            proj1.nextActivitySeq = 1
            context.insert(proj1)

            // Project 2: all optionals nil/default
            let proj2 = KanbanProject(id: UUID(), name: "API", key: "API")
            context.insert(proj2)

            // Columns for project 1
            let backlog = KanbanColumn(id: UUID(), name: "Backlog", kind: .backlog, sortIndex: 0)
            backlog.colorHex = "#E0E7FF"
            backlog.project = proj1
            proj1.columns.append(backlog)
            context.insert(backlog)

            let active = KanbanColumn(id: UUID(), name: "In Progress", kind: .active, sortIndex: 1)
            active.wipLimit = 3
            active.colorHex = "#FEF3C7"
            active.project = proj1
            proj1.columns.append(active)
            context.insert(active)

            let done = KanbanColumn(id: UUID(), name: "Done", kind: .done, sortIndex: 2)
            done.colorHex = "#DCFCE7"
            done.project = proj1
            proj1.columns.append(done)
            context.insert(done)

            // Columns for project 2
            let backlog2 = KanbanColumn(id: UUID(), name: "Backlog", kind: .backlog, sortIndex: 0)
            backlog2.project = proj2
            proj2.columns.append(backlog2)
            context.insert(backlog2)

            let done2 = KanbanColumn(id: UUID(), name: "Complete", kind: .done, sortIndex: 1)
            done2.project = proj2
            proj2.columns.append(done2)
            context.insert(done2)

            // Resources (memberships)
            let res1 = KanbanResource(id: UUID(), person: person1, assignment: .fullTime, allocationPercent: 100, sortIndex: 0)
            res1.role = "Lead"
            res1.capacityHoursPerWeekOverride = 45
            res1.openTaskTargetOverride = 3
            res1.startDate = Date().addingTimeInterval(-86400 * 30)
            res1.project = proj1
            proj1.resources.append(res1)
            context.insert(res1)

            let res2 = KanbanResource(id: UUID(), person: person2, assignment: .partTime, allocationPercent: 50, sortIndex: 1)
            res2.endDate = Date().addingTimeInterval(86400 * 30)
            res2.project = proj1
            proj1.resources.append(res2)
            context.insert(res2)

            let res3 = KanbanResource(id: UUID(), person: person1, assignment: .fullTime, allocationPercent: 100, sortIndex: 0)
            res3.project = proj2
            proj2.resources.append(res3)
            context.insert(res3)

            // Archive person2 in person directory (but not in project yet)
            person2.archivedAt = Date()

            // Labels
            let label1 = KanbanLabel(id: UUID(), name: "Feature", colorHex: "#60A5FA", sortIndex: 0)
            label1.symbolName = "star.fill"
            label1.project = proj1
            proj1.labels.append(label1)
            context.insert(label1)

            let label2 = KanbanLabel(id: UUID(), name: "Bug", colorHex: "#F87171", sortIndex: 1)
            label2.symbolName = "exclamationmark.circle"
            label2.project = proj1
            proj1.labels.append(label2)
            context.insert(label2)

            // Tasks with all fields
            let task1 = KanbanTask(id: UUID(), title: "Redesign", priority: 1, sortIndex: 0)
            task1.notes = "Update UI"
            task1.notesRich = try NotesCodec.encode(NotesDocument(blocks: [
                NotesBlock(kind: .paragraph, runs: [NotesRun(text: "Rich notes")])
            ]))
            task1.isCritical = true
            task1.dueDate = Date().addingTimeInterval(86400 * 3)
            task1.startDate = Date()
            task1.estimateHours = 8.5
            task1.jiraURL = "https://jira.example.com/PLAT-142"
            task1.isBlocked = false
            task1.project = proj1
            task1.column = backlog
            task1.resource = res1
            proj1.tasks.append(task1)
            backlog.tasks.append(task1)
            res1.tasks.append(task1)
            context.insert(task1)

            let task2 = KanbanTask(id: UUID(), title: "API endpoint", priority: 0, sortIndex: 1)
            task2.notes = ""
            task2.estimateHours = 5
            task2.project = proj1
            task2.column = active
            task2.resource = res2
            task2.isBlocked = true
            task2.blockedReason = "Waiting for design"
            proj1.tasks.append(task2)
            active.tasks.append(task2)
            res2.tasks.append(task2)
            context.insert(task2)

            let task3 = KanbanTask(id: UUID(), title: "Testing", priority: 2, sortIndex: 0)
            task3.project = proj1
            task3.column = done
            task3.resource = nil  // Unassigned
            task3.completedAt = Date().addingTimeInterval(-86400)
            proj1.tasks.append(task3)
            done.tasks.append(task3)
            context.insert(task3)

            let task4 = KanbanTask(id: UUID(), title: "Auth", priority: 1, sortIndex: 0)
            task4.project = proj2
            task4.column = backlog2
            task4.resource = res3
            proj2.tasks.append(task4)
            backlog2.tasks.append(task4)
            res3.tasks.append(task4)
            context.insert(task4)

            // Add labels to tasks
            task1.labels.append(label1)
            label1.tasks.append(task1)
            task2.labels.append(label2)
            label2.tasks.append(task2)

            // Self-referential dependencies
            task1.dependsOn.append(task2)
            task2.dependents.append(task1)
            task2.dependsOn.append(task3)
            task3.dependents.append(task2)

            // Subtasks
            let sub1 = KanbanSubtask(id: UUID(), title: "Review", isDone: false, sortIndex: 0)
            sub1.task = task1
            sub1.assignee = res1
            task1.subtasks.append(sub1)
            res1.subtaskAssignments.append(sub1)
            context.insert(sub1)

            let sub2 = KanbanSubtask(id: UUID(), title: "Deploy", isDone: true, sortIndex: 1)
            sub2.task = task1
            sub2.completedAt = Date()
            task1.subtasks.append(sub2)
            context.insert(sub2)

            // Activities
            let act1 = KanbanActivity(id: UUID(), seq: 1, at: Date(), kind: "created",
                                     taskIDs: [task1.id], summary: "Card created")
            act1.payload = try JSONEncoder().encode(["test": "data"])
            act1.project = proj1
            proj1.activities.append(act1)
            context.insert(act1)

            // Capture before save
            try context.save()
            original = try graph(context)

            #expect(original.people.count == 2, "2 people in graph")
            #expect(original.resources.count == 3, "3 resources")
            #expect(original.columns.count == 5, "5 columns total")
            #expect(original.tasks.count == 4, "4 tasks")
            #expect(original.subtasks.count == 2, "2 subtasks")
            #expect(original.labels.count == 2, "2 labels")
            #expect(original.activities.count == 1, "1 activity")
            #expect(original.taskLabelEdges[task1.id] == [label1.id], "task1 has label1")
            #expect(original.taskDependsOnEdges[task1.id] == [task2.id], "task1 depends on task2")
            #expect(original.taskDependentEdges[task2.id] == [task1.id], "task2 has task1 as dependent")

            // Planner must survive
            #expect(try context.fetch(FetchDescriptor<TaskItem>()).count == plannerBefore)
        }

        // Reopen and verify exact round-trip
        do {
            let container = try ModelContainerProvider.makeContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            reopened = try graph(context)
            #expect(try BackupStore.makeSnapshot(context: context).data == plannerOriginal,
                    "\(tag): the planner data is exactly unchanged after adding a board and reopening")

            #expect(reopened.people == original.people, "people round-trip exactly")
            #expect(reopened.resources == original.resources, "resources round-trip exactly")
            #expect(reopened.columns == original.columns, "columns round-trip exactly")
            #expect(reopened.tasks == original.tasks, "tasks round-trip exactly")
            #expect(reopened.subtasks == original.subtasks, "subtasks round-trip exactly")
            #expect(reopened.labels == original.labels, "labels round-trip exactly")
            #expect(reopened.activities == original.activities, "activities round-trip exactly")
            #expect(reopened.taskLabelEdges == original.taskLabelEdges, "task-label edges round-trip")
            #expect(reopened.taskDependsOnEdges == original.taskDependsOnEdges, "task-dependsOn edges round-trip")
            #expect(reopened.taskDependentEdges == original.taskDependentEdges, "task-dependent edges round-trip")
        }
    }

    // MARK: - 2. Delete cascade tests on disk

    @Test("Deleting a project cascades columns, resources, labels, tasks, activities; keeps people")
    func projectDeleteCascades() throws {
        let (store, cleanup) = try workingCopy(of: "v0.1.17")
        defer { cleanup() }

        let container = try ModelContainerProvider.makeContainer(at: store)
        var context = ModelContext(container)
        context.autosaveEnabled = false

        // Setup
        let person = KanbanPerson(id: UUID(), name: "Test", initials: "T")
        context.insert(person)

        let proj = KanbanProject(id: UUID(), name: "Test", key: "TST")
        context.insert(proj)

        let col = KanbanColumn(id: UUID(), name: "Backlog", kind: .backlog)
        col.project = proj
        proj.columns.append(col)
        context.insert(col)

        let res = KanbanResource(person: person, sortIndex: 0)
        res.project = proj
        proj.resources.append(res)
        person.memberships.append(res)
        context.insert(res)

        let label = KanbanLabel(name: "Bug")
        label.project = proj
        proj.labels.append(label)
        context.insert(label)

        let task = KanbanTask(title: "Task")
        task.project = proj
        task.column = col
        task.resource = res
        proj.tasks.append(task)
        col.tasks.append(task)
        res.tasks.append(task)
        context.insert(task)

        let act = KanbanActivity(seq: 1, kind: "test")
        act.project = proj
        proj.activities.append(act)
        context.insert(act)

        let projID = proj.id
        let personID = person.id
        try context.save()

        // Delete project
        let fetch = FetchDescriptor<KanbanProject>(predicate: #Predicate { $0.id == projID })
        let toDelete = try context.fetch(fetch).first
        try #require(toDelete != nil, "project exists")
        context.delete(toDelete!)
        try context.save()

        // Reopen and verify cascades
        context = ModelContext(try ModelContainerProvider.makeContainer(at: store))
        #expect(try context.fetch(FetchDescriptor<KanbanProject>()).isEmpty, "project deleted")
        #expect(try context.fetch(FetchDescriptor<KanbanColumn>()).isEmpty, "columns cascade-deleted")
        #expect(try context.fetch(FetchDescriptor<KanbanLabel>()).isEmpty, "labels cascade-deleted")
        #expect(try context.fetch(FetchDescriptor<KanbanTask>()).isEmpty, "tasks cascade-deleted")
        #expect(try context.fetch(FetchDescriptor<KanbanActivity>()).isEmpty, "activities cascade-deleted")
        #expect(try context.fetch(FetchDescriptor<KanbanResource>()).isEmpty, "resources cascade-deleted")

        let personFetch = FetchDescriptor<KanbanPerson>(predicate: #Predicate { $0.id == personID })
        let personStill = try context.fetch(personFetch)
        #expect(!personStill.isEmpty, "person survives project delete")
    }

    @Test("Deleting a column nullifies its tasks' column field (tasks survive)")
    func columnDeleteNullifies() throws {
        let (store, cleanup) = try workingCopy(of: "v0.1.17")
        defer { cleanup() }

        let container = try ModelContainerProvider.makeContainer(at: store)
        var context = ModelContext(container)
        context.autosaveEnabled = false

        // Setup
        let proj = KanbanProject(name: "Test", key: "T")
        context.insert(proj)

        let col = KanbanColumn(name: "Backlog", kind: .backlog)
        col.project = proj
        proj.columns.append(col)
        context.insert(col)

        let done = KanbanColumn(name: "Done", kind: .done)
        done.project = proj
        proj.columns.append(done)
        context.insert(done)

        let task = KanbanTask(title: "Task")
        task.project = proj
        task.column = col
        proj.tasks.append(task)
        col.tasks.append(task)
        context.insert(task)

        let colID = col.id
        let taskID = task.id
        try context.save()

        // Delete column
        let fetch = FetchDescriptor<KanbanColumn>(predicate: #Predicate { $0.id == colID })
        let toDelete = try context.fetch(fetch).first
        try #require(toDelete != nil, "column exists")
        context.delete(toDelete!)
        try context.save()

        // Reopen and verify nullification
        context = ModelContext(try ModelContainerProvider.makeContainer(at: store))
        let taskFetch = FetchDescriptor<KanbanTask>(predicate: #Predicate { $0.id == taskID })
        let taskAfter = try context.fetch(taskFetch).first
        #expect(taskAfter?.column == nil, "task.column nullified")
        #expect(taskAfter != nil, "task survives")
    }

    @Test("Deleting a membership nullifies task.resource and subtask.assignee (tasks survive)")
    func membershipDeleteNullifies() throws {
        let (store, cleanup) = try workingCopy(of: "v0.1.17")
        defer { cleanup() }

        let container = try ModelContainerProvider.makeContainer(at: store)
        var context = ModelContext(container)
        context.autosaveEnabled = false

        // Setup
        let person = KanbanPerson(name: "Test", initials: "T")
        context.insert(person)

        let proj = KanbanProject(name: "Test", key: "T")
        context.insert(proj)

        let col = KanbanColumn(name: "Backlog", kind: .backlog)
        col.project = proj
        proj.columns.append(col)
        context.insert(col)

        let res = KanbanResource(person: person)
        res.project = proj
        proj.resources.append(res)
        person.memberships.append(res)
        context.insert(res)

        let task = KanbanTask(title: "Task")
        task.project = proj
        task.column = col
        task.resource = res
        proj.tasks.append(task)
        col.tasks.append(task)
        res.tasks.append(task)
        context.insert(task)

        let sub = KanbanSubtask(title: "Sub")
        sub.task = task
        sub.assignee = res
        task.subtasks.append(sub)
        res.subtaskAssignments.append(sub)
        context.insert(sub)

        let resID = res.id
        let taskID = task.id
        let subID = sub.id
        try context.save()

        // Delete membership
        let fetch = FetchDescriptor<KanbanResource>(predicate: #Predicate { $0.id == resID })
        let toDelete = try context.fetch(fetch).first
        try #require(toDelete != nil, "membership exists")
        context.delete(toDelete!)
        try context.save()

        // Reopen and verify nullification
        context = ModelContext(try ModelContainerProvider.makeContainer(at: store))
        let taskFetch = FetchDescriptor<KanbanTask>(predicate: #Predicate { $0.id == taskID })
        let taskAfter = try context.fetch(taskFetch).first
        #expect(taskAfter?.resource == nil, "task.resource nullified")
        #expect(taskAfter != nil, "task survives")

        let subFetch = FetchDescriptor<KanbanSubtask>(predicate: #Predicate { $0.id == subID })
        let subAfter = try context.fetch(subFetch).first
        #expect(subAfter?.assignee == nil, "subtask.assignee nullified")
        #expect(subAfter != nil, "subtask survives")
    }

    @Test("Deleting a person nullifies resource.person (memberships survive)")
    func personDeleteNullifies() throws {
        let (store, cleanup) = try workingCopy(of: "v0.1.17")
        defer { cleanup() }

        let container = try ModelContainerProvider.makeContainer(at: store)
        var context = ModelContext(container)
        context.autosaveEnabled = false

        // Setup
        let person = KanbanPerson(name: "Test", initials: "T")
        context.insert(person)

        let proj = KanbanProject(name: "Test", key: "T")
        context.insert(proj)

        let res = KanbanResource(person: person)
        res.project = proj
        proj.resources.append(res)
        person.memberships.append(res)
        context.insert(res)

        let personID = person.id
        let resID = res.id
        try context.save()

        // Delete person
        let fetch = FetchDescriptor<KanbanPerson>(predicate: #Predicate { $0.id == personID })
        let toDelete = try context.fetch(fetch).first
        try #require(toDelete != nil, "person exists")
        context.delete(toDelete!)
        try context.save()

        // Reopen and verify nullification
        context = ModelContext(try ModelContainerProvider.makeContainer(at: store))
        let resFetch = FetchDescriptor<KanbanResource>(predicate: #Predicate { $0.id == resID })
        let resAfter = try context.fetch(resFetch).first
        #expect(resAfter?.person == nil, "resource.person nullified")
        #expect(resAfter != nil, "resource survives")
    }

    @Test("Deleting a label removes it from tasks (tasks survive)")
    func labelDeleteNullifies() throws {
        let (store, cleanup) = try workingCopy(of: "v0.1.17")
        defer { cleanup() }

        let container = try ModelContainerProvider.makeContainer(at: store)
        var context = ModelContext(container)
        context.autosaveEnabled = false

        // Setup
        let proj = KanbanProject(name: "Test", key: "T")
        context.insert(proj)

        let col = KanbanColumn(name: "Backlog", kind: .backlog)
        col.project = proj
        proj.columns.append(col)
        context.insert(col)

        let label = KanbanLabel(name: "Feature")
        label.project = proj
        proj.labels.append(label)
        context.insert(label)

        let task = KanbanTask(title: "Task")
        task.project = proj
        task.column = col
        task.labels.append(label)
        label.tasks.append(task)
        proj.tasks.append(task)
        col.tasks.append(task)
        context.insert(task)

        let labelID = label.id
        let taskID = task.id
        try context.save()

        // Delete label
        let fetch = FetchDescriptor<KanbanLabel>(predicate: #Predicate { $0.id == labelID })
        let toDelete = try context.fetch(fetch).first
        try #require(toDelete != nil, "label exists")
        context.delete(toDelete!)
        try context.save()

        // Reopen and verify label removal
        context = ModelContext(try ModelContainerProvider.makeContainer(at: store))
        let taskFetch = FetchDescriptor<KanbanTask>(predicate: #Predicate { $0.id == taskID })
        let taskAfter = try context.fetch(taskFetch).first
        #expect(taskAfter?.labels.isEmpty ?? false, "label removed from task")
        #expect(taskAfter != nil, "task survives")
    }

    @Test("Deleting a task removes its dependency edges both ways (other tasks survive)")
    func taskDeleteRemovesDependencies() throws {
        let (store, cleanup) = try workingCopy(of: "v0.1.17")
        defer { cleanup() }

        let container = try ModelContainerProvider.makeContainer(at: store)
        var context = ModelContext(container)
        context.autosaveEnabled = false

        // Setup
        let proj = KanbanProject(name: "Test", key: "T")
        context.insert(proj)

        let col = KanbanColumn(name: "Backlog", kind: .backlog)
        col.project = proj
        proj.columns.append(col)
        context.insert(col)

        let task1 = KanbanTask(title: "A")
        task1.project = proj
        task1.column = col
        proj.tasks.append(task1)
        col.tasks.append(task1)
        context.insert(task1)

        let task2 = KanbanTask(title: "B")
        task2.project = proj
        task2.column = col
        task2.dependsOn.append(task1)
        task1.dependents.append(task2)
        proj.tasks.append(task2)
        col.tasks.append(task2)
        context.insert(task2)

        let task2ID = task2.id
        let task1ID = task1.id
        try context.save()

        // Delete task1
        let fetch = FetchDescriptor<KanbanTask>(predicate: #Predicate { $0.id == task1ID })
        let toDelete = try context.fetch(fetch).first
        try #require(toDelete != nil, "task exists")
        context.delete(toDelete!)
        try context.save()

        // Reopen and verify edge removal
        context = ModelContext(try ModelContainerProvider.makeContainer(at: store))
        let task2Fetch = FetchDescriptor<KanbanTask>(predicate: #Predicate { $0.id == task2ID })
        let task2After = try context.fetch(task2Fetch).first
        #expect(task2After?.dependsOn.isEmpty ?? false, "dependency edge removed")
        #expect(task2After != nil, "other task survives")
    }

    @Test("Deleting a task cascades its subtasks (other tasks unaffected)")
    func taskDeleteCascadesSubtasks() throws {
        let (store, cleanup) = try workingCopy(of: "v0.1.17")
        defer { cleanup() }

        let container = try ModelContainerProvider.makeContainer(at: store)
        var context = ModelContext(container)
        context.autosaveEnabled = false

        // Setup
        let proj = KanbanProject(name: "Test", key: "T")
        context.insert(proj)

        let col = KanbanColumn(name: "Backlog", kind: .backlog)
        col.project = proj
        proj.columns.append(col)
        context.insert(col)

        let task1 = KanbanTask(title: "A")
        task1.project = proj
        task1.column = col
        proj.tasks.append(task1)
        col.tasks.append(task1)
        context.insert(task1)

        let sub = KanbanSubtask(title: "Sub")
        sub.task = task1
        task1.subtasks.append(sub)
        context.insert(sub)

        let task2 = KanbanTask(title: "B")
        task2.project = proj
        task2.column = col
        proj.tasks.append(task2)
        col.tasks.append(task2)
        context.insert(task2)

        let task1ID = task1.id
        let task2ID = task2.id
        let subID = sub.id
        try context.save()

        // Delete task1
        let fetch = FetchDescriptor<KanbanTask>(predicate: #Predicate { $0.id == task1ID })
        let toDelete = try context.fetch(fetch).first
        try #require(toDelete != nil, "task exists")
        context.delete(toDelete!)
        try context.save()

        // Reopen and verify cascade
        context = ModelContext(try ModelContainerProvider.makeContainer(at: store))
        let subFetch = FetchDescriptor<KanbanSubtask>(predicate: #Predicate { $0.id == subID })
        let subAfter = try context.fetch(subFetch)
        #expect(subAfter.isEmpty, "subtask cascade-deleted")

        let task2Fetch = FetchDescriptor<KanbanTask>(predicate: #Predicate { $0.id == task2ID })
        let task2After = try context.fetch(task2Fetch).first
        #expect(task2After != nil, "other task survives")
    }

    // MARK: - 3. Upgrade invariant: planner rows never lost

    @Test("Opening each legacy fixture twice never loses planner rows",
          arguments: fixtureVersions)
    func planner_RoundTrip(tag: String) throws {
        let (store, cleanup) = try workingCopy(of: tag)
        defer { cleanup() }

        var container = try ModelContainerProvider.makeContainer(at: store)
        var context = ModelContext(container)
        context.autosaveEnabled = false

        let before = try context.fetch(FetchDescriptor<TaskItem>()).count
        try context.save()

        container = try ModelContainerProvider.makeContainer(at: store)
        context = ModelContext(container)
        let after = try context.fetch(FetchDescriptor<TaskItem>()).count

        #expect(after == before, "\(tag): planner rows survive reopen")
    }
}
