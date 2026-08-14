import SwiftUI

/// Task priority. Backed by `TaskItem.priority` (Int), matching the legacy
/// app's integer priority so imports round-trip.
enum TaskPriority: Int, CaseIterable, Identifiable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var isFlagged: Bool { self != .none }

    var tint: Color {
        switch self {
        case .none: .secondary
        case .low: .blue
        case .medium: .orange
        case .high: .red
        }
    }
}

extension TaskItem {
    /// Typed accessor over the stored integer `priority`.
    var priorityLevel: TaskPriority {
        get { TaskPriority(rawValue: priority) ?? .none }
        set { priority = newValue.rawValue }
    }
}
