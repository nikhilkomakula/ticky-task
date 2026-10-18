import Foundation

/// Report of validation and import resolution issues found in a Kanban backup.
struct KanbanImportReport: Equatable, Sendable {
    /// Dependency edges dropped because they were self-edges or formed cycles.
    var droppedDependencyEdges: Int = 0
    /// Links to planner tasks that were cleared during restore because the target
    /// was missing or a hidden definition.
    var droppedPlannerLinks: Int = 0
    /// Live cards on an archived membership, sent to Unassigned.
    var unassignedFromArchivedMemberships: Int = 0
    /// Live cards whose completion didn't match their column (Done ⇔ completed), repaired.
    var repairedCompletions: Int = 0
}

/// Validates a decoded Kanban backup before restore or import, checking version,
/// referential integrity, column invariants, and resolving dependency cycles.
enum KanbanBackupValidator {
    /// Validates `kanban` and returns the report. Use `sanitized` for the data to insert.
    @discardableResult
    static func validate(_ kanban: KanbanBackupDTO) throws -> KanbanImportReport {
        try sanitized(kanban).report
    }

    /// Validates `kanban` and returns it with self-edges and cycle-closing dependency
    /// edges removed (counted in the report), ready to insert.
    static func sanitized(_ kanban: KanbanBackupDTO) throws -> (dto: KanbanBackupDTO, report: KanbanImportReport) {
        guard kanban.version <= KanbanBackupDTO.currentVersion else {
            throw BackupError.validationFailed(reason: "Kanban version \(kanban.version) is not supported (max: \(KanbanBackupDTO.currentVersion))")
        }

        // Build id sets for integrity checking.
        let personIds = Set(kanban.people.map(\.id))
        let projectIds = Set(kanban.projects.map(\.id))
        let columnIds = Set(kanban.columns.map(\.id))
        let resourceIds = Set(kanban.resources.map(\.id))
        let labelIds = Set(kanban.labels.map(\.id))
        let taskIds = Set(kanban.tasks.map(\.id))
        let subtaskIds = Set(kanban.subtasks.map(\.id))

        // Ids must be unique per entity: SwiftData has no uniqueness constraint, and a
        // duplicate would let a reference resolve to a row on another board.
        func requireUnique(_ ids: [UUID], _ entity: String) throws {
            guard Set(ids).count == ids.count else {
                throw BackupError.validationFailed(reason: "The backup repeats a \(entity) id")
            }
        }
        try requireUnique(kanban.people.map(\.id), "person")
        try requireUnique(kanban.projects.map(\.id), "board")
        try requireUnique(kanban.columns.map(\.id), "column")
        try requireUnique(kanban.resources.map(\.id), "membership")
        try requireUnique(kanban.labels.map(\.id), "label")
        try requireUnique(kanban.tasks.map(\.id), "card")
        try requireUnique(kanban.subtasks.map(\.id), "step")
        try requireUnique(kanban.activities.map(\.id), "change-log entry")
        try requireUnique((kanban.timeOff ?? []).map(\.id), "time-off entry")
        try requireUnique((kanban.availabilityOverrides ?? []).map(\.id), "availability override")
        // Availability (v2): each record points at what's in the file and holds real values.
        for project in kanban.projects {
            if KanbanAvailability.boardDatesProblem(project.startDay, project.endDay) != nil {
                throw BackupError.validationFailed(reason: "Board \(project.id) has invalid dates")
            }
        }
        for entry in kanban.timeOff ?? [] {
            guard entry.personId.map(personIds.contains) ?? false else {
                throw BackupError.validationFailed(reason: "Time off \(entry.id) names a person that isn't in the backup")
            }
            do { try AvailabilityRecords.check(entry) } catch {
                throw BackupError.validationFailed(reason: "Time off \(entry.id) is invalid")
            }
        }
        var overriddenWeeks = Set<String>()
        for override in kanban.availabilityOverrides ?? [] {
            guard let resource = override.resourceId, resourceIds.contains(resource) else {
                throw BackupError.validationFailed(reason: "Override \(override.id) names a membership that isn't in the backup")
            }
            guard let monday = KanbanDay(key: override.weekStart), monday.monday == monday, (0...14).contains(override.halfDays),
                  overriddenWeeks.insert("\(resource)|\(override.weekStart)").inserted else {
                throw BackupError.validationFailed(reason: "Override \(override.id) is invalid")
            }
        }
        for column in kanban.columns where KanbanColumnKind(rawValue: column.kindRaw) == nil {
            throw BackupError.validationFailed(reason: "Column \(column.id) has an unknown kind")
        }

        // Validate projects: must have exactly one backlog and at least one done column.
        var columnsByProject: [UUID: [KanbanColumnDTO]] = [:]
        for column in kanban.columns {
            guard let projectId = column.projectId else {
                throw BackupError.validationFailed(reason: "Column \(column.id) has no project")
            }
            guard projectIds.contains(projectId) else {
                throw BackupError.invalidReference(entity: "KanbanProject", id: projectId)
            }
            columnsByProject[projectId, default: []].append(column)
        }

        for project in kanban.projects {
            let cols = columnsByProject[project.id] ?? []
            let backlogCount = cols.filter { $0.kindRaw == "backlog" }.count
            let doneCount = cols.filter { $0.kindRaw == "done" }.count

            guard backlogCount == 1 else {
                throw BackupError.validationFailed(reason: "Project \(project.id) has \(backlogCount) backlog columns (expected 1)")
            }
            guard doneCount >= 1 else {
                throw BackupError.validationFailed(reason: "Project \(project.id) has \(doneCount) done columns (expected ≥1)")
            }
        }

        // Validate resources: must have a projectId and personId; at most one
        // non-archived membership per (person, project).
        var membershipKeys: [String: [KanbanResourceDTO]] = [:]
        for resource in kanban.resources {
            guard let projectId = resource.projectId else {
                throw BackupError.validationFailed(reason: "Resource \(resource.id) has no project")
            }
            guard projectIds.contains(projectId) else {
                throw BackupError.invalidReference(entity: "KanbanProject", id: projectId)
            }
            guard let personId = resource.personId else {
                throw BackupError.validationFailed(reason: "Resource \(resource.id) has no person")
            }
            guard personIds.contains(personId) else {
                throw BackupError.invalidReference(entity: "KanbanPerson", id: personId)
            }

            let key = "\(personId.uuidString),\(projectId.uuidString)"
            membershipKeys[key, default: []].append(resource)
        }

        // Check uniqueness of non-archived memberships per (person, project).
        for (_, memberships) in membershipKeys {
            let nonArchived = memberships.filter { $0.archivedAt == nil }
            guard nonArchived.count <= 1 else {
                throw BackupError.validationFailed(reason: "Multiple non-archived memberships for the same (person, project)")
            }
        }

        // Validate labels: belong to a project.
        for label in kanban.labels {
            guard let projectId = label.projectId else {
                throw BackupError.validationFailed(reason: "Label \(label.id) has no project")
            }
            guard projectIds.contains(projectId) else {
                throw BackupError.invalidReference(entity: "KanbanProject", id: projectId)
            }
        }

        // Validate tasks: ownership, relationships, and collect dependency edges.
        var tasksByProject: [UUID: [KanbanTaskDTO]] = [:]
        var tasksByColumn: [UUID: [KanbanTaskDTO]] = [:]
        var dependencyEdges: [(from: UUID, to: UUID)] = []

        for task in kanban.tasks {
            guard let projectId = task.projectId else {
                throw BackupError.validationFailed(reason: "Task \(task.id) has no project")
            }
            guard projectIds.contains(projectId) else {
                throw BackupError.invalidReference(entity: "KanbanProject", id: projectId)
            }
            tasksByProject[projectId, default: []].append(task)

            guard let columnId = task.columnId else {
                throw BackupError.validationFailed(reason: "Task \(task.id) has no column")
            }
            guard columnIds.contains(columnId) else {
                throw BackupError.invalidReference(entity: "KanbanColumn", id: columnId)
            }

            // Validate that the task's column belongs to the same project as the task.
            if let col = kanban.columns.first(where: { $0.id == columnId }) {
                guard col.projectId == projectId else {
                    throw BackupError.validationFailed(reason: "Task \(task.id)'s column belongs to a different project")
                }
            }

            tasksByColumn[columnId, default: []].append(task)

            // Resource is optional (Unassigned), but if present must be in the same project.
            if let resourceId = task.resourceId {
                guard resourceIds.contains(resourceId) else {
                    throw BackupError.invalidReference(entity: "KanbanResource", id: resourceId)
                }
                if let res = kanban.resources.first(where: { $0.id == resourceId }) {
                    guard res.projectId == projectId else {
                        throw BackupError.validationFailed(reason: "Task \(task.id)'s resource belongs to a different project")
                    }
                }
            }

            // Validate labels: all in the same project.
            for labelId in task.labelIds {
                guard labelIds.contains(labelId) else {
                    throw BackupError.invalidReference(entity: "KanbanLabel", id: labelId)
                }
                if let label = kanban.labels.first(where: { $0.id == labelId }) {
                    guard label.projectId == projectId else {
                        throw BackupError.validationFailed(reason: "Task \(task.id) has a label from a different project")
                    }
                }
            }

            // Collect dependency edges; cycles will be detected later.
            for depId in task.dependsOnIds {
                guard taskIds.contains(depId) else {
                    throw BackupError.invalidReference(entity: "KanbanTask", id: depId)
                }
                dependencyEdges.append((from: task.id, to: depId))

                // Validate same project.
                if let dep = kanban.tasks.first(where: { $0.id == depId }) {
                    guard dep.projectId == projectId else {
                        throw BackupError.validationFailed(reason: "Task \(task.id) has a dependency from a different project")
                    }
                }
            }
        }

        // Validate subtasks: belong to a task, optional assignee in the same project.
        for subtask in kanban.subtasks {
            guard let taskId = subtask.taskId else {
                throw BackupError.validationFailed(reason: "Subtask \(subtask.id) has no task")
            }
            guard taskIds.contains(taskId) else {
                throw BackupError.invalidReference(entity: "KanbanTask", id: taskId)
            }

            if let assigneeId = subtask.assigneeId {
                guard resourceIds.contains(assigneeId) else {
                    throw BackupError.invalidReference(entity: "KanbanResource", id: assigneeId)
                }
                if let task = kanban.tasks.first(where: { $0.id == taskId }),
                   let res = kanban.resources.first(where: { $0.id == assigneeId }) {
                    guard res.projectId == task.projectId else {
                        throw BackupError.validationFailed(reason: "Subtask \(subtask.id) assignee is from a different project")
                    }
                }
            }
        }

        // Validate activities: belong to a project.
        for activity in kanban.activities {
            guard let projectId = activity.projectId else {
                throw BackupError.validationFailed(reason: "Activity \(activity.id) has no project")
            }
            guard projectIds.contains(projectId) else {
                throw BackupError.invalidReference(entity: "KanbanProject", id: projectId)
            }
        }

        // Keep edges in ascending (source, target) id order and drop any that would close
        // a cycle: the dropped edge is then always the cycle's highest-source edge.
        var kept: [UUID: Set<UUID>] = [:]
        func reaches(_ from: UUID, _ target: UUID) -> Bool {
            var stack = [from], seen: Set<UUID> = []
            while let node = stack.popLast() {
                if node == target { return true }
                guard seen.insert(node).inserted else { continue }
                stack.append(contentsOf: kept[node] ?? [])
            }
            return false
        }
        var dropped = 0
        for edge in dependencyEdges.sorted(by: { ($0.from.uuidString, $0.to.uuidString) < ($1.from.uuidString, $1.to.uuidString) }) {
            if edge.from == edge.to || reaches(edge.to, edge.from) { dropped += 1; continue }
            kept[edge.from, default: []].insert(edge.to)
        }
        // A live card can't sit on an archived membership (archiving unassigns its cards);
        // repair rather than reject, sending it to Unassigned and counting it.
        let archivedResources = Set(kanban.resources.filter { $0.archivedAt != nil }.map(\.id))
        let doneColumns = Set(kanban.columns.filter { $0.kindRaw == KanbanColumnKind.done.rawValue }.map(\.id))
        var unassigned = 0, completions = 0
        var cleaned = kanban
        cleaned.tasks = kanban.tasks.map { task in
            var task = task
            task.dependsOnIds = task.dependsOnIds.filter { kept[task.id]?.contains($0) ?? false }
            if task.archivedAt == nil, let resource = task.resourceId, archivedResources.contains(resource) {
                task.resourceId = nil
                unassigned += 1
            }
            // A live card is complete exactly when it's in a Done column; repair (deterministically)
            // rather than reject.
            if task.archivedAt == nil, let column = task.columnId {
                if doneColumns.contains(column), task.completedAt == nil { task.completedAt = task.updatedAt; completions += 1 }
                if !doneColumns.contains(column), task.completedAt != nil { task.completedAt = nil; completions += 1 }
            }
            return task
        }
        return (cleaned, KanbanImportReport(droppedDependencyEdges: dropped, unassignedFromArchivedMemberships: unassigned,
                                            repairedCompletions: completions))
    }
}
