import Foundation

/// Validates a decoded backup **before** the importer touches the store, so a
/// malformed file can never leave the store half-wiped. Checks are grounded in
/// the real model invariants: unique ids, the day-XOR-list rule, valid day
/// keys, in-range time/priority, and referential integrity for every projected
/// relationship id.
enum BackupValidator {
    static func validate(_ store: BackupStoreDTO) throws {
        guard store.schemaVersion <= BackupStoreDTO.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(found: store.schemaVersion,
                                                supported: BackupStoreDTO.currentSchemaVersion)
        }
        guard store.schemaVersion >= 1 else { throw BackupError.corruptPayload }

        let data = store.data
        try requireUnique(data.taskItems.map(\.id), entity: "TaskItem")
        try requireUnique(data.subtasks.map(\.id), entity: "Subtask")
        try requireUnique(data.taskTags.map(\.id), entity: "TaskTag")
        try requireUnique(data.customLists.map(\.id), entity: "CustomList")
        try requireUnique(data.taskOccurrences.map(\.id), entity: "TaskOccurrence")

        let taskIds = Set(data.taskItems.map(\.id))
        let listIds = Set(data.customLists.map(\.id))
        let tagIds = Set(data.taskTags.map(\.id))

        for task in data.taskItems {
            guard task.dayKey == nil || task.customListId == nil else {
                throw BackupError.validationFailed(reason: "Task \(task.id) has both a day and a custom list")
            }
            if let key = task.dayKey, WeekMath.date(fromDayKey: key) == nil {
                throw BackupError.validationFailed(reason: "Task \(task.id) has an invalid day key")
            }
            if let listId = task.customListId, !listIds.contains(listId) {
                throw BackupError.invalidReference(entity: "CustomList", id: listId)
            }
            if let minutes = task.timeMinutes, !(0...1439).contains(minutes) {
                throw BackupError.validationFailed(reason: "Task \(task.id) has an out-of-range time")
            }
            guard TaskPriority(rawValue: task.priority) != nil else {
                throw BackupError.validationFailed(reason: "Task \(task.id) has an unknown priority")
            }
            guard Set(task.tagIds).count == task.tagIds.count else {
                throw BackupError.validationFailed(reason: "Task \(task.id) lists the same tag more than once")
            }
            for tagId in task.tagIds where !tagIds.contains(tagId) {
                throw BackupError.invalidReference(entity: "TaskTag", id: tagId)
            }
            if let rule = task.recurrence {
                guard rule.interval >= 1,
                      rule.weekdays.allSatisfy((1...7).contains),
                      rule.monthDays.allSatisfy((1...31).contains) else {
                    throw BackupError.validationFailed(reason: "Task \(task.id) has an invalid recurrence rule")
                }
                if case .afterCount(let count) = rule.end, count < 1 {
                    throw BackupError.validationFailed(reason: "Task \(task.id) has a non-positive recurrence count")
                }
                switch rule.frequency {
                case .customWeekdays where rule.weekdays.isEmpty:
                    throw BackupError.validationFailed(reason: "Task \(task.id) repeats on custom weekdays but names none")
                case .daysOfMonth where rule.monthDays.isEmpty:
                    throw BackupError.validationFailed(reason: "Task \(task.id) repeats on days of the month but names none")
                default:
                    break
                }
            }
        }

        for sub in data.subtasks {
            if let parentId = sub.parentId, !taskIds.contains(parentId) {
                throw BackupError.invalidReference(entity: "TaskItem", id: parentId)
            }
        }

        var occurrenceKeys = Set<String>()
        for occ in data.taskOccurrences {
            guard WeekMath.date(fromDayKey: occ.dayKey) != nil else {
                throw BackupError.validationFailed(reason: "Occurrence \(occ.id) has an invalid day key")
            }
            if let minutes = occ.timeOverride, !(0...1439).contains(minutes) {
                throw BackupError.validationFailed(reason: "Occurrence \(occ.id) has an out-of-range time override")
            }
            if let templateId = occ.templateId {
                guard taskIds.contains(templateId) else {
                    throw BackupError.invalidReference(entity: "TaskItem", id: templateId)
                }
                // One override per (template, day) — duplicates would let the app
                // pick an arbitrary winner for a single occurrence.
                guard occurrenceKeys.insert("\(templateId.uuidString)#\(occ.dayKey)").inserted else {
                    throw BackupError.validationFailed(
                        reason: "Duplicate occurrence for template \(templateId) on \(occ.dayKey)")
                }
            }
        }
    }

    private static func requireUnique(_ ids: [UUID], entity: String) throws {
        guard Set(ids).count == ids.count else {
            throw BackupError.validationFailed(reason: "\(entity) contains duplicate ids")
        }
    }
}
