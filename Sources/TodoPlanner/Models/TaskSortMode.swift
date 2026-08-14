import Foundation

/// How tasks are ordered within a day or list. Persisted in `@AppStorage`
/// ("taskSortMode") and applied by `BehaviorService.sorted`.
enum TaskSortMode: String, CaseIterable, Identifiable, Sendable {
    case manual
    case time
    case priority

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: "Manual order"
        case .time: "By time"
        case .priority: "By priority"
        }
    }
}
