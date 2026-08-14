import SwiftUI

/// Task priority: **low / medium / high**. Backed by `TaskItem.priority` (Int);
/// a task's color and glyph are derived from its level. The former `.critical`
/// level is gone — urgency that needs to jump the queue is now the independent,
/// opt-in `TaskItem.needsImmediateAttention` flag (a red warning mark), so a task
/// can be, say, low priority yet still flagged for immediate attention.
enum TaskPriority: Int, CaseIterable, Identifiable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// SF Symbol per level.
    var symbol: String {
        switch self {
        case .low: "arrow.down.circle.fill"
        case .medium: "minus.circle.fill"
        case .high: "arrow.up.circle.fill"
        }
    }

    /// Escalating color scheme: green → yellow → orange.
    var tint: Color {
        switch self {
        case .low: .green
        case .medium: .yellow
        case .high: .orange
        }
    }
}

extension TaskItem {
    /// Typed accessor over the stored integer `priority`, clamped to the valid
    /// range. Pre-0.1.2 data stored `3` for the removed "critical" level; it now
    /// reads back as `.high` (values below `.low` clamp up to `.low`).
    var priorityLevel: TaskPriority {
        get { TaskPriority(rawValue: min(max(priority, 0), 2)) ?? .low }
        set { priority = newValue.rawValue }
    }
}
