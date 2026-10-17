import Foundation
import SwiftData
import Testing
@testable import TickyTask

@Suite(.serialized) @MainActor
struct KanbanBoardTransferTests {
    // MARK: - Test Helpers

    private func makeInMemoryContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    private func makeFixtureBoard(context: ModelContext) -> (project: KanbanProject, people: [KanbanPerson], tasks: [KanbanTask]) {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Create people
        let alice = KanbanPerson(id: UUID(), name: "Alice", initials: "AW", employment: .fte)
        alice.createdAt = t0
        context.insert(alice)

        let bob = KanbanPerson(id: UUID(), name: "Bob", initials: "BC", employment: .contractor)
        bob.createdAt = t0
        context.insert(bob)

        // Create project
        let project = KanbanProject(id: UUID(), name: "Test Board", key: "TEST", sortIndex: 1)
        project.createdAt = t0
        project.updatedAt = t0
        context.insert(project)

        // Create columns
        let backlog = KanbanColumn(id: UUID(), name: "Backlog", sortIndex: 1)
        backlog.kindRaw = "backlog"
        backlog.project = project
        context.insert(backlog)

        let inProgress = KanbanColumn(id: UUID(), name: "In Progress", sortIndex: 2)
        inProgress.kindRaw = "active"
        inProgress.project = project
        context.insert(inProgress)

        let done = KanbanColumn(id: UUID(), name: "Done", sortIndex: 3)
        done.kindRaw = "done"
        done.project = project
        context.insert(done)

        // Create resources
        let res1 = KanbanResource()
        res1.id = UUID()
        res1.person = alice
        res1.project = project
        res1.assignmentRaw = KanbanAssignment.fullTime.rawValue
        res1.allocationPercent = 100
        res1.sortIndex = 1
        context.insert(res1)

        let res2 = KanbanResource()
        res2.id = UUID()
        res2.person = bob
        res2.project = project
        res2.assignmentRaw = KanbanAssignment.partTime.rawValue
        res2.allocationPercent = 50
        res2.sortIndex = 2
        context.insert(res2)

        // Create tasks
        let task1 = KanbanTask(id: UUID(), title: "Task 1", priority: 1, sortIndex: 1)
        task1.project = project
        task1.column = backlog
        task1.resource = res1
        task1.createdAt = t0
        task1.updatedAt = t0
        context.insert(task1)

        let task2 = KanbanTask(id: UUID(), title: "Task 2", priority: 0, sortIndex: 2)
        task2.project = project
        task2.column = inProgress
        task2.resource = res2
        task2.createdAt = t0
        task2.updatedAt = t0
        context.insert(task2)

        let task3 = KanbanTask(id: UUID(), title: "Task 3", priority: 2, sortIndex: 3)
        task3.project = project
        task3.column = done
        task3.completedAt = t0
        task3.createdAt = t0
        task3.updatedAt = t0
        context.insert(task3)

        // Create subtasks
        let subtask1 = KanbanSubtask(id: UUID(), title: "Subtask 1", isDone: false, sortIndex: 1)
        subtask1.task = task1
        subtask1.assignee = res1
        context.insert(subtask1)

        try? context.save()

        return (project: project, people: [alice, bob], tasks: [task1, task2, task3])
    }

    // MARK: - Export Tests

    @Test
    func testExportBasicBoard() throws {
        let context = makeInMemoryContext()
        let (project, _, _) = makeFixtureBoard(context: context)

        let data = try KanbanBoardTransfer.export(projects: [project], context: context)

        // Verify JSON structure
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct Envelope: Codable {
            let format: String
            let version: Int
            let kanban: KanbanBackupDTO
        }

        let envelope = try decoder.decode(Envelope.self, from: data)
        #expect(envelope.format == "tickytask-board")
        #expect(envelope.version == 1)
        #expect(!envelope.kanban.projects.isEmpty)
    }

    @Test
    func testExportIncludesReferencedPeople() throws {
        let context = makeInMemoryContext()
        let (project, people, _) = makeFixtureBoard(context: context)

        let data = try KanbanBoardTransfer.export(projects: [project], context: context)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct Envelope: Codable {
            let format: String
            let version: Int
            let kanban: KanbanBackupDTO
        }

        let envelope = try decoder.decode(Envelope.self, from: data)
        let kanban = envelope.kanban

        #expect(kanban.people.count == 2)
        #expect(kanban.projects.count == 1)
        #expect(kanban.tasks.count == 3)
    }

    @Test
    func testExportDeterministicOrder() throws {
        let context = makeInMemoryContext()
        let (project, _, _) = makeFixtureBoard(context: context)

        let data1 = try KanbanBoardTransfer.export(projects: [project], context: context)
        let data2 = try KanbanBoardTransfer.export(projects: [project], context: context)

        #expect(data1 == data2)
    }

    // MARK: - CSV Tests

    @Test
    func testCSVExport() throws {
        let context = makeInMemoryContext()
        let (project, _, _) = makeFixtureBoard(context: context)

        let csv = KanbanBoardTransfer.csv(project: project, context: context)

        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count >= 4)  // Header + at least 3 tasks
        #expect(String(lines[0]).contains("Title"))
        #expect(String(lines[0]).contains("Column"))
    }

    @Test
    func testCSVQuoting() throws {
        let context = makeInMemoryContext()

        let project = KanbanProject(name: "Test", key: "TST", sortIndex: 1)
        context.insert(project)

        let col = KanbanColumn(name: "Backlog", sortIndex: 1)
        col.kindRaw = "backlog"
        col.project = project
        context.insert(col)

        let task = KanbanTask(title: "Task with \"quotes\", comma", priority: 0, sortIndex: 1)
        task.project = project
        task.column = col
        context.insert(task)

        try? context.save()

        let csv = KanbanBoardTransfer.csv(project: project, context: context)
        #expect(csv.contains("\"Task with \"\"quotes\"\", comma\""))
    }

    // MARK: - Preview Tests

    @Test
    func testPreviewValidatesFileFormat() throws {
        let context = makeInMemoryContext()

        struct BadEnvelope: Codable {
            let format: String
            let version: Int
            let kanban: KanbanBackupDTO
        }

        let badDto = KanbanBackupDTO(version: 1, people: [], projects: [], columns: [], resources: [], labels: [], tasks: [], subtasks: [], activities: [])
        let badEnvelope = BadEnvelope(format: "wrong", version: 1, kanban: badDto)
        let badJson = try JSONEncoder().encode(badEnvelope)

        do {
            _ = try KanbanBoardTransfer.preview(badJson, context: context)
            #expect(false, "Should have thrown")
        } catch {
            #expect(error is BackupError)
        }
    }

    @Test
    func testPreviewRejectsIncompatibleVersion() throws {
        let context = makeInMemoryContext()

        struct Envelope: Codable {
            let format: String
            let version: Int
            let kanban: KanbanBackupDTO
        }

        let badDto = KanbanBackupDTO(version: 999, people: [], projects: [], columns: [], resources: [], labels: [], tasks: [], subtasks: [], activities: [])
        let envelope = Envelope(format: "tickytask-board", version: 999, kanban: badDto)
        let json = try JSONEncoder().encode(envelope)

        do {
            _ = try KanbanBoardTransfer.preview(json, context: context)
            #expect(false, "Should have thrown")
        } catch {
            #expect(error is BackupError)
        }
    }

    @Test
    func testPreviewIdClashRemapping() throws {
        let sourceContext = makeInMemoryContext()
        let (project, people, _) = makeFixtureBoard(context: sourceContext)

        let exportData = try KanbanBoardTransfer.export(projects: [project], context: sourceContext)

        let destContext = makeInMemoryContext()
        // Insert same ids to trigger clash
        for person in people {
            let dup = KanbanPerson(id: person.id, name: "Duplicate", initials: "DUP", employment: .fte)
            destContext.insert(dup)
        }

        let plan = try KanbanBoardTransfer.preview(exportData, context: destContext)

        #expect(plan.format == "tickytask-board")
        #expect(plan.version == 1)
        #expect(!plan.projectActions.isEmpty)
    }

    @Test
    func testPreviewPersonNameMatching() throws {
        let sourceContext = makeInMemoryContext()
        let (project, _, _) = makeFixtureBoard(context: sourceContext)

        let exportData = try KanbanBoardTransfer.export(projects: [project], context: sourceContext)

        let destContext = makeInMemoryContext()
        // Insert person with same name but different id
        let alice = KanbanPerson(id: UUID(), name: "Alice", initials: "AW", employment: .fte)
        destContext.insert(alice)

        let plan = try KanbanBoardTransfer.preview(exportData, context: destContext)

        let aliceAction = plan.personActions.first { $0.sourceName == "Alice" }
        #expect(aliceAction?.action != nil)
    }

    @Test
    func testPreviewProjectKeyClash() throws {
        let sourceContext = makeInMemoryContext()
        let (project, _, _) = makeFixtureBoard(context: sourceContext)

        let exportData = try KanbanBoardTransfer.export(projects: [project], context: sourceContext)

        let destContext = makeInMemoryContext()
        // Insert project with same key
        let existing = KanbanProject(name: "Existing", key: "TEST", sortIndex: 1)
        destContext.insert(existing)

        let plan = try KanbanBoardTransfer.preview(exportData, context: destContext)

        let projectAction = plan.projectActions.first
        if case .mergeInto = projectAction?.action {
            // Expected: suggest merge
        } else {
            #expect(false, "Should suggest merge for key clash")
        }
    }

    @Test
    func testPreviewDanglingPersonIdRejected() throws {
        // Create a simple invalid Kanban file with dangling person reference
        let invalidData = """
        {
            "format": "tickytask-board",
            "version": 1,
            "kanban": {
                "version": 1,
                "people": [],
                "projects": [{
                    "id": "00000000-0000-0000-0000-000000000001",
                    "name": "Test",
                    "key": "TST",
                    "details": "",
                    "colorHex": "#000000",
                    "symbolName": "square",
                    "sortIndex": 1,
                    "isPinned": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z",
                    "archivedAt": null,
                    "workWeekDays": [],
                    "hoursPerDay": 8,
                    "defaultCapacityHoursPerWeek": 40,
                    "wipPolicyRaw": "ignore",
                    "loadMeasureRaw": "hours",
                    "openTaskTarget": 5,
                    "defaultEstimateHours": 4,
                    "weightedLoad": false,
                    "dueSoonThresholdDays": 7,
                    "suggestDoneWhenSubtasksComplete": false,
                    "collapsedRowKeys": [],
                    "boardState": null,
                    "nextActivitySeq": 1
                }],
                "columns": [{
                    "id": "00000000-0000-0000-0000-000000000002",
                    "name": "Backlog",
                    "sortIndex": 1,
                    "colorHex": null,
                    "wipLimit": null,
                    "kindRaw": "backlog",
                    "projectId": "00000000-0000-0000-0000-000000000001"
                }],
                "resources": [{
                    "id": "00000000-0000-0000-0000-000000000003",
                    "projectId": "00000000-0000-0000-0000-000000000001",
                    "personId": "00000000-0000-0000-0000-000000000099",
                    "role": null,
                    "assignmentRaw": "full-time",
                    "allocationPercent": 100,
                    "capacityHoursPerWeekOverride": null,
                    "openTaskTargetOverride": null,
                    "startDate": null,
                    "endDate": null,
                    "sortIndex": 1,
                    "archivedAt": null
                }],
                "labels": [],
                "tasks": [],
                "subtasks": [],
                "activities": []
            }
        }
        """.data(using: .utf8)!

        let context = makeInMemoryContext()

        do {
            _ = try KanbanBoardTransfer.preview(invalidData, context: context)
            #expect(false, "Should have thrown for dangling person id")
        } catch {
            #expect(error is BackupError)
        }
    }

    // MARK: - Round-Trip Tests

    @Test
    func testRoundTripPreservesData() throws {
        let sourceContext = makeInMemoryContext()
        let (project, _, tasks) = makeFixtureBoard(context: sourceContext)

        // Export
        let exportData = try KanbanBoardTransfer.export(projects: [project], context: sourceContext)

        // Decode to verify structure
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct Envelope: Codable {
            let format: String
            let version: Int
            let kanban: KanbanBackupDTO
        }

        let envelope = try decoder.decode(Envelope.self, from: exportData)
        let kanban = envelope.kanban

        // Verify counts
        #expect(kanban.people.count == 2)
        #expect(kanban.projects.count == 1)
        #expect(kanban.tasks.count == 3)
        #expect(kanban.columns.count == 3)
    }

    @Test
    func testPreviewPreservesProjectStructure() throws {
        let sourceContext = makeInMemoryContext()
        let (project, _, _) = makeFixtureBoard(context: sourceContext)

        let exportData = try KanbanBoardTransfer.export(projects: [project], context: sourceContext)

        let destContext = makeInMemoryContext()
        let plan = try KanbanBoardTransfer.preview(exportData, context: destContext)

        #expect(plan.entityCounts.projects == 1)
        #expect(plan.entityCounts.people == 2)
        #expect(plan.entityCounts.tasks == 3)
        #expect(plan.entityCounts.columns == 3)
    }

    @Test
    func testMultiProjectExport() throws {
        let context = makeInMemoryContext()

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Create two projects
        let proj1 = KanbanProject(name: "Project 1", key: "P1", sortIndex: 1)
        proj1.createdAt = t0
        proj1.updatedAt = t0
        context.insert(proj1)

        let proj2 = KanbanProject(name: "Project 2", key: "P2", sortIndex: 2)
        proj2.createdAt = t0
        proj2.updatedAt = t0
        context.insert(proj2)

        // Create columns for both
        for proj in [proj1, proj2] {
            let col = KanbanColumn(name: "Backlog", sortIndex: 1)
            col.kindRaw = "backlog"
            col.project = proj
            context.insert(col)

            let done = KanbanColumn(name: "Done", sortIndex: 2)
            done.kindRaw = "done"
            done.project = proj
            context.insert(done)
        }

        try? context.save()

        let data = try KanbanBoardTransfer.export(projects: [proj1, proj2], context: context)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct Envelope: Codable {
            let format: String
            let version: Int
            let kanban: KanbanBackupDTO
        }

        let envelope = try decoder.decode(Envelope.self, from: data)
        let kanban = envelope.kanban

        #expect(kanban.projects.count == 2)
        #expect(kanban.columns.count == 4)
    }
}

// MARK: - Test Error

enum KanbanBoardTransferTestError: Error {
    case unexpectedFormat
}
