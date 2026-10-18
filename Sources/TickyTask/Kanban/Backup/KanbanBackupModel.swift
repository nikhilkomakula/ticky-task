import Foundation
import SwiftData

// MARK: - Top-level DTO

/// Backup of all Kanban data: people, projects (boards), columns, resources
/// (memberships), labels, tasks, subtasks, activities, and availability data
/// (time off, overrides, and holidays). Every field is optional with stable JSON keys so
/// future releases decode older files unchanged.
struct KanbanBackupDTO: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version: Int = currentVersion
    var people: [KanbanPersonDTO] = []
    var projects: [KanbanProjectDTO] = []
    var columns: [KanbanColumnDTO] = []
    var resources: [KanbanResourceDTO] = []
    var labels: [KanbanLabelDTO] = []
    var tasks: [KanbanTaskDTO] = []
    var subtasks: [KanbanSubtaskDTO] = []
    var activities: [KanbanActivityDTO] = []
    /// Time off (v2+, optional for v1 compatibility).
    var timeOff: [KanbanTimeOffDTO]?
    /// Availability overrides (v2+, optional for v1 compatibility).
    var availabilityOverrides: [KanbanAvailabilityOverrideDTO]?
    /// Public holidays (v3+, optional for v1/v2 compatibility).
    var holidays: [KanbanHolidayDTO]?

    /// Snapshot the entire Kanban graph, including archived items and availability data.
    @MainActor
    static func snapshot(context: ModelContext) throws -> KanbanBackupDTO {
        let people = try context.fetch(FetchDescriptor<KanbanPerson>())
        let projects = try context.fetch(FetchDescriptor<KanbanProject>())
        let columns = try context.fetch(FetchDescriptor<KanbanColumn>())
        let resources = try context.fetch(FetchDescriptor<KanbanResource>())
        let labels = try context.fetch(FetchDescriptor<KanbanLabel>())
        let tasks = try context.fetch(FetchDescriptor<KanbanTask>())
        let subtasks = try context.fetch(FetchDescriptor<KanbanSubtask>())
        let activities = try context.fetch(FetchDescriptor<KanbanActivity>())
        let timeOff = try context.fetch(FetchDescriptor<KanbanTimeOff>())
        let overrides = try context.fetch(FetchDescriptor<KanbanAvailabilityOverride>())
        let holidays = try context.fetch(FetchDescriptor<KanbanHoliday>())

        return KanbanBackupDTO(
            version: currentVersion,
            people: people.map(KanbanPersonDTO.init),
            projects: projects.map(KanbanProjectDTO.init),
            columns: columns.map(KanbanColumnDTO.init),
            resources: resources.map(KanbanResourceDTO.init),
            labels: labels.map(KanbanLabelDTO.init),
            tasks: tasks.map(KanbanTaskDTO.init),
            subtasks: subtasks.map(KanbanSubtaskDTO.init),
            activities: activities.map(KanbanActivityDTO.init),
            timeOff: timeOff.isEmpty ? nil : timeOff.map(KanbanTimeOffDTO.init),
            availabilityOverrides: overrides.isEmpty ? nil : overrides.map(KanbanAvailabilityOverrideDTO.init),
            holidays: holidays.isEmpty ? nil : holidays.map(KanbanHolidayDTO.init)
        ).deterministicallySorted()
    }

    /// UUID-sorted ordering for diff-friendly, deterministic exports.
    func deterministicallySorted() -> KanbanBackupDTO {
        KanbanBackupDTO(
            version: version,
            people: people.sorted { $0.id.uuidString < $1.id.uuidString },
            projects: projects.sorted { $0.id.uuidString < $1.id.uuidString },
            columns: columns.sorted { $0.id.uuidString < $1.id.uuidString },
            resources: resources.sorted { $0.id.uuidString < $1.id.uuidString },
            labels: labels.sorted { $0.id.uuidString < $1.id.uuidString },
            tasks: tasks.sorted { $0.id.uuidString < $1.id.uuidString },
            subtasks: subtasks.sorted { $0.id.uuidString < $1.id.uuidString },
            activities: activities.sorted { $0.id.uuidString < $1.id.uuidString },
            timeOff: timeOff?.sorted { $0.id.uuidString < $1.id.uuidString },
            availabilityOverrides: availabilityOverrides?.sorted { $0.id.uuidString < $1.id.uuidString },
            holidays: holidays?.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }
}

// MARK: - Entity DTOs

struct KanbanPersonDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var initials: String
    var colorHex: String?
    var employmentRaw: String
    var skills: [String]
    var createdAt: Date
    var archivedAt: Date?
    /// Alternative names the assistant learned for this person (v2+, optional).
    var aliases: [String]?

    init(_ model: KanbanPerson) {
        self.id = model.id
        self.name = model.name
        self.initials = model.initials
        self.colorHex = model.colorHex
        self.employmentRaw = model.employmentRaw
        self.skills = model.skills
        self.createdAt = model.createdAt
        self.archivedAt = model.archivedAt
        self.aliases = model.aliases
    }
}

struct KanbanProjectDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var key: String
    var details: String
    var colorHex: String
    var symbolName: String
    var sortIndex: Double
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    /// Board start day (v2+, yyyyMMdd, optional).
    var startDay: String?
    /// Board end day (v2+, yyyyMMdd, optional).
    var endDay: String?
    var workWeekDays: [Int]
    var hoursPerDay: Double
    var defaultCapacityHoursPerWeek: Double
    var wipPolicyRaw: String
    var loadMeasureRaw: String
    var openTaskTarget: Double
    var defaultEstimateHours: Double
    var weightedLoad: Bool
    var dueSoonThresholdDays: Int
    var suggestDoneWhenSubtasksComplete: Bool
    var collapsedRowKeys: [String]
    var boardState: Data?
    var nextActivitySeq: Int

    init(_ model: KanbanProject) {
        self.id = model.id
        self.name = model.name
        self.key = model.key
        self.details = model.details
        self.colorHex = model.colorHex
        self.symbolName = model.symbolName
        self.sortIndex = model.sortIndex
        self.isPinned = model.isPinned
        self.createdAt = model.createdAt
        self.updatedAt = model.updatedAt
        self.archivedAt = model.archivedAt
        self.startDay = model.startDay
        self.endDay = model.endDay
        self.workWeekDays = model.workWeekDays
        self.hoursPerDay = model.hoursPerDay
        self.defaultCapacityHoursPerWeek = model.defaultCapacityHoursPerWeek
        self.wipPolicyRaw = model.wipPolicyRaw
        self.loadMeasureRaw = model.loadMeasureRaw
        self.openTaskTarget = model.openTaskTarget
        self.defaultEstimateHours = model.defaultEstimateHours
        self.weightedLoad = model.weightedLoad
        self.dueSoonThresholdDays = model.dueSoonThresholdDays
        self.suggestDoneWhenSubtasksComplete = model.suggestDoneWhenSubtasksComplete
        self.collapsedRowKeys = model.collapsedRowKeys
        self.boardState = model.boardState
        self.nextActivitySeq = model.nextActivitySeq
    }
}

struct KanbanColumnDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var sortIndex: Double
    var colorHex: String?
    /// Added after 0.2.0's first builds; older files simply don't have it.
    var symbolName: String?
    var wipLimit: Int?
    var kindRaw: String
    var projectId: UUID?

    init(_ model: KanbanColumn) {
        self.id = model.id
        self.name = model.name
        self.sortIndex = model.sortIndex
        self.colorHex = model.colorHex
        self.symbolName = model.symbolName
        self.wipLimit = model.wipLimit
        self.kindRaw = model.kindRaw
        self.projectId = model.project?.id
    }
}

struct KanbanResourceDTO: Codable, Equatable, Sendable {
    var id: UUID
    var projectId: UUID?
    var personId: UUID?
    var role: String?
    var assignmentRaw: String
    var allocationPercent: Int
    var capacityHoursPerWeekOverride: Double?
    var openTaskTargetOverride: Double?
    var startDate: Date?
    var endDate: Date?
    var sortIndex: Double
    var archivedAt: Date?

    init(_ model: KanbanResource) {
        self.id = model.id
        self.projectId = model.project?.id
        self.personId = model.person?.id
        self.role = model.role
        self.assignmentRaw = model.assignmentRaw
        self.allocationPercent = model.allocationPercent
        self.capacityHoursPerWeekOverride = model.capacityHoursPerWeekOverride
        self.openTaskTargetOverride = model.openTaskTargetOverride
        self.startDate = model.startDate
        self.endDate = model.endDate
        self.sortIndex = model.sortIndex
        self.archivedAt = model.archivedAt
    }
}

struct KanbanLabelDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String
    var symbolName: String?
    var sortIndex: Double
    var projectId: UUID?

    init(_ model: KanbanLabel) {
        self.id = model.id
        self.name = model.name
        self.colorHex = model.colorHex
        self.symbolName = model.symbolName
        self.sortIndex = model.sortIndex
        self.projectId = model.project?.id
    }
}

struct KanbanTaskDTO: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var notes: String
    var notesRich: Data?
    var priority: Int
    var isCritical: Bool
    var sortIndex: Double
    var dueDate: Date?
    var startDate: Date?
    var estimateHours: Double?
    /// Added in v0.2.0; optional, so older backups read as "not set".
    var complexity: Int?
    var jiraURL: String?
    var isBlocked: Bool
    var blockedReason: String?
    var linkedPlannerTaskID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var archivedAt: Date?
    var projectId: UUID?
    var columnId: UUID?
    var resourceId: UUID?
    var labelIds: [UUID]
    var dependsOnIds: [UUID]

    init(_ model: KanbanTask) {
        self.id = model.id
        self.title = model.title
        self.notes = model.notes
        self.notesRich = model.notesRich
        self.priority = model.priority
        self.isCritical = model.isCritical
        self.sortIndex = model.sortIndex
        self.dueDate = model.dueDate
        self.startDate = model.startDate
        self.estimateHours = model.estimateHours
        self.complexity = model.complexity
        self.jiraURL = model.jiraURL
        self.isBlocked = model.isBlocked
        self.blockedReason = model.blockedReason
        self.linkedPlannerTaskID = model.linkedPlannerTaskID
        self.createdAt = model.createdAt
        self.updatedAt = model.updatedAt
        self.completedAt = model.completedAt
        self.archivedAt = model.archivedAt
        self.projectId = model.project?.id
        self.columnId = model.column?.id
        self.resourceId = model.resource?.id
        // To-many relationships have no stored order; sort so exports are deterministic.
        self.labelIds = model.labels.map(\.id).sorted { $0.uuidString < $1.uuidString }
        self.dependsOnIds = model.dependsOn.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }
}

struct KanbanSubtaskDTO: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var isDone: Bool
    var sortIndex: Double
    var completedAt: Date?
    var taskId: UUID?
    var assigneeId: UUID?

    init(_ model: KanbanSubtask) {
        self.id = model.id
        self.title = model.title
        self.isDone = model.isDone
        self.sortIndex = model.sortIndex
        self.completedAt = model.completedAt
        self.taskId = model.task?.id
        self.assigneeId = model.assignee?.id
    }
}

struct KanbanActivityDTO: Codable, Equatable, Sendable {
    var id: UUID
    var seq: Int
    var at: Date
    var kindRaw: String
    var taskIDs: [UUID]
    var summary: String
    var payload: Data
    var revertsActivityID: UUID?
    var revertedByActivityID: UUID?
    var projectId: UUID?

    init(_ model: KanbanActivity) {
        self.id = model.id
        self.seq = model.seq
        self.at = model.at
        self.kindRaw = model.kindRaw
        self.taskIDs = model.taskIDs
        self.summary = model.summary
        self.payload = model.payload
        self.revertsActivityID = model.revertsActivityID
        self.revertedByActivityID = model.revertedByActivityID
        self.projectId = model.project?.id
    }
}

// MARK: - Availability (Kanban payload v2; every key optional for v1 files)

struct KanbanTimeOffDTO: Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var personId: UUID?
    var startDay: String
    var endDay: String
    var portionRaw: String
    var kindRaw: String
    var note: String?
    var originRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(_ model: KanbanTimeOff) {
        id = model.id
        personId = model.person?.id
        startDay = model.startDay
        endDay = model.endDay
        portionRaw = model.portionRaw
        kindRaw = model.kindRaw
        note = model.note
        originRaw = model.originRaw
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    init(id: UUID = UUID(), personId: UUID?, startDay: String, endDay: String, portion: KanbanTimeOffPortion = .full,
         kind: KanbanTimeOffKind = .pto, note: String? = nil, origin: KanbanTimeOffOrigin = .manual,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.personId = personId
        self.startDay = startDay
        self.endDay = endDay
        self.portionRaw = portion.rawValue
        self.kindRaw = kind.rawValue
        self.note = note
        self.originRaw = origin.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// What the entry says, without its id or timestamps: two entries alike here are the same time off.
    var meaning: [String] { [personId?.uuidString ?? "", startDay, endDay, portionRaw, kindRaw] }
}

/// A public holiday (design 04). `workedBy` holds person ids, sorted and unique.
struct KanbanHolidayDTO: Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var day: String
    var name: String
    var portionRaw: String
    var workedBy: [UUID]?
    var createdAt: Date
    var updatedAt: Date

    init(_ model: KanbanHoliday) {
        id = model.id
        day = model.day
        name = model.name
        portionRaw = model.portionRaw
        workedBy = model.workedBy
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    init(id: UUID = UUID(), day: String, name: String, portion: KanbanTimeOffPortion = .full, workedBy: [UUID]? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.day = day
        self.name = name
        self.portionRaw = portion.rawValue
        self.workedBy = KanbanHoliday.normalized(workedBy)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Two holidays alike here are the same holiday.
    var meaning: [String] { [day, portionRaw, name.trimmingCharacters(in: .whitespaces).lowercased()] }
}

struct KanbanAvailabilityOverrideDTO: Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var resourceId: UUID?
    var weekStart: String
    var halfDays: Int
    var note: String?
    var createdAt: Date
    var updatedAt: Date

    init(_ model: KanbanAvailabilityOverride) {
        id = model.id
        resourceId = model.resource?.id
        weekStart = model.weekStart
        halfDays = model.halfDays
        note = model.note
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    init(id: UUID = UUID(), resourceId: UUID?, weekStart: String, halfDays: Int, note: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.resourceId = resourceId
        self.weekStart = weekStart
        self.halfDays = halfDays
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
