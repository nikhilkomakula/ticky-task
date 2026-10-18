import Foundation

/// Settings › Kanban's defaults for new boards. Existing boards keep their own settings.
struct KanbanBoardDefaults: Equatable, Sendable {
    var weightedLoad = false
    var wipPolicy = KanbanWIPPolicy.warn
    var loadMeasure = KanbanLoadMeasure.taskCount
    var openTaskTarget: Double = 5
    var dueSoonThresholdDays = 3
    var suggestDone = true
    var labels: [KanbanTemplate.Label]?

    init() {}

    init(_ d: UserDefaults) {
        weightedLoad = d.bool(forKey: Self.weightedLoadKey, default: false)
        wipPolicy = d.string(forKey: Self.wipPolicyKey).flatMap(KanbanWIPPolicy.init(rawValue:)) ?? .warn
        loadMeasure = d.string(forKey: Self.loadMeasureKey).flatMap(KanbanLoadMeasure.init(rawValue:)) ?? .taskCount
        let target = d.object(forKey: Self.openTaskTargetKey).map { _ in d.double(forKey: Self.openTaskTargetKey) } ?? 5
        openTaskTarget = target.isFinite && target >= 0 ? target : 5
        dueSoonThresholdDays = max(0, d.integer(forKey: Self.dueSoonKey, default: 3))
        suggestDone = d.bool(forKey: Self.suggestDoneKey, default: true)

        // Load default labels from JSON, or use nil to indicate factory defaults
        if let jsonStr = d.string(forKey: Self.defaultLabelsKey) {
            if let data = jsonStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([KanbanTemplate.Label].self, from: data) {
                labels = decoded
            } else {
                // Malformed: use factory labels without overwriting stored value
                labels = nil
            }
        }
    }

    static let weightedLoadKey = "kanban.weightedLoadDefault"
    static let wipPolicyKey = "kanban.wipPolicyDefault"
    static let loadMeasureKey = "kanban.loadMeasureDefault"
    static let openTaskTargetKey = "kanban.openTaskTargetDefault"
    static let dueSoonKey = "kanban.dueSoonThresholdDefault"
    static let suggestDoneKey = "kanban.suggestDoneDefault"
    /// Row headers show each member's allocation (part-time icon and percentage); off unless turned on.
    static let showAllocationKey = "kanban.showAllocation"
    static let autoArchiveEnabledKey = "kanban.autoArchiveEnabled"
    static let autoArchiveDaysKey = "kanban.autoArchiveDays"
    static let defaultLabelsKey = "kanban.defaultLabels"

    /// Returns the labels to use for a new board: explicit defaults, factory labels, or empty.
    /// - nil: use factory labels (KanbanTemplate.defaultLabels)
    /// - empty array: use no labels
    /// - non-empty: use these labels
    func labelsForNewBoard() -> [KanbanTemplate.Label] {
        if let labels { return labels }
        return KanbanTemplate.defaultLabels
    }

    /// Settings › Kanban's default labels only: nil returns to the factory labels, empty means none.
    static func saveLabels(_ labels: [KanbanTemplate.Label]?, to defaults: UserDefaults = .standard) throws {
        guard let labels else { return defaults.removeObject(forKey: defaultLabelsKey) }
        defaults.set(String(decoding: try JSONEncoder().encode(labels), as: UTF8.self), forKey: defaultLabelsKey)
    }

    /// Saves these defaults to UserDefaults.
    @MainActor
    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(weightedLoad, forKey: Self.weightedLoadKey)
        defaults.set(wipPolicy.rawValue, forKey: Self.wipPolicyKey)
        defaults.set(loadMeasure.rawValue, forKey: Self.loadMeasureKey)
        defaults.set(openTaskTarget, forKey: Self.openTaskTargetKey)
        defaults.set(dueSoonThresholdDays, forKey: Self.dueSoonKey)
        defaults.set(suggestDone, forKey: Self.suggestDoneKey)

        if let labels {
            let data = try JSONEncoder().encode(labels)
            let jsonStr = String(data: data, encoding: .utf8)
            defaults.set(jsonStr, forKey: Self.defaultLabelsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultLabelsKey)
        }
    }

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
