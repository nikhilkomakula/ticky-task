import Foundation
import SwiftData

/// What one normalization pass changed (and what it deliberately left alone).
struct NormalizationReport: Equatable {
    var splitDefinitions = 0
    var backfilledSlots = 0
    var restoredOverrides = 0
    /// Legacy override records that disagree with an existing occurrence. Both are
    /// kept as they are; nothing is overwritten.
    var conflicts: [String] = []
}

/// Brings recurring series stored by older releases into the current shape:
/// a hidden definition plus one ordinary occurrence row per scheduled slot.
///
/// Idempotent and safe to run on every materialization and restore, so any old
/// store or backup is converted before anything reads it — there is no "already
/// migrated" flag to get out of step. Nothing is homogenized: legacy titles,
/// times, and tags that differ across a series stay as they are until the user
/// edits that field. Does not save; the caller commits it with its own changes.
@MainActor
enum RecurrenceNormalizer {
    @discardableResult
    static func normalize(context: ModelContext) throws -> NormalizationReport {
        normalize(try context.fetch(FetchDescriptor<TaskItem>()), context: context)
    }

    /// Normalize exactly `all` (every task in the store), without fetching.
    @discardableResult
    static func normalize(_ all: [TaskItem], context: ModelContext) -> NormalizationReport {
        var report = NormalizationReport()
        var childrenBySeries = Dictionary(grouping: all.filter { $0.templateID != nil }) { $0.templateID! }
        var sortCache: [String: Double] = [:]

        for definition in all where definition.recurrence != nil && definition.templateID == nil {
            if definition.dayKey != nil || definition.customList != nil {
                childrenBySeries[definition.id, default: []].append(splitFirstOccurrence(from: definition, context: context))
                report.splitDefinitions += 1
            }
        }
        // Rows generated before slots were recorded sit on their slot unless the
        // user moved them, which can't be told apart now — the current day is the
        // best record. A row moved after this release (`occurrenceModified == true`)
        // or sitting in a list has no recoverable slot and keeps `nil`.
        for child in childrenBySeries.values.joined()
        where child.occurrenceKey == nil && child.occurrenceModified == nil && child.dayKey != nil {
            child.occurrenceKey = child.dayKey
            report.backfilledSlots += 1
        }
        for definition in all where definition.recurrence != nil && definition.templateID == nil {
            restoreOverrides(of: definition, children: childrenBySeries[definition.id] ?? [],
                             sortCache: &sortCache, context: context, report: &report)
        }
        for conflict in report.conflicts { NSLog("TickyTask: recurring-series normalization kept both: \(conflict)") }
        return report
    }

    /// Releases before 0.1.17 used the definition row as the series' first
    /// occurrence. Move that occurrence — its placement, order, notes, completion,
    /// timestamps, and the same subtask objects — onto a row of its own, and leave
    /// the definition holding only the rule and the shared attributes.
    private static func splitFirstOccurrence(from definition: TaskItem, context: ModelContext) -> TaskItem {
        let occurrence = TaskItem(title: definition.title, dayKey: definition.dayKey,
                                  customList: definition.customList, timeMinutes: definition.timeMinutes,
                                  colorHex: definition.colorHex, priority: definition.priority,
                                  sortIndex: definition.sortIndex, alarmEnabled: definition.alarmEnabled)
        occurrence.isCritical = definition.isCritical
        occurrence.notes = definition.notes
        occurrence.notesRich = definition.notesRich
        occurrence.isDone = definition.isDone
        occurrence.completedAt = definition.completedAt
        occurrence.createdAt = definition.createdAt
        occurrence.updatedAt = definition.updatedAt
        occurrence.tags = definition.tags
        occurrence.templateID = definition.id
        occurrence.occurrenceKey = definition.dayKey
        context.insert(occurrence)
        for subtask in Array(definition.subtasks) { subtask.parent = occurrence }

        definition.dayKey = nil
        definition.customList = nil
        definition.notes = ""
        definition.notesRich = nil
        definition.isDone = false
        definition.completedAt = nil
        return occurrence
    }

    /// Before 0.1.13 occurrences were virtual and a completed or edited one was a
    /// `TaskOccurrence` override. Give each such slot a real occurrence carrying that
    /// state (without inventing a completion date). A skipped slot stays skipped; a
    /// slot that already has an occurrence is left alone, and a disagreement is
    /// reported rather than resolved. The records themselves are never changed.
    private static func restoreOverrides(of definition: TaskItem, children: [TaskItem],
                                         sortCache: inout [String: Double], context: ModelContext,
                                         report: inout NormalizationReport) {
        var bySlot = Dictionary(grouping: children.filter { $0.occurrenceKey != nil }) { $0.occurrenceKey! }
        // A skip always wins: older releases could add one beside an override for
        // the same slot, and the user's deletion must not be undone.
        let skippedSlots = Set(definition.occurrences.filter(\.skipped).map(\.dayKey))
        let overrides = definition.occurrences
            .filter { !$0.skipped && !skippedSlots.contains($0.dayKey) }
            .filter { $0.isDone || $0.titleOverride != nil || $0.timeOverride != nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }   // deterministic when a slot has several
        for record in overrides {
            if let existing = bySlot[record.dayKey] {
                let agrees = existing.contains { row in
                    (!record.isDone || row.isDone)
                        && (record.titleOverride.map { $0 == row.title } ?? true)
                        && (record.timeOverride.map { $0 == row.timeMinutes } ?? true)
                }
                if !agrees {
                    report.conflicts.append("series \(definition.id) slot \(record.dayKey)")
                }
                continue
            }
            let occurrence = RecurrenceMaterializer.makeOccurrence(of: definition, slot: record.dayKey)
            occurrence.occurrenceModified = nil
            occurrence.isDone = record.isDone
            if let title = record.titleOverride { occurrence.title = title }
            if let minutes = record.timeOverride { occurrence.timeMinutes = minutes }
            occurrence.sortIndex = RecurrenceMaterializer.nextSortIndex(forDay: record.dayKey, cache: &sortCache,
                                                                        context: context)
            context.insert(occurrence)
            bySlot[record.dayKey] = [occurrence]
            report.restoredOverrides += 1
        }
    }
}
