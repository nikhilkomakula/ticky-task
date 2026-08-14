import SwiftUI

/// The fixed WeekToDo task-color palette.
///
/// Matches the legacy app's `colorPicker.vue` exactly — 11 presets plus "none"
/// — so imported tasks keep their colors. Stored on `TaskItem.colorHex` as a
/// "#rrggbb" string; `nil` means "none".
enum TaskColor: String, CaseIterable, Identifiable, Sendable {
    case green  = "#77e785"
    case cyan   = "#06b6d4"
    case blue   = "#5e6ef2"
    case violet = "#8b5cf6"
    case pink   = "#ed56a1"
    case red    = "#ed544b"
    case orange = "#f97316"
    case yellow = "#f9d54a"
    case brown  = "#ba7956"
    case gray   = "#6b7280"
    case ink    = "#030712"

    var id: String { rawValue }
    var hex: String { rawValue }
    var color: Color { Color(hex: rawValue) ?? .gray }
}

extension Color {
    /// Parse a `"#rrggbb"` (or `"rrggbb"`) hex string into an sRGB color.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
