import Foundation

/// The notes of one task as the summary sees them. Rich-first: a readable rich
/// document is authoritative (even when empty), so stale plain-text projections
/// are never resurrected; legacy Markdown is passed through verbatim.
enum SummaryNotes: Sendable, Equatable {
    case rich(NotesDocument)
    case legacyMarkdown(String)
    case none

    static func resolve(notesRich: Data?, notes: String) -> SummaryNotes {
        if let notesRich, !notesRich.isEmpty, let document = try? NotesCodec.decode(notesRich) {
            // Rich-first: check if document is empty or whitespace-only
            let trimmed = document.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .none : .rich(document)
        }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .none : .legacyMarkdown(notes)
    }

    var hasContent: Bool {
        if case .none = self { return false }
        return true
    }

    /// Plain text used for the selection list's excerpt.
    var plainText: String {
        switch self {
        case .rich(let document): document.plainText
        case .legacyMarkdown(let text): text
        case .none: ""
        }
    }
}

/// An immutable, `Sendable` copy of one task row, captured on the main actor so
/// generation never touches SwiftData models off-actor.
struct SummaryTaskSnapshot: Sendable, Equatable, Identifiable {
    struct Subtask: Sendable, Equatable {
        var title: String
        var isDone: Bool
    }

    var id: UUID
    /// Shared by every row of one recurring series; `nil` for a one-off task.
    var seriesID: UUID?
    var dayKey: String
    var sortIndex: Double
    var title: String
    var isDone: Bool
    var subtasks: [Subtask]
    var notes: SummaryNotes

    var isRecurring: Bool { seriesID != nil }
    var hasNotes: Bool { notes.hasContent }
}

extension SummaryTaskSnapshot {
    @MainActor
    init(_ task: TaskItem) {
        self.init(
            id: task.id,
            seriesID: SummarySeries.key(for: task),
            dayKey: task.dayKey ?? "",
            sortIndex: task.sortIndex,
            title: task.title,
            isDone: task.isDone,
            subtasks: task.subtasks
                .sorted { $0.sortIndex < $1.sortIndex }
                .map { Subtask(title: $0.title, isDone: $0.isDone) },
            notes: SummaryNotes.resolve(notesRich: task.notesRich, notes: task.notes)
        )
    }
}

/// Recurring-series identity. Rows are only ever grouped by series — never by
/// title, since two unrelated tasks can share a name.
enum SummarySeries {
    @MainActor
    static func key(for task: TaskItem) -> UUID? {
        task.templateID ?? (task.recurrence != nil ? task.id : nil)
    }
}

/// The seven calendar days a summary covers. Deliberately independent of the
/// week view's column settings, which can hide weekends or span more than a week.
enum SummaryWeek {
    static func days(containing anchor: Date, weekStartsMonday: Bool,
                     calendar: Calendar = .current) -> [Date] {
        let start = WeekMath.startOfWeek(containing: anchor, weekStartsMonday: weekStartsMonday, calendar: calendar)
        return WeekMath.weekDates(startingFrom: start, count: 7, calendar: calendar)
    }
}

/// Builds the JSON payload sent to the CLI. Pure, so its contract — no dates,
/// keys, ids, timestamps, or priorities leave the app — is unit-tested.
enum SummaryInputBuilder {
    /// Larger selections are rejected rather than silently truncated.
    static let payloadLimit = 256 * 1024

    static func payload(for snapshots: [SummaryTaskSnapshot]) throws -> Data {
        let ordered = snapshots.sorted { lhs, rhs in
            if lhs.dayKey != rhs.dayKey { return lhs.dayKey < rhs.dayKey }
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        // Groups appear in order of their first record; one-offs are each their own group.
        var groups: [PayloadGroup] = []
        var seriesGroupIndex: [UUID: Int] = [:]
        for (offset, snapshot) in ordered.enumerated() {
            let record = PayloadRecord(snapshot, ordinal: offset + 1)
            if let series = snapshot.seriesID, let index = seriesGroupIndex[series] {
                groups[index].records.append(record)
            } else {
                if let series = snapshot.seriesID { seriesGroupIndex[series] = groups.count }
                groups.append(PayloadGroup(
                    groupId: "g\(groups.count + 1)",
                    relationship: snapshot.seriesID == nil ? "single_record" : "recurring_series",
                    records: [record]
                ))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Payload(taskGroups: groups))
        guard data.count <= payloadLimit else {
            throw WeeklySummaryError.inputTooLarge(bytes: data.count, limit: payloadLimit)
        }
        return data
    }
}

// MARK: - Payload shape (schemaVersion 1)

private struct Payload: Encodable {
    struct Semantics: Encodable {
        let snapshot = "current_selected_records"
        let ordering = "planner_placement_order"
        let historicalStateAvailable = false
        let activityWindowVerified = false
    }

    let schemaVersion = 1
    let sourceSemantics = Semantics()
    let taskGroups: [PayloadGroup]
}

private struct PayloadGroup: Encodable {
    let groupId: String
    let relationship: String
    var records: [PayloadRecord]
}

private struct PayloadRecord: Encodable {
    struct Subtask: Encodable {
        let title: String
        let currentStatus: String
    }

    let sourceId: String
    let sourceOrdinal: Int
    let title: String
    let currentStatus: String
    let subtasks: [Subtask]
    let notes: PayloadNotes

    init(_ snapshot: SummaryTaskSnapshot, ordinal: Int) {
        sourceId = "s\(ordinal)"
        sourceOrdinal = ordinal
        title = snapshot.title
        currentStatus = snapshot.isDone ? "done" : "open"
        subtasks = snapshot.subtasks.map { Subtask(title: $0.title, currentStatus: $0.isDone ? "done" : "open") }
        notes = PayloadNotes(snapshot.notes)
    }
}

private struct PayloadNotes: Encodable {
    let notes: SummaryNotes

    init(_ notes: SummaryNotes) { self.notes = notes }

    private enum CodingKeys: String, CodingKey { case format, blocks, text }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch notes {
        case .rich(let document):
            try container.encode("rich_blocks", forKey: .format)
            try container.encode(document.blocks.map(PayloadBlock.init), forKey: .blocks)
        case .legacyMarkdown(let text):
            try container.encode("legacy_markdown", forKey: .format)
            try container.encode(text, forKey: .text)
        case .none:
            try container.encode("none", forKey: .format)
        }
    }
}

/// A rich-note block with only the style flags that are set, keeping the
/// payload compact without losing structure.
private struct PayloadBlock: Encodable {
    struct Run: Encodable {
        let text: String
        let bold: Bool?
        let italic: Bool?
        let underline: Bool?
        let strikethrough: Bool?
        let link: String?

        init(_ run: NotesRun) {
            text = run.text
            bold = run.bold ? true : nil
            italic = run.italic ? true : nil
            underline = run.underline ? true : nil
            strikethrough = run.strikethrough ? true : nil
            link = run.link?.absoluteString
        }
    }

    let kind: String
    let indent: Int?
    let checked: Bool?
    let runs: [Run]

    init(_ block: NotesBlock) {
        kind = block.kind.rawValue
        indent = block.indent > 0 ? block.indent : nil
        checked = block.kind == .checkbox ? block.checked : nil
        runs = block.runs.filter { !$0.text.isEmpty }.map(Run.init)
    }
}
