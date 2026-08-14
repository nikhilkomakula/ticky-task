import Foundation

/// Codable snapshot of the whole store, plus the on-disk file envelope.
///
/// Relationships are projected to stable UUIDs (`customListId`, `parentId`,
/// `templateId`, `tagIds`) rather than encoded recursively, so the graph is
/// rebuilt deterministically on import. `RecurrenceRule` is already a `Codable`
/// value type, so it is embedded directly (its persisted shape *is* the backup
/// shape — no lossy re-projection).
///
/// The file itself is a `BackupFile` envelope: a **plaintext** backup embeds the
/// store as nested, human-readable JSON; an **encrypted** backup replaces it
/// with an AES-GCM payload. One envelope shape covers both so import can detect
/// the mode from a single `encrypted` flag.

// MARK: - Errors

enum BackupError: Error, Equatable {
    case unsupportedFormat(found: Int, supported: Int)
    case unsupportedSchema(found: Int, supported: Int)
    case missingPassphrase
    case wrongPassphrase
    case corruptPayload
    case fileTooLarge(maxMB: Int)
    case validationFailed(reason: String)
    case invalidReference(entity: String, id: UUID)
}

// MARK: - Envelope

/// The root object written to disk. Format-versioned independently of the data
/// schema so the container can evolve without a data migration.
struct BackupFile: Codable, Equatable, Sendable {
    var format: Int = 1
    var encrypted: Bool
    /// Present iff `!encrypted` — the store as readable nested JSON.
    var store: BackupStoreDTO?
    /// Present iff `encrypted` — PBKDF2 + AES-GCM sealed store.
    var crypto: EncryptedPayload?
}

/// AES-256-GCM payload with the PBKDF2 parameters needed to re-derive the key
/// from the user's passphrase on another machine. `Data` fields serialize as
/// base64 under synthesized `Codable`.
struct EncryptedPayload: Codable, Equatable, Sendable {
    var salt: Data
    var nonce: Data
    var ciphertext: Data
    var tag: Data
    var iterations: Int
}

// MARK: - Store snapshot

struct BackupStoreDTO: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var appVersion: String
    var exportedAt: Date
    var data: BackupDataDTO
}

struct BackupDataDTO: Codable, Equatable, Sendable {
    var taskItems: [TaskItemDTO]
    var subtasks: [SubtaskDTO]
    var taskTags: [TaskTagDTO]
    var customLists: [CustomListDTO]
    var taskOccurrences: [TaskOccurrenceDTO]

    /// UUID-sorted ordering for diff-friendly, deterministic exports.
    func deterministicallySorted() -> BackupDataDTO {
        BackupDataDTO(
            taskItems:       taskItems.sorted       { $0.id.uuidString < $1.id.uuidString },
            subtasks:        subtasks.sorted        { $0.id.uuidString < $1.id.uuidString },
            taskTags:        taskTags.sorted        { $0.id.uuidString < $1.id.uuidString },
            customLists:     customLists.sorted     { $0.id.uuidString < $1.id.uuidString },
            taskOccurrences: taskOccurrences.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }
}

// MARK: - Entity DTOs

struct TaskItemDTO: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var notes: String
    var isDone: Bool
    var dayKey: String?
    var customListId: UUID?
    var timeMinutes: Int?
    var colorHex: String?
    var priority: Int
    var sortIndex: Double
    var alarmEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var recurrence: RecurrenceRule?
    var tagIds: [UUID]
    /// Optional for backward compatibility: pre-0.1.2 backups omit this key and
    /// decode as `nil` (treated as `false` on restore). Defaulted so the projection
    /// and older call sites need not pass it.
    var needsImmediateAttention: Bool? = nil
}

struct SubtaskDTO: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var isDone: Bool
    var sortIndex: Double
    var parentId: UUID?
}

struct TaskTagDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String?
}

struct CustomListDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var sortIndex: Double
}

struct TaskOccurrenceDTO: Codable, Equatable, Sendable {
    var id: UUID
    var dayKey: String
    var isDone: Bool
    var skipped: Bool
    var titleOverride: String?
    var timeOverride: Int?
    var templateId: UUID?
}

// MARK: - Projections from live models

extension TaskItemDTO {
    init(_ task: TaskItem) {
        self.init(
            id: task.id, title: task.title, notes: task.notes, isDone: task.isDone,
            dayKey: task.dayKey, customListId: task.customList?.id,
            timeMinutes: task.timeMinutes, colorHex: task.colorHex,
            priority: task.priority, sortIndex: task.sortIndex, alarmEnabled: task.alarmEnabled,
            createdAt: task.createdAt, updatedAt: task.updatedAt,
            recurrence: task.recurrence,
            tagIds: task.tags.map(\.id).sorted { $0.uuidString < $1.uuidString },
            needsImmediateAttention: task.needsImmediateAttention
        )
    }
}

extension SubtaskDTO {
    init(_ sub: Subtask) {
        self.init(id: sub.id, title: sub.title, isDone: sub.isDone,
                  sortIndex: sub.sortIndex, parentId: sub.parent?.id)
    }
}

extension TaskTagDTO {
    init(_ tag: TaskTag) { self.init(id: tag.id, name: tag.name, colorHex: tag.colorHex) }
}

extension CustomListDTO {
    init(_ list: CustomList) { self.init(id: list.id, name: list.name, sortIndex: list.sortIndex) }
}

extension TaskOccurrenceDTO {
    init(_ occ: TaskOccurrence) {
        self.init(id: occ.id, dayKey: occ.dayKey, isDone: occ.isDone, skipped: occ.skipped,
                  titleOverride: occ.titleOverride, timeOverride: occ.timeOverride,
                  templateId: occ.template?.id)
    }
}

// MARK: - Coders

enum BackupCoding {
    private static func isoFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f
    }

    /// Encodes **with fractional seconds** so `createdAt`/`updatedAt`/
    /// `exportedAt`, recurrence `startDate`, and `.until(Date)` round-trip
    /// losslessly (the stock `.iso8601` strategy truncates to whole seconds).
    static func encoder() -> JSONEncoder {
        let iso = isoFormatter(fractionalSeconds: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Accepts ISO-8601 **with or without** fractional seconds, so both this
    /// app's fractional exports and any whole-second date (hand-edited files or
    /// other tools) decode.
    static func decoder() -> JSONDecoder {
        let withFraction = isoFormatter(fractionalSeconds: true)
        let wholeSeconds = isoFormatter(fractionalSeconds: false)
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) { return date }
            if let date = wholeSeconds.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid ISO-8601 date: \(text)"
            ))
        }
        return d
    }
}
