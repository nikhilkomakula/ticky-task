import SwiftUI

/// A rounded material "card" surface shared by day columns and custom lists, so
/// they read as deliberate panels rather than divider-separated regions.
struct CardSurface: ViewModifier {
    var selected: Bool = false

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
            }
    }
}

extension View {
    func cardSurface(selected: Bool = false) -> some View {
        modifier(CardSurface(selected: selected))
    }
}

/// Friendly empty state for task columns, lists, and the agenda.
struct EmptyTasksView: View {
    var title: String = "No tasks"
    var hint: String = "Add one below"

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
    }
}

/// Shared inline "add task/list" field with a focus-aware material background,
/// used identically by day columns, the agenda, and custom lists.
struct QuickAddField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                    lineWidth: focused ? 1.5 : 1
                )
        }
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}
