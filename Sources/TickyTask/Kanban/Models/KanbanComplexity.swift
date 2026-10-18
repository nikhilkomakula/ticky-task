import Foundation

/// How complex a card is, independent of its priority and estimate. Optional: a card
/// without one shows nothing.
enum KanbanComplexity: Int, CaseIterable, Identifiable, Sendable {
    case low = 1
    case medium = 2
    case high = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// The card marker's text.
    var shortLabel: String {
        switch self {
        case .low: "Low"
        case .medium: "Med"
        case .high: "High"
        }
    }

    /// How many of the marker's three bars are filled.
    var barsFilled: Double { Double(rawValue) / 3 }
}
