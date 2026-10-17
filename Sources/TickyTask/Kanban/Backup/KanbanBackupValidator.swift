import Foundation

/// Report of validation and import resolution issues found in a Kanban backup.
struct KanbanImportReport: Equatable, Sendable {
    /// Dependency edges dropped because they were self-edges or formed cycles.
    var droppedDependencyEdges: Int = 0
    /// Links to planner tasks that were cleared during restore because the target
    /// was missing or a hidden definition.
    var droppedPlannerLinks: Int = 0
}

/// Validates a decoded Kanban backup before restore or import, checking version,
/// referential integrity, column invariants, and resolving dependency cycles.
enum KanbanBackupValidator {
    static func validate(_ kanban: KanbanBackupDTO) throws -> KanbanImportReport {
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

        // Validate people: archived or not.
        for person in kanban.people {
            // A person's id is uniquely referenced; no other checks needed here.
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

        // Detect and drop cycles in dependency edges.
        let droppedEdges = dropCycles(in: &dependencyEdges, taskIds: taskIds)

        return KanbanImportReport(droppedDependencyEdges: droppedEdges)
    }

    /// Detect cycles in the dependency graph and drop the edge whose source task id
    /// (as uuidString) sorts last within each cycle. Returns the count of edges dropped.
    private static func dropCycles(in edges: inout [(from: UUID, to: UUID)], taskIds: Set<UUID>) -> Int {
        var dropped = 0
        var visited: Set<UUID> = []
        var recursionStack: Set<UUID> = []

        func hasCycle(node: UUID) -> Bool {
            if recursionStack.contains(node) {
                return true
            }
            if visited.contains(node) {
                return false
            }

            visited.insert(node)
            recursionStack.insert(node)

            let neighbors = edges.filter { $0.from == node }.map(\.to)
            for neighbor in neighbors {
                if hasCycle(node: neighbor) {
                    return true
                }
            }

            recursionStack.remove(node)
            return false
        }

        // Find all cycles and drop the last edge in each cycle by uuidString.
        var allVisited: Set<UUID> = []
        for startNode in taskIds {
            guard !allVisited.contains(startNode) else { continue }

            visited = []
            recursionStack = []

            if hasCycle(node: startNode) {
                // A cycle exists involving startNode. Find the edge to drop.
                // We'll drop the edge whose source sorts last within the cycle.
                // For now, use a simpler approach: drop edges with self-references first,
                // then iteratively drop the edge with the lexicographically largest source.

                // First pass: self-edges.
                let selfEdgeCount = edges.count
                edges.removeAll { $0.from == $0.to }
                dropped += selfEdgeCount - edges.count

                // Then iteratively drop edges until no cycle remains.
                while hasCycle(node: startNode) {
                    visited = []
                    recursionStack = []
                    var cycleEdges: [(from: UUID, to: UUID)] = []

                    // Find edges in the current cycle.
                    func findCycleEdges(node: UUID, path: inout [(from: UUID, to: UUID)]) {
                        if recursionStack.contains(node) {
                            // Found cycle; extract it from path.
                            if let idx = path.firstIndex(where: { $0.to == node }) {
                                cycleEdges.append(contentsOf: path[(idx + 1)...])
                            }
                            return
                        }
                        if visited.contains(node) { return }

                        visited.insert(node)
                        recursionStack.insert(node)

                        for edge in edges.filter({ $0.from == node }) {
                            var newPath = path + [edge]
                            findCycleEdges(node: edge.to, path: &newPath)
                        }

                        recursionStack.remove(node)
                    }

                    var path: [(from: UUID, to: UUID)] = []
                    findCycleEdges(node: startNode, path: &path)

                    // Drop the edge with the largest source uuidString.
                    if let maxEdge = cycleEdges.max(by: { $0.from.uuidString < $1.from.uuidString }) {
                        edges.removeAll { $0.from == maxEdge.from && $0.to == maxEdge.to }
                        dropped += 1
                    } else {
                        break // Safety: avoid infinite loop.
                    }
                }
            }

            allVisited.formUnion(visited)
        }

        return dropped
    }
}
