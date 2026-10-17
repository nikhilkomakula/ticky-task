import Foundation
import SwiftData

/// A Kanban board: status columns × resource rows (plus an Unassigned row, which is
/// `task.resource == nil`, not a resource). Every property is defaulted or optional
/// so existing stores lightweight-migrate (see `AppSchema`).
@Model
final class KanbanProject {
    var id: UUID = UUID()
    var name: String = ""
    /// Short code shown in breadcrumbs and Jira-style references, e.g. "PLAT".
    var key: String = ""
    var details: String = ""
    var colorHex: String = "#3B82F6"
    var symbolName: String = "square.grid.3x2"
    /// Sidebar order (drag-reorderable).
    var sortIndex: Double = 0
    var isPinned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var archivedAt: Date?

    /// `Calendar` weekday numbers (1 = Sunday … 7 = Saturday); Mon–Fri by default.
    var workWeekDays: [Int] = [2, 3, 4, 5, 6]
    var hoursPerDay: Double = 8
    var defaultCapacityHoursPerWeek: Double = 40
    var wipPolicyRaw: String = KanbanWIPPolicy.warn.rawValue
    var loadMeasureRaw: String = KanbanLoadMeasure.taskCount.rawValue
    /// Open-task target for a full-time membership, scaled by allocation.
    var openTaskTarget: Double = 5
    /// Hours counted for an unestimated open task in hours mode.
    var defaultEstimateHours: Double = 4
    var weightedLoad: Bool = false
    var dueSoonThresholdDays: Int = 3
    var suggestDoneWhenSubtasksComplete: Bool = true
    /// Collapsed board rows: resource UUID strings, plus `"unassigned"`. Rows not
    /// listed are expanded, so new resources need no bookkeeping.
    var collapsedRowKeys: [String] = []
    /// Encoded `BoardViewState` (last view, filters, sort, density, show-archived).
    var boardState: Data?
    /// Next `KanbanActivity.seq`; activities replay in this order.
    var nextActivitySeq: Int = 1

    @Relationship(deleteRule: .cascade, inverse: \KanbanColumn.project) var columns: [KanbanColumn] = []
    @Relationship(deleteRule: .cascade, inverse: \KanbanResource.project) var resources: [KanbanResource] = []
    @Relationship(deleteRule: .cascade, inverse: \KanbanLabel.project) var labels: [KanbanLabel] = []
    @Relationship(deleteRule: .cascade, inverse: \KanbanTask.project) var tasks: [KanbanTask] = []
    @Relationship(deleteRule: .cascade, inverse: \KanbanActivity.project) var activities: [KanbanActivity] = []

    init(id: UUID = UUID(), name: String = "", key: String = "", sortIndex: Double = 0) {
        self.id = id
        self.name = name
        self.key = key
        self.sortIndex = sortIndex
    }

    var wipPolicy: KanbanWIPPolicy {
        get { KanbanWIPPolicy(rawValue: wipPolicyRaw) ?? .warn }
        set { wipPolicyRaw = newValue.rawValue }
    }

    var loadMeasure: KanbanLoadMeasure {
        get { KanbanLoadMeasure(rawValue: loadMeasureRaw) ?? .taskCount }
        set { loadMeasureRaw = newValue.rawValue }
    }

    /// Columns in board order.
    var orderedColumns: [KanbanColumn] { columns.sorted { $0.sortIndex < $1.sortIndex } }
}
