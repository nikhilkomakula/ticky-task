import SwiftUI

/// Task priority. Backed by `TaskItem.priority` (Int). A task's color is derived
/// from its priority (no separate color palette), and a flag symbol is used only
/// for `.critical`.
enum TaskPriority: Int, CaseIterable, Identifiable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .critical: "Critical"
        }
    }

    /// SF Symbol per level. A flag is used **only** for `.critical`.
    var symbol: String {
        switch self {
        case .low: "arrow.down.circle.fill"
        case .medium: "minus.circle.fill"
        case .high: "arrow.up.circle.fill"
        case .critical: "flag.fill"
        }
    }

    /// Default escalating color scheme: green → yellow → orange → red.
    var tint: Color {
        switch self {
        case .low: .green
        case .medium: .yellow
        case .high: .orange
        case .critical: .red
        }
    }

    var isCritical: Bool { self == .critical }
}

extension TaskItem {
    /// Typed accessor over the stored integer `priority` (defaults to `.low`).
    var priorityLevel: TaskPriority {
        get { TaskPriority(rawValue: priority) ?? .low }
        set { priority = newValue.rawValue }
    }
}
