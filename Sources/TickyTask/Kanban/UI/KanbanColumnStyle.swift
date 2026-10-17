import SwiftUI

/// Visual presentation for column kinds: symbol, accent color, and accessible description.
struct KanbanColumnStyle {
    let kind: KanbanColumnKind
    let customColorHex: String?

    init(kind: KanbanColumnKind, customColorHex: String?) {
        self.kind = kind
        self.customColorHex = customColorHex
    }

    /// The effective accent color: custom override or kind's semantic color.
    var effectiveAccent: Color {
        if let hex = customColorHex, let color = KanbanUI.color(hex) {
            return color
        }
        return kindAccent
    }

    /// The kind's default semantic color.
    private var kindAccent: Color {
        switch kind {
        case .backlog: return .red
        case .active: return .orange
        case .done: return .green
        }
    }

    /// The SF Symbol for this column kind.
    var symbol: String {
        switch kind {
        case .backlog: return "circle.dashed"
        case .active: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }

    /// The accessible name for this column kind (also used in tooltips).
    var kindName: String {
        switch kind {
        case .backlog: return "Not started"
        case .active: return "In progress"
        case .done: return "Done"
        }
    }

    /// The 1–3-word tooltip for the column kind.
    var tooltip: String { kindName }
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
