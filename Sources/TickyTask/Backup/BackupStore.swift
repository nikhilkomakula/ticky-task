import Foundation
import SwiftData

extension Notification.Name {
    /// Posted after a backup restore replaces the entire store, so views can reset
    /// session-scoped caches (e.g. the recurrence materialization horizon) and
    /// regenerate derived rows.
    static let tickyTaskStoreRestored = Notification.Name("TickyTaskStoreRestored")
}

/// Per-entity add/update/remove counts for the restore preview.
struct EntityDiff: Equatable, Sendable {
    let added: Int
    let updated: Int
    let removed: Int

    init(imported: Set<UUID>, existing: Set<UUID>) {
        added = imported.subtracting(existing).count
        updated = imported.intersection(existing).count
        removed = existing.subtracting(imported).count
    }
}

/// What a restore would change, shown to the user before they confirm.
struct BackupDiff: Equatable, Sendable {
    let taskItems: EntityDiff
    let subtasks: EntityDiff
    let taskTags: EntityDiff
    let customLists: EntityDiff
    let taskOccurrences: EntityDiff
    /// Kanban data (added/updated/removed counts per entity).
    let kanban: KanbanBackupDiff?
    /// Links to planner tasks cleared during import.
    let droppedPlannerLinks: Int

    var totalAdded: Int { taskItems.added + subtasks.added + taskTags.added + customLists.added + taskOccurrences.added + (kanban?.totalAdded ?? 0) }
    var totalUpdated: Int { taskItems.updated + subtasks.updated + taskTags.updated + customLists.updated + taskOccurrences.updated + (kanban?.totalUpdated ?? 0) }
    var totalRemoved: Int { taskItems.removed + subtasks.removed + taskTags.removed + customLists.removed + taskOccurrences.removed + (kanban?.totalRemoved ?? 0) }
}

/// Kanban-specific diff for the backup preview.
struct KanbanBackupDiff: Equatable, Sendable {
    let people: EntityDiff
    let projects: EntityDiff
    let columns: EntityDiff
    let resources: EntityDiff
    let labels: EntityDiff
    let tasks: EntityDiff
    let subtasks: EntityDiff
    let activities: EntityDiff
    let droppedDependencyEdges: Int

    var totalAdded: Int { people.added + projects.added + columns.added + resources.added + labels.added + tasks.added + subtasks.added + activities.added }
    var totalUpdated: Int { people.updated + projects.updated + columns.updated + resources.updated + labels.updated + tasks.updated + subtasks.updated + activities.updated }
    var totalRemoved: Int { people.removed + projects.removed + columns.removed + resources.removed + labels.removed + tasks.removed + subtasks.removed + activities.removed }
}

/// Bridges live SwiftData models and the pure `BackupService`: reads a snapshot
/// out of a `ModelContext`, previews a restore diff, and applies a restore as an
/// all-or-nothing replace. Restore is **replace-all**: validate the whole
/// snapshot first, then wipe and re-insert in one transaction, rolling back on
/// any error so a bad import can never leave a half-populated store.
@MainActor
enum BackupStore {
    static let service = BackupService()

    // MARK: Export

    static func makeSnapshot(context: ModelContext) throws -> BackupStoreDTO {
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let subs = try context.fetch(FetchDescriptor<Subtask>())
        let tags = try context.fetch(FetchDescriptor<TaskTag>())
        let lists = try context.fetch(FetchDescriptor<CustomList>())
        let occs = try context.fetch(FetchDescriptor<TaskOccurrence>())

        let data = BackupDataDTO(
            taskItems: tasks.map(TaskItemDTO.init),
            subtasks: subs.map(SubtaskDTO.init),
            taskTags: tags.map(TaskTagDTO.init),
            customLists: lists.map(CustomListDTO.init),
            taskOccurrences: occs.map(TaskOccurrenceDTO.init)
        ).deterministicallySorted()

        let kanban = try KanbanBackupDTO.snapshot(context: context)

        return BackupStoreDTO(
            schemaVersion: BackupStoreDTO.currentSchemaVersion,
            appVersion: appVersion,
            exportedAt: Date(),
            data: data,
            settings: AppSettingsDTO.capture(),
            kanban: kanban
        )
    }

    static func exportData(context: ModelContext, passphrase: String?) throws -> Data {
        try service.makeFile(store: makeSnapshot(context: context), passphrase: passphrase)
    }

    // MARK: Import

    static func preview(_ store: BackupStoreDTO, context: ModelContext) throws -> BackupDiff {
        let tasks = Set(try context.fetch(FetchDescriptor<TaskItem>()).map(\.id))
        let subs = Set(try context.fetch(FetchDescriptor<Subtask>()).map(\.id))
        let tags = Set(try context.fetch(FetchDescriptor<TaskTag>()).map(\.id))
        let lists = Set(try context.fetch(FetchDescriptor<CustomList>()).map(\.id))
        let occs = Set(try context.fetch(FetchDescriptor<TaskOccurrence>()).map(\.id))

        var kanbanDiff: KanbanBackupDiff? = nil
        var droppedLinks = 0

        if let kanbanSection = store.kanban {
            let people = Set(try context.fetch(FetchDescriptor<KanbanPerson>()).map(\.id))
            let projects = Set(try context.fetch(FetchDescriptor<KanbanProject>()).map(\.id))
            let columns = Set(try context.fetch(FetchDescriptor<KanbanColumn>()).map(\.id))
            let resources = Set(try context.fetch(FetchDescriptor<KanbanResource>()).map(\.id))
            let labels = Set(try context.fetch(FetchDescriptor<KanbanLabel>()).map(\.id))
            let kanbanTasks = Set(try context.fetch(FetchDescriptor<KanbanTask>()).map(\.id))
            let subtasks = Set(try context.fetch(FetchDescriptor<KanbanSubtask>()).map(\.id))
            let activities = Set(try context.fetch(FetchDescriptor<KanbanActivity>()).map(\.id))

            let report = try KanbanBackupValidator.validate(kanbanSection)
            kanbanDiff = KanbanBackupDiff(
                people: EntityDiff(imported: Set(kanbanSection.people.map(\.id)), existing: people),
                projects: EntityDiff(imported: Set(kanbanSection.projects.map(\.id)), existing: projects),
                columns: EntityDiff(imported: Set(kanbanSection.columns.map(\.id)), existing: columns),
                resources: EntityDiff(imported: Set(kanbanSection.resources.map(\.id)), existing: resources),
                labels: EntityDiff(imported: Set(kanbanSection.labels.map(\.id)), existing: labels),
                tasks: EntityDiff(imported: Set(kanbanSection.tasks.map(\.id)), existing: kanbanTasks),
                subtasks: EntityDiff(imported: Set(kanbanSection.subtasks.map(\.id)), existing: subtasks),
                activities: EntityDiff(imported: Set(kanbanSection.activities.map(\.id)), existing: activities),
                droppedDependencyEdges: report.droppedDependencyEdges
            )
        }
        // Links that the restore will clear: their target isn't in the file's planner
        // rows, or is a series definition. A file without a board section keeps the
        // existing boards, so their links are checked instead.
        let linkable = linkablePlannerIDs(store.data.taskItems)
        if let kanbanSection = store.kanban {
            droppedLinks = kanbanSection.tasks.filter { $0.linkedPlannerTaskID.map { !linkable.contains($0) } ?? false }.count
        } else {
            droppedLinks = try context.fetch(FetchDescriptor<KanbanTask>())
                .filter { $0.linkedPlannerTaskID.map { !linkable.contains($0) } ?? false }.count
        }

        return BackupDiff(
            taskItems: EntityDiff(imported: Set(store.data.taskItems.map(\.id)), existing: tasks),
            subtasks: EntityDiff(imported: Set(store.data.subtasks.map(\.id)), existing: subs),
            taskTags: EntityDiff(imported: Set(store.data.taskTags.map(\.id)), existing: tags),
            customLists: EntityDiff(imported: Set(store.data.customLists.map(\.id)), existing: lists),
            taskOccurrences: EntityDiff(imported: Set(store.data.taskOccurrences.map(\.id)), existing: occs),
            kanban: kanbanDiff,
            droppedPlannerLinks: droppedLinks
        )
    }

    /// Replace the entire store with `store`'s contents in one transaction.
    /// D11 semantics: if kanban key is absent, keep existing boards; if present,
    /// replace them (empty means no boards).
    static func restore(_ store: BackupStoreDTO, context: ModelContext) throws {
        try BackupValidator.validate(store)
        // The board section to insert, with cycle-closing dependency edges removed.
        let kanbanSection = try store.kanban.map { try KanbanBackupValidator.sanitized($0).dto }

        // Commit unrelated pending edits first, outside the transaction, so a failure
        // here undoes nothing of theirs.
        try RecurrenceMaterializer.checkpoint(context)

        do {
            // MARK: - Prepare phase (all can fail and will roll back in place)

            // Fetch existing planner data (always deleted).
            let existingPlanner = try fetchAllPlanner(context: context)

            // Fetch existing Kanban data (deleted only if kanban section is present).
            let existingKanban: [any PersistentModel] = store.kanban != nil ?
                try fetchAllKanban(context: context) : []
            // Boards kept by a file without a board section (D11); their links are
            // repaired against the restored planner rows below.
            let retainedKanbanTasks: [KanbanTask] = store.kanban == nil ?
                try context.fetch(FetchDescriptor<KanbanTask>()) : []

            // MARK: - Delete phase (only non-throwing work follows)

            // Delete all existing planner data.
            existingPlanner.forEach { context.delete($0) }

            // Delete Kanban data if the section is present (D11: absent = keep).
            existingKanban.forEach { context.delete($0) }

            // MARK: - Insert phase (non-throwing)

            let insertedPlanner = insert(store.data, context: context)
            RecurrenceNormalizer.normalize(insertedPlanner, context: context)

            var boardTasks = retainedKanbanTasks
            if let kanbanSection {
                boardTasks = insertKanban(kanbanSection, context: context).tasksByProject.values.flatMap { $0 }
            }
            // Repair every kept and imported planner link against the normalised rows:
            // keep it only if its target exists and isn't a series definition.
            let linkable = Set(insertedPlanner.filter(isLinkable).map(\.id))
            for task in boardTasks {
                if let link = task.linkedPlannerTaskID, !linkable.contains(link) { task.linkedPlannerTaskID = nil }
            }

            // MARK: - Commit

            try context.saveTransaction()

            // MARK: - Post-transaction

            store.settings?.apply()
            NotificationCenter.default.post(name: .tickyTaskStoreRestored, object: nil)

            let defaults = UserDefaults.standard
            let reminderEnabled = defaults.bool(forKey: "endOfDayReminderEnabled")
            let reminderMinutes = defaults.integer(forKey: "endOfDayReminderMinutes", default: 18 * 60)
            Task { @MainActor in
                await NotificationService.scheduleEndOfDayReminder(enabled: reminderEnabled, minutes: reminderMinutes)
            }
        } catch {
            context.undoFailedTransaction()
            throw error
        }
    }

    // MARK: Private

    private static func fetchAllPlanner(context: ModelContext) throws -> [any PersistentModel] {
        var all: [any PersistentModel] = []
        all += try context.fetch(FetchDescriptor<TaskItem>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<Subtask>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<TaskOccurrence>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<TaskTag>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<CustomList>()) as [any PersistentModel]
        return all
    }

    private static func fetchAllKanban(context: ModelContext) throws -> [any PersistentModel] {
        var all: [any PersistentModel] = []
        all += try context.fetch(FetchDescriptor<KanbanPerson>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<KanbanProject>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<KanbanColumn>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<KanbanResource>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<KanbanLabel>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<KanbanTask>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<KanbanSubtask>()) as [any PersistentModel]
        all += try context.fetch(FetchDescriptor<KanbanActivity>()) as [any PersistentModel]
        return all
    }

    private static func fetchAll(context: ModelContext) throws -> [any PersistentModel] {
        var all: [any PersistentModel] = []
        all += try fetchAllPlanner(context: context)
        all += try fetchAllKanban(context: context)
        return all
    }

    /// Insert in dependency order — lists & tags first, then tasks (which link
    /// to them), then children (subtasks, occurrences) that link to tasks.
    @discardableResult
    private static func insert(_ data: BackupDataDTO, context: ModelContext) -> [TaskItem] {
        var listMap: [UUID: CustomList] = [:]
        for dto in data.customLists {
            let list = CustomList(id: dto.id, name: dto.name, sortIndex: dto.sortIndex)
            context.insert(list)
            listMap[dto.id] = list
        }

        var tagMap: [UUID: TaskTag] = [:]
        for dto in data.taskTags {
            let tag = TaskTag(id: dto.id, name: dto.name, colorHex: dto.colorHex)
            context.insert(tag)
            tagMap[dto.id] = tag
        }

        var taskMap: [UUID: TaskItem] = [:]
        for dto in data.taskItems {
            let task = TaskItem(
                id: dto.id, title: dto.title, dayKey: dto.dayKey,
                customList: dto.customListId.flatMap { listMap[$0] },
                timeMinutes: dto.timeMinutes, colorHex: dto.colorHex,
                priority: dto.priority, sortIndex: dto.sortIndex,
                alarmEnabled: dto.alarmEnabled, recurrence: dto.recurrence
            )
            task.notes = dto.notes
            task.notesRich = dto.notesRich
            task.isDone = dto.isDone
            task.isCritical = dto.needsImmediateAttention ?? false
            task.completedAt = dto.completedAt
            task.templateID = dto.templateId
            task.occurrenceKey = dto.occurrenceKey
            task.recurrenceEffectiveFromKey = dto.recurrenceEffectiveFromKey
            task.occurrenceModified = dto.occurrenceModified
            task.createdAt = dto.createdAt
            task.updatedAt = dto.updatedAt
            task.tags = dto.tagIds.compactMap { tagMap[$0] }
            context.insert(task)
            taskMap[dto.id] = task
        }

        for dto in data.subtasks {
            let sub = Subtask(id: dto.id, title: dto.title, isDone: dto.isDone, sortIndex: dto.sortIndex)
            sub.parent = dto.parentId.flatMap { taskMap[$0] }
            context.insert(sub)
        }

        for dto in data.taskOccurrences {
            let occ = TaskOccurrence(id: dto.id, dayKey: dto.dayKey, isDone: dto.isDone,
                                     skipped: dto.skipped, titleOverride: dto.titleOverride,
                                     timeOverride: dto.timeOverride)
            occ.template = dto.templateId.flatMap { taskMap[$0] }
            context.insert(occ)
        }
        return Array(taskMap.values)
    }

    /// Graph of inserted Kanban objects, used for link repair.
    struct KanbanInsertedGraph {
        var tasksByProject: [UUID: [KanbanTask]] = [:]
    }

    /// Insert Kanban data in dependency order: people, projects, columns, labels,
    /// resources, tasks, subtasks, activities, then dependency edges.
    private static func insertKanban(_ kanban: KanbanBackupDTO, context: ModelContext) -> KanbanInsertedGraph {
        var personMap: [UUID: KanbanPerson] = [:]
        for dto in kanban.people {
            let person = KanbanPerson(id: dto.id, name: dto.name, initials: dto.initials)
            person.colorHex = dto.colorHex
            person.employmentRaw = dto.employmentRaw
            person.skills = dto.skills
            person.createdAt = dto.createdAt
            person.archivedAt = dto.archivedAt
            context.insert(person)
            personMap[dto.id] = person
        }

        var projectMap: [UUID: KanbanProject] = [:]
        for dto in kanban.projects {
            let project = KanbanProject(id: dto.id, name: dto.name, key: dto.key, sortIndex: dto.sortIndex)
            project.details = dto.details
            project.colorHex = dto.colorHex
            project.symbolName = dto.symbolName
            project.isPinned = dto.isPinned
            project.createdAt = dto.createdAt
            project.updatedAt = dto.updatedAt
            project.archivedAt = dto.archivedAt
            project.workWeekDays = dto.workWeekDays
            project.hoursPerDay = dto.hoursPerDay
            project.defaultCapacityHoursPerWeek = dto.defaultCapacityHoursPerWeek
            project.wipPolicyRaw = dto.wipPolicyRaw
            project.loadMeasureRaw = dto.loadMeasureRaw
            project.openTaskTarget = dto.openTaskTarget
            project.defaultEstimateHours = dto.defaultEstimateHours
            project.weightedLoad = dto.weightedLoad
            project.dueSoonThresholdDays = dto.dueSoonThresholdDays
            project.suggestDoneWhenSubtasksComplete = dto.suggestDoneWhenSubtasksComplete
            project.collapsedRowKeys = dto.collapsedRowKeys
            project.boardState = dto.boardState
            // Never below an imported entry's number, whatever the file says.
            let highest = kanban.activities.filter { $0.projectId == dto.id }.map(\.seq).max() ?? 0
            project.nextActivitySeq = max(dto.nextActivitySeq, highest + 1)
            // Rows are rebuilt from the backup, so earlier entries can't be reverted.
            project.historyBoundarySeq = project.nextActivitySeq - 1
            context.insert(project)
            projectMap[dto.id] = project
        }

        var columnMap: [UUID: KanbanColumn] = [:]
        for dto in kanban.columns {
            let column = KanbanColumn(id: dto.id, name: dto.name, sortIndex: dto.sortIndex)
            column.colorHex = dto.colorHex
            column.symbolName = dto.symbolName
            column.wipLimit = dto.wipLimit
            column.kindRaw = dto.kindRaw
            column.project = dto.projectId.flatMap { projectMap[$0] }
            context.insert(column)
            columnMap[dto.id] = column
        }

        var labelMap: [UUID: KanbanLabel] = [:]
        for dto in kanban.labels {
            let label = KanbanLabel(id: dto.id, name: dto.name, colorHex: dto.colorHex, sortIndex: dto.sortIndex)
            label.symbolName = dto.symbolName
            label.project = dto.projectId.flatMap { projectMap[$0] }
            context.insert(label)
            labelMap[dto.id] = label
        }

        var resourceMap: [UUID: KanbanResource] = [:]
        for dto in kanban.resources {
            let resource = KanbanResource(id: dto.id)
            resource.project = dto.projectId.flatMap { projectMap[$0] }
            resource.person = dto.personId.flatMap { personMap[$0] }
            resource.role = dto.role
            resource.assignmentRaw = dto.assignmentRaw
            resource.allocationPercent = dto.allocationPercent
            resource.capacityHoursPerWeekOverride = dto.capacityHoursPerWeekOverride
            resource.openTaskTargetOverride = dto.openTaskTargetOverride
            resource.startDate = dto.startDate
            resource.endDate = dto.endDate
            resource.sortIndex = dto.sortIndex
            resource.archivedAt = dto.archivedAt
            context.insert(resource)
            resourceMap[dto.id] = resource
        }

        var taskMap: [UUID: KanbanTask] = [:]
        var tasksByProject: [UUID: [KanbanTask]] = [:]

        for dto in kanban.tasks {
            let task = KanbanTask(id: dto.id, title: dto.title, priority: dto.priority, sortIndex: dto.sortIndex)
            task.notes = dto.notes
            task.notesRich = dto.notesRich
            task.isCritical = dto.isCritical
            task.dueDate = dto.dueDate
            task.startDate = dto.startDate
            task.estimateHours = dto.estimateHours
            task.complexity = dto.complexity.flatMap { KanbanComplexity(rawValue: $0)?.rawValue }
            task.jiraURL = dto.jiraURL
            task.isBlocked = dto.isBlocked
            task.blockedReason = dto.blockedReason
            task.linkedPlannerTaskID = dto.linkedPlannerTaskID
            task.createdAt = dto.createdAt
            task.updatedAt = dto.updatedAt
            task.completedAt = dto.completedAt
            task.archivedAt = dto.archivedAt
            task.project = dto.projectId.flatMap { projectMap[$0] }
            task.column = dto.columnId.flatMap { columnMap[$0] }
            task.resource = dto.resourceId.flatMap { resourceMap[$0] }
            task.labels = dto.labelIds.compactMap { labelMap[$0] }
            context.insert(task)
            taskMap[dto.id] = task

            if let projId = dto.projectId {
                tasksByProject[projId, default: []].append(task)
            }
        }

        for dto in kanban.subtasks {
            let subtask = KanbanSubtask(id: dto.id, title: dto.title, isDone: dto.isDone, sortIndex: dto.sortIndex)
            subtask.completedAt = dto.completedAt
            subtask.task = dto.taskId.flatMap { taskMap[$0] }
            subtask.assignee = dto.assigneeId.flatMap { resourceMap[$0] }
            context.insert(subtask)
        }

        // Add dependency edges.
        for (sourceId, targetIds) in kanban.tasks.reduce(into: [UUID: [UUID]]()) { dict, task in
            if let projectId = task.projectId {
                dict[task.id] = task.dependsOnIds
            }
        } {
            if let source = taskMap[sourceId] {
                let targets = targetIds.compactMap { taskMap[$0] }
                source.dependsOn = targets
            }
        }

        for dto in kanban.activities {
            let activity = KanbanActivity(id: dto.id, seq: dto.seq, at: dto.at, kind: dto.kindRaw,
                                         taskIDs: dto.taskIDs, summary: dto.summary, payload: dto.payload)
            activity.revertsActivityID = dto.revertsActivityID
            activity.revertedByActivityID = dto.revertedByActivityID
            activity.project = dto.projectId.flatMap { projectMap[$0] }
            context.insert(activity)
        }

        return KanbanInsertedGraph(tasksByProject: tasksByProject)
    }

    /// A planner row a board card may link to: anything but a series definition
    /// (a rule and no parent series), which is hidden from the planner.
    private static func isLinkable(_ task: TaskItem) -> Bool {
        task.recurrence == nil || task.templateID != nil
    }

    /// The ids a restore of `items` leaves linkable. A pre-v0.1.17 series row (a rule
    /// on a dated row) becomes a definition when normalised, so it isn't linkable either.
    private static func linkablePlannerIDs(_ items: [TaskItemDTO]) -> Set<UUID> {
        Set(items.filter { $0.recurrence == nil || $0.templateId != nil }.map(\.id))
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
