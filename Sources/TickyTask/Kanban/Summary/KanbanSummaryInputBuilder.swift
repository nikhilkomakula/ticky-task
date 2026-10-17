import Foundation

/// An immutable, `Sendable` snapshot of one Kanban card for summary generation.
struct KanbanTaskSnapshot: Sendable, Equatable, Identifiable {
    struct Subtask: Sendable, Equatable {
        var title: String
        var isDone: Bool
    }

    var id: UUID
    var title: String
    var isDone: Bool
    var subtasks: [Subtask]
    var notes: SummaryNotes
    var column: String
    /// The person's label on this board, distinct from everyone else's ("Alex (2)").
    var resource: String
    var labels: [String]
    var priority: String
    var isCritical: Bool
    var isBlocked: Bool
    var blockedReason: String?
    var jiraKey: String?

    var hasNotes: Bool { notes.hasContent }
}

extension KanbanTaskSnapshot {
    /// `resource`: the person's distinct label on the board (see `KanbanUI.uniqueNames`).
    @MainActor
    init(_ task: KanbanTask, resource: String? = nil) {
        self.init(
            id: task.id,
            title: task.title,
            isDone: task.completedAt != nil,
            subtasks: task.subtasks
                .sorted { $0.sortIndex < $1.sortIndex }
                .map { Subtask(title: $0.title, isDone: $0.isDone) },
            notes: SummaryNotes.resolve(notesRich: task.notesRich, notes: task.notes),
            column: task.column?.name ?? "Unknown",
            resource: task.resource.map { resource ?? $0.displayName } ?? "Unassigned",
            labels: task.labels
                .sorted { $0.name < $1.name }
                .map(\.name),
            priority: ["Low", "Medium", "High"][task.priority],
            isCritical: task.isCritical,
            isBlocked: task.isBlocked,
            blockedReason: task.blockedReason,
            jiraKey: task.jiraKey
        )
    }
}

extension KanbanTaskSnapshot {
    /// The board's live cards. People who share a name stay apart in the sheet's groups and
    /// the payload ("Alex", "Alex (2)").
    @MainActor
    static func cards(of project: KanbanProject) -> [KanbanTaskSnapshot] {
        let labels = KanbanUI.uniqueNames(project.resources.sorted { $0.sortIndex < $1.sortIndex }.map { ($0.id, $0.displayName) })
        return project.tasks
            .filter { $0.archivedAt == nil }
            .map { KanbanTaskSnapshot($0, resource: $0.resource.flatMap { labels[$0.id] }) }
    }
}

/// Builds the JSON payload sent to the CLI for Kanban cards. Pure, so its contract —
/// no ids or dates — is unit-tested. Reuses the 256 KB payload limit from Weekly Summary.
enum KanbanSummaryInputBuilder {
    static let payloadLimit = 256 * 1024

    static func payload(for snapshots: [KanbanTaskSnapshot]) throws -> Data {
        let ordered = snapshots.sorted { lhs, rhs in
            if lhs.resource != rhs.resource { return lhs.resource < rhs.resource }
            if lhs.column != rhs.column { return lhs.column < rhs.column }
            return lhs.title < rhs.title
        }

        let records = ordered.enumerated().map { (offset, snapshot) -> PayloadRecord in
            PayloadRecord(snapshot, ordinal: offset + 1)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Payload(cards: records))
        guard data.count <= payloadLimit else {
            throw WeeklySummaryError.inputTooLarge(bytes: data.count, limit: payloadLimit)
        }
        return data
    }
}

// MARK: - Payload shape

private struct Payload: Encodable {
    struct Semantics: Encodable {
        let snapshot = "current_selected_cards"
        let ordering = "grouped_by_resource_and_column"
        let historicalStateAvailable = false
        let activityWindowVerified = false
    }

    let schemaVersion = 1
    let sourceSemantics = Semantics()
    let cards: [PayloadRecord]
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
    let column: String
    let resource: String
    let labels: String
    let priority: String
    let critical: Bool
    let blocked: Bool
    let blockedReason: String?
    let jiraKey: String?

    init(_ snapshot: KanbanTaskSnapshot, ordinal: Int) {
        sourceId = "k\(ordinal)"
        sourceOrdinal = ordinal
        title = snapshot.title
        currentStatus = snapshot.isDone ? "done" : "open"
        subtasks = snapshot.subtasks.map { Subtask(title: $0.title, currentStatus: $0.isDone ? "done" : "open") }
        notes = PayloadNotes(snapshot.notes)
        column = snapshot.column
        resource = snapshot.resource
        labels = snapshot.labels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
        priority = snapshot.priority
        critical = snapshot.isCritical
        blocked = snapshot.isBlocked
        blockedReason = snapshot.blockedReason?.isEmpty == false ? snapshot.blockedReason : nil
        jiraKey = snapshot.jiraKey
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
