import SwiftUI
import SwiftData

/// A column's Appearance…: its colour and icon, each Automatic (from its stage and name) or
/// chosen. Each pick applies at once as one undoable Change Log entry; the preview shows the
/// header and a cell as the board draws them.
struct KanbanColumnAppearancePopover: View {
    let column: KanbanColumn
    let count: Int
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        let style = KanbanColumnStyle(column)
        VStack(alignment: .leading, spacing: 14) {
            preview(style)
            section("Colour") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 6), alignment: .leading, spacing: 4) {
                    automaticColour(style)
                    ForEach(TaskColor.allCases) { colour in
                        swatch(KanbanContrast.accent(colour.hex), name: colour.name, selected: column.colorHex?.lowercased() == colour.hex) {
                            apply(colorHex: .some(colour.hex))
                        }
                    }
                }
            }
            section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 6), alignment: .leading, spacing: 4) {
                    tile(style.automaticSymbol, name: "Automatic: \(KanbanColumnStyle.iconName(style.automaticSymbol))", accent: style.effectiveAccent,
                         selected: column.symbolName == nil, badge: "A") { apply(symbolName: .some(nil)) }
                    ForEach(KanbanColumnStyle.iconChoices, id: \.symbol) { choice in
                        tile(choice.symbol, name: choice.name, accent: style.effectiveAccent, selected: column.symbolName == choice.symbol) {
                            apply(symbolName: .some(choice.symbol))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Automatic (A) follows the column’s stage and name.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset to automatic") { apply(colorHex: .some(nil), symbolName: .some(nil)) }
                    .disabled(column.colorHex == nil && column.symbolName == nil)
                    .accessibilityIdentifier("kanban-appearance-reset")
            }
        }
        .padding(14)
        .frame(width: 252)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban-appearance-\(column.name)")
    }

    /// The real header over a sample cell, so the subtle wash and tint show.
    private func preview(_ style: KanbanColumnStyle) -> some View {
        VStack(spacing: 0) {
            KanbanColumnHeader(column: column, count: count, hours: nil)
                .frame(height: 40)
            ZStack(alignment: .top) {
                style.effectiveAccent.opacity(0.06)
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    .frame(height: 22)
                    .padding(6)
            }
            .frame(height: 40)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityHidden(true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func automaticColour(_ style: KanbanColumnStyle) -> some View {
        let stage = KanbanColumnStyle(kind: column.kind, customColorHex: nil)
        return swatch(stage.effectiveAccent, name: "Automatic: \(stage.colorName)", selected: column.colorHex == nil, badge: "A") {
            apply(colorHex: .some(nil))
        }
    }

    /// A 22 pt colour in a 30 pt target; the chosen one has a ring and a check.
    private func swatch(_ colour: Color, name: String, selected: Bool, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(colour).frame(width: 22, height: 22)
                if let badge, !selected {
                    Text(badge).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
                if selected {
                    Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 28, height: 28)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("kanban-appearance-colour-\(name)")
    }

    /// A 28 pt icon tile in a 34 pt target; the chosen one has an outline and a check.
    private func tile(_ symbol: String, name: String, accent: Color, selected: Bool, badge: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? AnyShapeStyle(accent.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5))))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? accent : .clear, lineWidth: 2))
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.white, accent).offset(x: 3, y: -3)
                } else if let badge {
                    Text(badge).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).offset(x: -2, y: 1)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("Icon: \(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("kanban-appearance-icon-\(symbol)")
    }

    /// Picking what's already set writes nothing (`editColumn` skips unchanged fields).
    private func apply(colorHex: String?? = nil, symbolName: String?? = nil) {
        app.runKanban { try app.kanbanService(context).editColumn(column, colorHex: colorHex, symbolName: symbolName) }
    }
}
