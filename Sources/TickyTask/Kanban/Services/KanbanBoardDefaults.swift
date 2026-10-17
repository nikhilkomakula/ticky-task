import Foundation

/// Settings › Kanban's defaults for new boards. Existing boards keep their own settings.
struct KanbanBoardDefaults: Equatable, Sendable {
    var weightedLoad = false
    var wipPolicy = KanbanWIPPolicy.warn
    var loadMeasure = KanbanLoadMeasure.taskCount
    var openTaskTarget: Double = 5
    var dueSoonThresholdDays = 3
    var suggestDone = true

    init() {}

    init(_ d: UserDefaults) {
        weightedLoad = d.bool(forKey: Self.weightedLoadKey, default: false)
        wipPolicy = d.string(forKey: Self.wipPolicyKey).flatMap(KanbanWIPPolicy.init(rawValue:)) ?? .warn
        loadMeasure = d.string(forKey: Self.loadMeasureKey).flatMap(KanbanLoadMeasure.init(rawValue:)) ?? .taskCount
        let target = d.object(forKey: Self.openTaskTargetKey).map { _ in d.double(forKey: Self.openTaskTargetKey) } ?? 5
        openTaskTarget = target.isFinite && target >= 0 ? target : 5
        dueSoonThresholdDays = max(0, d.integer(forKey: Self.dueSoonKey, default: 3))
        suggestDone = d.bool(forKey: Self.suggestDoneKey, default: true)
    }

    static let weightedLoadKey = "kanban.weightedLoadDefault"
    static let wipPolicyKey = "kanban.wipPolicyDefault"
    static let loadMeasureKey = "kanban.loadMeasureDefault"
    static let openTaskTargetKey = "kanban.openTaskTargetDefault"
    static let dueSoonKey = "kanban.dueSoonThresholdDefault"
    static let suggestDoneKey = "kanban.suggestDoneDefault"
    static let autoArchiveEnabledKey = "kanban.autoArchiveEnabled"
    static let autoArchiveDaysKey = "kanban.autoArchiveDays"

    @MainActor
    func apply(to project: KanbanProject) {
        project.weightedLoad = weightedLoad
        project.wipPolicyRaw = wipPolicy.rawValue
        project.loadMeasureRaw = loadMeasure.rawValue
        project.openTaskTarget = openTaskTarget
        project.dueSoonThresholdDays = dueSoonThresholdDays
        project.suggestDoneWhenSubtasksComplete = suggestDone
    }
}
