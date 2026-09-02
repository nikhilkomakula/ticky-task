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
    /// User-facing preferences (UserDefaults) captured at export and applied on
    /// restore. Optional so older backups without it still decode.
    var settings: AppSettingsDTO? = nil
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
    /// Persists `TaskItem.isCritical`. Kept under its original JSON key
    /// `needsImmediateAttention` for backup-format stability across 0.1.2↔0.1.3,
    /// and optional so pre-0.1.2 backups (which omit it) still decode → `false`.
    var needsImmediateAttention: Bool? = nil
    /// When the task was completed (`nil` if open). Optional so older backups
    /// without the key still decode.
    var completedAt: Date? = nil
    /// Encoded rich notes (`NotesDocument` JSON as Data). Optional so older backups
    /// that omit the key decode to nil; the plain-text `notes` key is unchanged.
    var notesRich: Data? = nil
    /// Links a materialized occurrence back to its recurring template's id (`nil`
    /// for one-off tasks and templates). Optional new key so older backups decode.
    var templateId: UUID? = nil
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

/// The app's user-facing preferences (UserDefaults), included in a backup so a
/// restore reproduces the full setup — not just the task data. Machine-specific
/// keys (the chosen data-folder path) are deliberately excluded. Every field is
/// optional: a preference still at its default (absent from `UserDefaults`) is
/// omitted, and older backups without a `settings` block decode to `nil`.
struct AppSettingsDTO: Codable, Equatable, Sendable {
    var appTheme: String? = nil
    var calendarColumns: Int? = nil
    var weekStartsMonday: Bool? = nil
    var compactView: Bool? = nil
    var taskSortMode: String? = nil
    var moveCompletedToBottom: Bool? = nil
    var autoCarryForward: Bool? = nil
    var autoDeleteCompletedEnabled: Bool? = nil
    var autoDeleteCompletedDays: Int? = nil
    var endOfDayReminderEnabled: Bool? = nil
    var endOfDayReminderMinutes: Int? = nil
    var menuBarOnly: Bool? = nil
    var autoCheckUpdates: Bool? = nil

    /// Snapshot the current preferences. Uses `object(forKey:)` so an unset key
    /// stays `nil` rather than reading back as `false` / `0`.
    static func capture(from d: UserDefaults = .standard) -> AppSettingsDTO {
        AppSettingsDTO(
            appTheme: d.string(forKey: "appTheme"),
            calendarColumns: d.object(forKey: "calendarColumns") as? Int,
            weekStartsMonday: d.object(forKey: "weekStartsMonday") as? Bool,
            compactView: d.object(forKey: "compactView") as? Bool,
            taskSortMode: d.string(forKey: "taskSortMode"),
            moveCompletedToBottom: d.object(forKey: "moveCompletedToBottom") as? Bool,
            autoCarryForward: d.object(forKey: "autoCarryForward") as? Bool,
            autoDeleteCompletedEnabled: d.object(forKey: "autoDeleteCompletedEnabled") as? Bool,
            autoDeleteCompletedDays: d.object(forKey: "autoDeleteCompletedDays") as? Int,
            endOfDayReminderEnabled: d.object(forKey: "endOfDayReminderEnabled") as? Bool,
            endOfDayReminderMinutes: d.object(forKey: "endOfDayReminderMinutes") as? Int,
            menuBarOnly: d.object(forKey: "menuBarOnly") as? Bool,
            autoCheckUpdates: d.object(forKey: "autoCheckUpdates") as? Bool
        )
    }

    /// Every UserDefaults key this DTO carries — used to reset before a restore so
    /// the destination reproduces the source's *effective* settings (a key the
    /// source left at its default clears any explicit value here, back to default).
    static let portableKeys = [
        "appTheme", "calendarColumns", "weekStartsMonday", "compactView",
        "taskSortMode", "moveCompletedToBottom", "autoCarryForward",
        "autoDeleteCompletedEnabled", "autoDeleteCompletedDays",
        "endOfDayReminderEnabled", "endOfDayReminderMinutes",
        "menuBarOnly", "autoCheckUpdates",
    ]

    /// Reproduce the backed-up settings: clear every portable key first (so a
    /// preference the source left at its default resets any explicit value here to
    /// the same default), then write the values the backup carries.
    func apply(to d: UserDefaults = .standard) {
        for key in Self.portableKeys { d.removeObject(forKey: key) }
        if let v = appTheme { d.set(v, forKey: "appTheme") }
        if let v = calendarColumns { d.set(v, forKey: "calendarColumns") }
        if let v = weekStartsMonday { d.set(v, forKey: "weekStartsMonday") }
        if let v = compactView { d.set(v, forKey: "compactView") }
        if let v = taskSortMode { d.set(v, forKey: "taskSortMode") }
        if let v = moveCompletedToBottom { d.set(v, forKey: "moveCompletedToBottom") }
        if let v = autoCarryForward { d.set(v, forKey: "autoCarryForward") }
        if let v = autoDeleteCompletedEnabled { d.set(v, forKey: "autoDeleteCompletedEnabled") }
        if let v = autoDeleteCompletedDays { d.set(v, forKey: "autoDeleteCompletedDays") }
        if let v = endOfDayReminderEnabled { d.set(v, forKey: "endOfDayReminderEnabled") }
        if let v = endOfDayReminderMinutes { d.set(v, forKey: "endOfDayReminderMinutes") }
        if let v = menuBarOnly { d.set(v, forKey: "menuBarOnly") }
        if let v = autoCheckUpdates { d.set(v, forKey: "autoCheckUpdates") }
    }
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
            needsImmediateAttention: task.isCritical,
            completedAt: task.completedAt,
            notesRich: task.notesRich,
            templateId: task.templateID
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
