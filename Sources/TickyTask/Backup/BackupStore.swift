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

    var totalAdded: Int { taskItems.added + subtasks.added + taskTags.added + customLists.added + taskOccurrences.added }
    var totalUpdated: Int { taskItems.updated + subtasks.updated + taskTags.updated + customLists.updated + taskOccurrences.updated }
    var totalRemoved: Int { taskItems.removed + subtasks.removed + taskTags.removed + customLists.removed + taskOccurrences.removed }
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

        return BackupStoreDTO(
            schemaVersion: BackupStoreDTO.currentSchemaVersion,
            appVersion: appVersion,
            exportedAt: Date(),
            data: data,
            settings: AppSettingsDTO.capture()
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

        return BackupDiff(
            taskItems: EntityDiff(imported: Set(store.data.taskItems.map(\.id)), existing: tasks),
            subtasks: EntityDiff(imported: Set(store.data.subtasks.map(\.id)), existing: subs),
            taskTags: EntityDiff(imported: Set(store.data.taskTags.map(\.id)), existing: tags),
            customLists: EntityDiff(imported: Set(store.data.customLists.map(\.id)), existing: lists),
            taskOccurrences: EntityDiff(imported: Set(store.data.taskOccurrences.map(\.id)), existing: occs)
        )
    }

    /// Replace the entire store with `store`'s contents in one transaction.
    static func restore(_ store: BackupStoreDTO, context: ModelContext) throws {
        try BackupValidator.validate(store)
        do {
            try wipe(context: context)
            insert(store.data, context: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        // The store was replaced wholesale — tell the app so it can regenerate any
        // recurring occurrences now due (the running session's materialization
        // horizon may otherwise suppress them until a relaunch or navigation).
        NotificationCenter.default.post(name: .tickyTaskStoreRestored, object: nil)
        // Apply the backed-up preferences once the data restore has succeeded.
        store.settings?.apply()
        // Settings live in UserDefaults; reschedule the end-of-day reminder now so
        // notification behavior matches the restored settings without a relaunch.
        let defaults = UserDefaults.standard
        let reminderEnabled = defaults.bool(forKey: "endOfDayReminderEnabled")
        let reminderMinutes = defaults.object(forKey: "endOfDayReminderMinutes") as? Int ?? 18 * 60
        Task { @MainActor in
            await NotificationService.scheduleEndOfDayReminder(enabled: reminderEnabled, minutes: reminderMinutes)
        }
    }

    // MARK: Private

    private static func wipe(context: ModelContext) throws {
        for t in try context.fetch(FetchDescriptor<TaskItem>()) { context.delete(t) }
        for s in try context.fetch(FetchDescriptor<Subtask>()) { context.delete(s) }
        for o in try context.fetch(FetchDescriptor<TaskOccurrence>()) { context.delete(o) }
        for g in try context.fetch(FetchDescriptor<TaskTag>()) { context.delete(g) }
        for l in try context.fetch(FetchDescriptor<CustomList>()) { context.delete(l) }
    }

    /// Insert in dependency order — lists & tags first, then tasks (which link
    /// to them), then children (subtasks, occurrences) that link to tasks.
    private static func insert(_ data: BackupDataDTO, context: ModelContext) {
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
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
