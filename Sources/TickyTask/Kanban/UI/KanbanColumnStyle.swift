import SwiftUI
import AppKit

/// How a column (a task status) looks: its accent colour and icon. Each is automatic unless
/// chosen: the colour follows the stage (red, orange, green), the icon the column's name when it
/// names a status ("In Review" → eye), else the stage.
struct KanbanColumnStyle {
    let kind: KanbanColumnKind
    let customColorHex: String?
    var customSymbol: String?
    var name = ""

    init(kind: KanbanColumnKind, customColorHex: String?, customSymbol: String? = nil, name: String = "") {
        self.kind = kind
        self.customColorHex = customColorHex
        self.customSymbol = customSymbol
        self.name = name
    }

    init(_ column: KanbanColumn) {
        self.init(kind: column.kind, customColorHex: column.colorHex, customSymbol: column.symbolName, name: column.name)
    }

    // MARK: Colour

    /// The chosen colour, or the stage's.
    var baseHex: String {
        if let customColorHex, Color(hex: customColorHex) != nil { return customColorHex }
        return Self.stageHex(kind)
    }

    static func stageHex(_ kind: KanbanColumnKind) -> String {
        switch kind {
        case .backlog: TaskColor.red.hex
        case .active: TaskColor.orange.hex
        case .done: TaskColor.green.hex
        }
    }

    /// The accent as drawn: the base colour, darkened in light mode or lightened in dark mode
    /// just enough for the icon and rule to stand out from the header (the stored colour is
    /// never changed).
    var effectiveAccent: Color { KanbanContrast.accent(baseHex) }

    var colorName: String {
        if let customColorHex, let color = TaskColor(rawValue: customColorHex.lowercased()) { return color.name }
        if customColorHex != nil { return "Custom" }
        return TaskColor(rawValue: Self.stageHex(kind))?.name ?? "Stage"
    }

    // MARK: Icon

    /// The chosen icon when this Mac has it, otherwise the automatic one (an imported board may
    /// name a symbol this system lacks; it stays stored).
    var symbol: String {
        if let customSymbol, NSImage(systemSymbolName: customSymbol, accessibilityDescription: nil) != nil { return customSymbol }
        return automaticSymbol
    }

    var automaticSymbol: String { Self.nameSymbol(name) ?? stageSymbol }

    var stageSymbol: String {
        switch kind {
        case .backlog: "circle.dashed"
        case .active: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }

    /// The icon a status name clearly asks for. Blocked and waiting win over the rest ("Waiting
    /// for review" waits); two other different matches mean no clear answer.
    static func nameSymbol(_ name: String) -> String? {
        let lower = name.lowercased()
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        if words.contains("blocked") || lower.contains("on hold") { return "hand.raised" }
        if words.contains("waiting") { return "hourglass" }
        let specific: [(words: Set<String>, symbol: String)] = [
            (["review", "reviewing"], "eye"), (["test", "testing", "qa", "verify"], "checkmark.seal"),
            (["deploy", "deploying", "release", "releasing", "ship", "shipping"], "shippingbox"),
            (["design", "designing"], "paintbrush"), (["docs", "documentation"], "doc.text"), (["ready"], "flag"),
        ]
        let matches = Set(specific.filter { !$0.words.isDisjoint(with: words) }.map(\.symbol))
        return matches.count == 1 ? matches.first : nil
    }

    /// The icons offered in Appearance…, with the names VoiceOver and tooltips use.
    static let iconChoices: [(symbol: String, name: String)] = [
        ("circle.dashed", "Not started"), ("circle.lefthalf.filled", "In progress"), ("checkmark.circle.fill", "Done"),
        ("tray", "Inbox"), ("eye", "Review"), ("checkmark.seal", "Testing"), ("hand.raised", "Blocked"),
        ("hourglass", "Waiting"), ("shippingbox", "Release"), ("paintbrush", "Design"), ("doc.text", "Docs"),
        ("flag", "Ready"), ("hammer", "Build"), ("clock", "Scheduled"), ("pause.circle", "Paused"),
        ("bolt", "Urgent"), ("star", "Priority"), ("sparkles", "Ideas"), ("bubble.left", "Feedback"),
    ]

    static func iconName(_ symbol: String) -> String { iconChoices.first { $0.symbol == symbol }?.name ?? "Custom" }

    // MARK: Stage

    /// The accessible name for this column kind (also used in tooltips); it stays the stage
    /// whatever icon is chosen.
    var kindName: String {
        switch kind {
        case .backlog: "Not started"
        case .active: "In progress"
        case .done: "Done"
        }
    }

    /// The 1–3-word tooltip for the column kind.
    var tooltip: String { kindName }
}

extension TaskColor {
    var name: String { String(describing: self).capitalized }
}

/// Keeps an accent's icon and rule at 3:1 or more against the header in both appearances.
enum KanbanContrast {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// Light and dark window backgrounds, with the header's 6% wash of the accent mixed in.
    static let lightSurface: RGB = (0.925, 0.925, 0.925)
    static let darkSurface: RGB = (0.118, 0.118, 0.118)
    static let minimum = 3.0

    static func accent(_ hex: String) -> Color {
        guard let base = rgb(hex) else { return .gray }
        let light = nsColor(adjusted(base, dark: false)), dark = nsColor(adjusted(base, dark: true))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    /// The colour moved toward black (light mode) or white (dark mode) in 5% steps until it
    /// reaches the minimum contrast against its washed surface.
    static func adjusted(_ color: RGB, dark: Bool) -> RGB {
        var color = color
        for _ in 0..<40 where contrast(color, surface(for: color, dark: dark)) < minimum {
            let target = dark ? 1.0 : 0.0
            color = (color.r + (target - color.r) * 0.05, color.g + (target - color.g) * 0.05, color.b + (target - color.b) * 0.05)
        }
        return color
    }

    static func surface(for accent: RGB, dark: Bool) -> RGB {
        let base = dark ? darkSurface : lightSurface
        return (base.r * 0.94 + accent.r * 0.06, base.g * 0.94 + accent.g * 0.06, base.b * 0.94 + accent.b * 0.06)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func rgb(_ hex: String) -> RGB? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// Black or white, whichever stands out more on `hex` as drawn in each appearance (for the
    /// letters and checks on swatches).
    static func foreground(on hex: String) -> Color {
        guard let base = rgb(hex) else { return .primary }
        func pick(_ dark: Bool) -> NSColor {
            let fill = adjusted(base, dark: dark)
            return contrast(fill, (1, 1, 1)) >= contrast(fill, (0, 0, 0)) ? .white : .black
        }
        let (light, dark) = (pick(false), pick(true))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    private static func nsColor(_ c: RGB) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
}

/// A compact badge showing the column kind glyph and name, used in multiple views.
struct KanbanColumnBadge: View {
    let style: KanbanColumnStyle
    var fontSize: CGFloat = 13
    var isCompact: Bool = false

    var body: some View {
        HStack(spacing: isCompact ? 3 : 4) {
            Image(systemName: style.symbol)
                .font(.system(size: 11))
                .foregroundStyle(style.effectiveAccent)
                .help(style.tooltip)
            if !isCompact {
                Text(style.kind == .done ? "Done" : style.kindName)
                    .font(.system(size: fontSize))
            }
        }
    }
}
