import Foundation
import SwiftData

// MARK: - Top-level DTO

/// Backup of all Kanban data: people, projects (boards), columns, resources
/// (memberships), labels, tasks, subtasks, and activities. Every field is optional
/// with stable JSON keys so future releases decode older files unchanged.
struct KanbanBackupDTO: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var people: [KanbanPersonDTO] = []
    var projects: [KanbanProjectDTO] = []
    var columns: [KanbanColumnDTO] = []
    var resources: [KanbanResourceDTO] = []
    var labels: [KanbanLabelDTO] = []
    var tasks: [KanbanTaskDTO] = []
    var subtasks: [KanbanSubtaskDTO] = []
    var activities: [KanbanActivityDTO] = []

    /// Snapshot the entire Kanban graph, including archived items.
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

        return KanbanBackupDTO(
            version: currentVersion,
            people: people.map(KanbanPersonDTO.init),
            projects: projects.map(KanbanProjectDTO.init),
            columns: columns.map(KanbanColumnDTO.init),
            resources: resources.map(KanbanResourceDTO.init),
            labels: labels.map(KanbanLabelDTO.init),
            tasks: tasks.map(KanbanTaskDTO.init),
            subtasks: subtasks.map(KanbanSubtaskDTO.init),
            activities: activities.map(KanbanActivityDTO.init)
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
            activities: activities.sorted { $0.id.uuidString < $1.id.uuidString }
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

    init(_ model: KanbanPerson) {
        self.id = model.id
        self.name = model.name
        self.initials = model.initials
        self.colorHex = model.colorHex
        self.employmentRaw = model.employmentRaw
        self.skills = model.skills
        self.createdAt = model.createdAt
        self.archivedAt = model.archivedAt
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
    var wipLimit: Int?
    var kindRaw: String
    var projectId: UUID?

    init(_ model: KanbanColumn) {
        self.id = model.id
        self.name = model.name
        self.sortIndex = model.sortIndex
        self.colorHex = model.colorHex
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
        self.labelIds = model.labels.map(\.id)
        self.dependsOnIds = model.dependsOn.map(\.id)
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
