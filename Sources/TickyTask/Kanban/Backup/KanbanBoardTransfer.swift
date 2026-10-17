import Foundation
import SwiftData

// MARK: - Import Plan

/// Per-project decision: rename with new ids/key or merge into existing.
struct ProjectAction: Equatable, Sendable {
    let sourceId: UUID
    let sourceName: String
    let action: Action

    enum Action: Equatable, Sendable {
        case rename(newKey: String)
        case mergeInto(existingProjectID: UUID)
    }
}

/// Per-person decision: id match, name match link vs create, or create.
struct PersonAction: Equatable, Sendable {
    let sourceId: UUID
    let sourceName: String
    let action: Action

    enum Action: Equatable, Sendable {
        case linkById(UUID)
        case linkByName(existingPersonID: UUID)
        case createNew
    }
}

/// A reuse event: incoming task/subtask assignee was remapped to an existing membership.
struct ReuseEvent: Equatable, Sendable {
    let projectName: String
    let personName: String
    let taskTitle: String
    let reason: String  // "Destination board already has this person" or "Two source people resolved to one"
}

/// Preview and decisions for importing a board file.
struct ImportPlan: Equatable, Sendable {
    /// Target file format. Must be "tickytask-board".
    let format: String
    /// Target file version. Must be ≤ KanbanBackupDTO.currentVersion.
    let version: Int
    /// Import source filename (for the informational activity).
    let sourceFilename: String
    /// Per-project actions. User can override each `action` field.
    var projectActions: [ProjectAction]
    /// Per-person actions. User can override each `action` field.
    var personActions: [PersonAction]
    /// Reuse events (people already on the destination).
    var reuseEvents: [ReuseEvent]
    /// Counts of what will be imported (with final ids).
    var entityCounts: EntityCounts
    /// Warnings (e.g. missing Jira links, future-dated tasks).
    var warnings: [String]

    struct EntityCounts: Equatable, Sendable {
        var people: Int
        var projects: Int
        var columns: Int
        var resources: Int
        var labels: Int
        var tasks: Int
        var subtasks: Int
    }
}

// MARK: - Export/Import Transfer

@MainActor
enum KanbanBoardTransfer {
    /// Export chosen projects and the people they reference to a `.tickytask-board` JSON envelope.
    static func export(projects: [KanbanProject], context: ModelContext) throws -> Data {
        var people = Set<KanbanPerson>()
        var personIds: Set<UUID> = []
        var projectIds = Set(projects.map(\.id))

        // Collect people referenced by resources in the chosen projects.
        for project in projects {
            for resource in project.resources where resource.archivedAt == nil {
                if let person = resource.person {
                    people.insert(person)
                    personIds.insert(person.id)
                }
            }
        }

        // Fetch all entities for the chosen projects.
        var descFetch = FetchDescriptor<KanbanProject>()
        descFetch.predicate = #Predicate { projectIds.contains($0.id) }
        let fetchedProjects = try context.fetch(descFetch)

        let allColumns = try context.fetch(FetchDescriptor<KanbanColumn>())
        let columns = allColumns.filter { $0.project.map { projectIds.contains($0.id) } ?? false }

        let allResources = try context.fetch(FetchDescriptor<KanbanResource>())
        let resources = allResources.filter { $0.project.map { projectIds.contains($0.id) } ?? false }

        let allLabels = try context.fetch(FetchDescriptor<KanbanLabel>())
        let labels = allLabels.filter { $0.project.map { projectIds.contains($0.id) } ?? false }

        let allTasks = try context.fetch(FetchDescriptor<KanbanTask>())
        let tasks = allTasks.filter { $0.project.map { projectIds.contains($0.id) } ?? false }

        let subtasks = try context.fetch(FetchDescriptor<KanbanSubtask>())
        let taskIds = Set(tasks.map(\.id))
        let filteredSubtasks = subtasks.filter { $0.task.map { taskIds.contains($0.id) } ?? false }

        let kanban = KanbanBackupDTO(
            version: KanbanBackupDTO.currentVersion,
            people: Array(people).map(KanbanPersonDTO.init).sorted { $0.id.uuidString < $1.id.uuidString },
            projects: fetchedProjects.map(KanbanProjectDTO.init).sorted { $0.id.uuidString < $1.id.uuidString },
            columns: columns.map(KanbanColumnDTO.init).sorted { $0.id.uuidString < $1.id.uuidString },
            resources: resources.map(KanbanResourceDTO.init).sorted { $0.id.uuidString < $1.id.uuidString },
            labels: labels.map(KanbanLabelDTO.init).sorted { $0.id.uuidString < $1.id.uuidString },
            tasks: tasks.map(KanbanTaskDTO.init).sorted { $0.id.uuidString < $1.id.uuidString },
            subtasks: filteredSubtasks.map(KanbanSubtaskDTO.init).sorted { $0.id.uuidString < $1.id.uuidString },
            activities: []  // Activities not exported; importer adds "Imported from X"
        )

        struct Envelope: Codable {
            let format: String
            let version: Int
            let kanban: KanbanBackupDTO
        }

        let envelope = Envelope(format: "tickytask-board", version: 1, kanban: kanban)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// Decode and preview an import file, computing remapping decisions and validating the resolved graph.
    static func preview(_ data: Data, context: ModelContext) throws -> ImportPlan {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Decode envelope
        struct Envelope: Codable {
            let format: String
            let version: Int
            let kanban: KanbanBackupDTO
        }

        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.format == "tickytask-board" else {
            throw BackupError.validationFailed(reason: "File is not a .tickytask-board (format field missing or invalid)")
        }
        guard envelope.version <= KanbanBackupDTO.currentVersion else {
            throw BackupError.validationFailed(reason: "File version \(envelope.version) is not supported (max: \(KanbanBackupDTO.currentVersion))")
        }

        let kanban = envelope.kanban

        // Check for dangling personIds.
        let personIds = Set(kanban.people.map(\.id))
        for resource in kanban.resources {
            guard let personId = resource.personId, personIds.contains(personId) else {
                throw BackupError.validationFailed(reason: "Resource \(resource.id) references missing person \(resource.personId?.uuidString ?? "(nil)")")
            }
        }
        for subtask in kanban.subtasks {
            if let assigneeId = subtask.assigneeId, !personIds.contains(assigneeId) {
                throw BackupError.validationFailed(reason: "Subtask \(subtask.id) references missing person \(assigneeId.uuidString)")
            }
        }

        // Validate and sanitize the Kanban section.
        let (sanitized, _) = try KanbanBackupValidator.sanitized(kanban)

        // Fetch existing data for clash detection.
        let existingPeople = try context.fetch(FetchDescriptor<KanbanPerson>())
        let existingProjects = try context.fetch(FetchDescriptor<KanbanProject>())
        let existingIds = Set(
            existingPeople.map(\.id) +
            existingProjects.map(\.id) +
            (try context.fetch(FetchDescriptor<KanbanColumn>()).map(\.id)) +
            (try context.fetch(FetchDescriptor<KanbanResource>()).map(\.id)) +
            (try context.fetch(FetchDescriptor<KanbanLabel>()).map(\.id)) +
            (try context.fetch(FetchDescriptor<KanbanTask>()).map(\.id)) +
            (try context.fetch(FetchDescriptor<KanbanSubtask>()).map(\.id))
        )

        // Remap clashing ids.
        var idMap: [UUID: UUID] = [:]  // from imported id to final id
        var remappedKanban = sanitized

        for i in remappedKanban.people.indices {
            if existingIds.contains(remappedKanban.people[i].id) {
                let newId = UUID()
                idMap[sanitized.people[i].id] = newId
                remappedKanban.people[i].id = newId
            } else {
                idMap[sanitized.people[i].id] = sanitized.people[i].id
            }
        }

        for i in remappedKanban.projects.indices {
            if existingIds.contains(remappedKanban.projects[i].id) {
                let newId = UUID()
                idMap[sanitized.projects[i].id] = newId
                remappedKanban.projects[i].id = newId
            } else {
                idMap[sanitized.projects[i].id] = sanitized.projects[i].id
            }
        }

        for i in remappedKanban.columns.indices {
            if existingIds.contains(remappedKanban.columns[i].id) {
                let newId = UUID()
                idMap[sanitized.columns[i].id] = newId
                remappedKanban.columns[i].id = newId
            } else {
                idMap[sanitized.columns[i].id] = sanitized.columns[i].id
            }
        }

        for i in remappedKanban.resources.indices {
            if existingIds.contains(remappedKanban.resources[i].id) {
                let newId = UUID()
                idMap[sanitized.resources[i].id] = newId
                remappedKanban.resources[i].id = newId
            } else {
                idMap[sanitized.resources[i].id] = sanitized.resources[i].id
            }
        }

        for i in remappedKanban.labels.indices {
            if existingIds.contains(remappedKanban.labels[i].id) {
                let newId = UUID()
                idMap[sanitized.labels[i].id] = newId
                remappedKanban.labels[i].id = newId
            } else {
                idMap[sanitized.labels[i].id] = sanitized.labels[i].id
            }
        }

        for i in remappedKanban.tasks.indices {
            if existingIds.contains(remappedKanban.tasks[i].id) {
                let newId = UUID()
                idMap[sanitized.tasks[i].id] = newId
                remappedKanban.tasks[i].id = newId
            } else {
                idMap[sanitized.tasks[i].id] = sanitized.tasks[i].id
            }
        }

        for i in remappedKanban.subtasks.indices {
            if existingIds.contains(remappedKanban.subtasks[i].id) {
                let newId = UUID()
                idMap[sanitized.subtasks[i].id] = newId
                remappedKanban.subtasks[i].id = newId
            } else {
                idMap[sanitized.subtasks[i].id] = sanitized.subtasks[i].id
            }
        }

        // Remap all references.
        remappedKanban = applyIdMapping(remappedKanban, idMap)

        // Match people: id first, then name, then create.
        var personActions: [PersonAction] = []
        var personIdMap: [UUID: UUID] = [:]  // from remapped import id to final id

        for person in remappedKanban.people {
            if let existing = existingPeople.first(where: { $0.id == person.id }) {
                // Id match
                personActions.append(PersonAction(sourceId: person.id, sourceName: person.name, action: .linkById(existing.id)))
                personIdMap[person.id] = existing.id
            } else if let existing = existingPeople.first(where: { $0.name.lowercased().trimmingCharacters(in: .whitespaces) == person.name.lowercased().trimmingCharacters(in: .whitespaces) }) {
                // Name match
                personActions.append(PersonAction(sourceId: person.id, sourceName: person.name, action: .linkByName(existingPersonID: existing.id)))
                personIdMap[person.id] = existing.id
            } else {
                // Create new
                personActions.append(PersonAction(sourceId: person.id, sourceName: person.name, action: .createNew))
                personIdMap[person.id] = person.id
            }
        }

        // Match projects: key clash, then id clash.
        var projectActions: [ProjectAction] = []
        var projectIdMap: [UUID: UUID] = [:]

        for project in remappedKanban.projects {
            let existingByKey = existingProjects.first { $0.key == project.key }
            let existingById = existingProjects.first { $0.id == project.id }

            if let existing = existingByKey {
                projectActions.append(ProjectAction(sourceId: project.id, sourceName: project.name, action: .mergeInto(existingProjectID: existing.id)))
                projectIdMap[project.id] = existing.id
            } else if let existing = existingById {
                projectActions.append(ProjectAction(sourceId: project.id, sourceName: project.name, action: .mergeInto(existingProjectID: existing.id)))
                projectIdMap[project.id] = existing.id
            } else {
                let newKey = project.key  // Default: keep key; UI can override with suffix
                projectActions.append(ProjectAction(sourceId: project.id, sourceName: project.name, action: .rename(newKey: newKey)))
                projectIdMap[project.id] = project.id
            }
        }

        // Compute reuse events: check for duplicate non-archived memberships after matching.
        var reuseEvents: [ReuseEvent] = []
        var membershipByKey: [String: (personId: UUID, resourceId: UUID, isNew: Bool)] = [:]

        for resource in remappedKanban.resources {
            guard resource.archivedAt == nil else { continue }
            guard let personId = resource.personId, let projectId = resource.projectId else { continue }

            let finalPersonId = personIdMap[personId] ?? personId
            let finalProjectId = projectIdMap[projectId] ?? projectId
            let key = "\(finalPersonId.uuidString),\(finalProjectId.uuidString)"

            if let existing = membershipByKey[key] {
                // Collision: existing takes priority
                reuseEvents.append(ReuseEvent(
                    projectName: remappedKanban.projects.first { $0.id == projectId }?.name ?? "Unknown",
                    personName: remappedKanban.people.first { $0.id == personId }?.name ?? "Unknown",
                    taskTitle: "",  // Placeholder; filled when tasks are rewritten
                    reason: "Destination board already has this person"
                ))
            } else {
                membershipByKey[key] = (personId: finalPersonId, resourceId: resource.id, isNew: true)
            }
        }

        // Check existing memberships too - fetch all resources and filter
        let existingResources = try context.fetch(FetchDescriptor<KanbanResource>())
        for resource in existingResources where resource.archivedAt == nil {
            if let person = resource.person, let project = resource.project {
                let key = "\(person.id.uuidString),\(project.id.uuidString)"
                membershipByKey[key] = (personId: person.id, resourceId: resource.id, isNew: false)
            }
        }

        // Build entity counts.
        let entityCounts = ImportPlan.EntityCounts(
            people: remappedKanban.people.count,
            projects: remappedKanban.projects.count,
            columns: remappedKanban.columns.count,
            resources: remappedKanban.resources.count,
            labels: remappedKanban.labels.count,
            tasks: remappedKanban.tasks.count,
            subtasks: remappedKanban.subtasks.count
        )

        let sourceFilename = "board.tickytask-board"

        return ImportPlan(
            format: envelope.format,
            version: envelope.version,
            sourceFilename: sourceFilename,
            projectActions: projectActions,
            personActions: personActions,
            reuseEvents: reuseEvents,
            entityCounts: entityCounts,
            warnings: []
        )
    }

    /// Apply the import plan in a single transaction.
    static func apply(_ plan: ImportPlan, decisions: [UUID: ImportDecision], context: ModelContext) throws {
        // Not implemented in this phase; requires coordinator integration.
        throw BackupError.validationFailed(reason: "Import apply not yet implemented")
    }

    /// Export a project's tasks to CSV (RFC 4180).
    static func csv(project: KanbanProject, context: ModelContext) -> String {
        let tasks = project.tasks.filter { $0.archivedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }

        var lines: [String] = []
        let header = [
            "Title", "Column", "Assignee", "Priority", "Critical", "Due", "Start",
            "Estimate", "Labels", "Jira", "Blocked", "Subtasks Done/Total"
        ]
        lines.append(csvLine(header))

        for task in tasks {
            let row = [
                task.title,
                task.column?.name ?? "Unknown",
                task.resource?.person?.name ?? "Unassigned",
                priorityName(task.priority),
                task.isCritical ? "Yes" : "No",
                dateString(task.dueDate),
                dateString(task.startDate),
                task.estimateHours.map { String(format: "%.1f", $0) } ?? "",
                task.labels.map(\.name).sorted().joined(separator: ";"),
                task.jiraKey ?? "",
                task.isBlocked ? "Yes" : "No",
                "\(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)"
            ]
            lines.append(csvLine(row))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    private static func applyIdMapping(_ kanban: KanbanBackupDTO, _ idMap: [UUID: UUID]) -> KanbanBackupDTO {
        var result = kanban

        for i in result.people.indices {
            if let newId = idMap[result.people[i].id] {
                result.people[i].id = newId
            }
        }

        for i in result.projects.indices {
            if let newId = idMap[result.projects[i].id] {
                result.projects[i].id = newId
            }
        }

        for i in result.columns.indices {
            if let newId = idMap[result.columns[i].id] {
                result.columns[i].id = newId
            }
            if let projectId = result.columns[i].projectId, let newId = idMap[projectId] {
                result.columns[i].projectId = newId
            }
        }

        for i in result.resources.indices {
            if let newId = idMap[result.resources[i].id] {
                result.resources[i].id = newId
            }
            if let projectId = result.resources[i].projectId, let newId = idMap[projectId] {
                result.resources[i].projectId = newId
            }
            if let personId = result.resources[i].personId, let newId = idMap[personId] {
                result.resources[i].personId = newId
            }
        }

        for i in result.labels.indices {
            if let newId = idMap[result.labels[i].id] {
                result.labels[i].id = newId
            }
            if let projectId = result.labels[i].projectId, let newId = idMap[projectId] {
                result.labels[i].projectId = newId
            }
        }

        for i in result.tasks.indices {
            if let newId = idMap[result.tasks[i].id] {
                result.tasks[i].id = newId
            }
            if let projectId = result.tasks[i].projectId, let newId = idMap[projectId] {
                result.tasks[i].projectId = newId
            }
            if let columnId = result.tasks[i].columnId, let newId = idMap[columnId] {
                result.tasks[i].columnId = newId
            }
            if let resourceId = result.tasks[i].resourceId, let newId = idMap[resourceId] {
                result.tasks[i].resourceId = newId
            }
            result.tasks[i].labelIds = result.tasks[i].labelIds.compactMap { idMap[$0] ?? $0 }
            result.tasks[i].dependsOnIds = result.tasks[i].dependsOnIds.compactMap { idMap[$0] ?? $0 }
        }

        for i in result.subtasks.indices {
            if let newId = idMap[result.subtasks[i].id] {
                result.subtasks[i].id = newId
            }
            if let taskId = result.subtasks[i].taskId, let newId = idMap[taskId] {
                result.subtasks[i].taskId = newId
            }
            if let assigneeId = result.subtasks[i].assigneeId, let newId = idMap[assigneeId] {
                result.subtasks[i].assigneeId = newId
            }
        }

        for i in result.activities.indices {
            if let projectId = result.activities[i].projectId, let newId = idMap[projectId] {
                result.activities[i].projectId = newId
            }
        }

        return result
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map { field in
            if field.contains("\"") || field.contains(",") || field.contains("\n") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: ",")
    }

    private static func priorityName(_ priority: Int) -> String {
        switch priority {
        case 0: return "Low"
        case 1: return "Medium"
        case 2: return "High"
        default: return "Unknown"
        }
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date).prefix(10).description
    }
}

// MARK: - Supporting Types

enum ImportDecision: Equatable, Sendable {
    case keepDefault
    case override(value: String)
}
