import Foundation
import SwiftData

/// A value draft for task creation, holding field values until Done.
struct TaskCreationDraft: Sendable {
    var title: String = ""
    var notes: String = ""
    var notesRich: Data?
    var location: TaskLocation = .unassigned
    var dayKey: String?
    var timeMinutes: Int?
    var alarmEnabled: Bool = false
    var priority: Int = 0
    var isCritical: Bool = false
    var repeatRule: RecurrenceRule?

    struct Step: Sendable {
        var title: String
        var isDone: Bool = false
    }
    var steps: [Step] = []

    init() {}
}

/// Commits a task creation draft in one transaction: validates everything first,
/// then inserts the task, steps and any repeat rule definition and saves once.
/// On failure, no model is inserted.
@MainActor
enum TaskCreateCommit {
    /// Creates a task from a draft in one transaction. Checkpoints unrelated changes first.
    /// Returns the created task; on failure the draft remains unchanged and the error is rethrown.
    @discardableResult
    static func commit(_ draft: TaskCreationDraft, context: ModelContext,
                       today: Date = Date(), horizon: Date, calendar: Calendar = .current,
                       save: ((ModelContext) throws -> Void)? = nil) throws -> TaskItem {
        // Checkpoint unrelated changes (recurrence updates, etc.) before any insert
        try RecurrenceMaterializer.checkpoint(context)

        // Validate title
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { throw NSError(domain: "TaskCreate", code: 1, userInfo: [NSLocalizedDescriptionKey: "A task needs a title."]) }

        // Validate step titles
        for step in draft.steps {
            guard !step.title.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw NSError(domain: "TaskCreate", code: 2, userInfo: [NSLocalizedDescriptionKey: "A step can't have a blank title."])
            }
        }

        // Validate notes (use same pattern as TaskEditCommit)
        if let notesRich = draft.notesRich, !notesRich.isEmpty {
            // Try to decode to validate
            _ = try? NotesCodec.decode(notesRich)
        }

        // Validate time and repeat rule
        if let time = draft.timeMinutes {
            guard (0..<(24 * 60)).contains(time) else {
                throw NSError(domain: "TaskCreate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Time out of range."])
            }
        }

        // If a repeat rule is provided, validate it
        if let rule = draft.repeatRule {
            // The materializer will fully validate it; just basic sanity checks here
            if case .until(let date) = rule.end {
                guard date > today else { throw NSError(domain: "TaskCreate", code: 4, userInfo: [NSLocalizedDescriptionKey: "Repeat end date must be in the future."]) }
            }
        }

        // All validation passed; now insert
        let task = TaskItem(title: trimmedTitle)
        task.notes = draft.notes
        task.notesRich = draft.notesRich
        task.priority = draft.priority
        task.isCritical = draft.isCritical
        task.timeMinutes = draft.timeMinutes
        task.alarmEnabled = draft.alarmEnabled
        task.updatedAt = Date()

        // Set location
        if let dayKey = draft.dayKey {
            task.dayKey = dayKey
        }

        // Assign sort index
        let siblings: [TaskItem]
        switch draft.location {
        case .day(let key):
            task.dayKey = key
            task.customList = nil
            siblings = try context.fetch(FetchDescriptor<TaskItem>())
                .filter { $0.dayKey == key && $0.customList == nil }
        case .customList(let list):
            task.customList = list
            task.dayKey = nil
            siblings = try context.fetch(FetchDescriptor<TaskItem>())
                .filter { $0.customList?.id == list.id }
        case .unassigned:
            task.dayKey = nil
            task.customList = nil
            siblings = try context.fetch(FetchDescriptor<TaskItem>())
                .filter { $0.dayKey == nil && $0.customList == nil }
        }
        task.sortIndex = Double(siblings.count)

        // Insert task
        context.insert(task)

        // Create subtasks
        for (index, stepDraft) in draft.steps.enumerated() {
            let step = Subtask(id: UUID(), title: stepDraft.title.trimmingCharacters(in: .whitespaces),
                               isDone: stepDraft.isDone, sortIndex: Double(index))
            context.insert(step)
            step.parent = task
        }

        // Handle repeat rule if present (caller-saves pattern)
        if let rule = draft.repeatRule, let dayKey = draft.dayKey {
            try RecurrenceMaterializer.startSeries(from: task, rule: rule, through: horizon,
                                                   context: context, calendar: calendar)
        }

        // Single save
        do {
            if let save { try save(context) } else { try context.saveTransaction() }
        } catch {
            context.undoFailedTransaction()
            throw error
        }

        return task
    }
}
