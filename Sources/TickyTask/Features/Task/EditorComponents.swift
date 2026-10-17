import SwiftUI

/// Editor pieces shared by the planner's task editor and the Kanban card editor, so both
/// look and behave the same (design 01 §5, D4).

/// Low / Medium / High, with each level's glyph.
struct PriorityPicker: View {
    @Binding var selection: TaskPriority

    var body: some View {
        Picker("Priority", selection: $selection) {
            ForEach(TaskPriority.allCases) { priority in
                Label(priority.label, systemImage: priority.symbol).tag(priority)
            }
        }
    }
}

/// The Critical flag: a red flag shown before the priority, independent of its level.
struct CriticalToggle: View {
    @Binding var isOn: Bool
    var help = "Mark this task critical — shown with a red flag before its priority, independent of the priority level."

    var body: some View {
        Toggle(isOn: $isOn) {
            Label("Critical", systemImage: "flag.fill")
        }
        .help(help)
    }
}

/// One editable checklist item: a done circle, the title and a delete button on hover.
struct ChecklistRow: View {
    @Binding var title: String
    @Binding var isDone: Bool
    var toggleIdentifier: String
    var onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack {
            Button { isDone.toggle() } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 20)
            .accessibilityIdentifier(toggleIdentifier)

            TextField("Subtask", text: $title)
                .strikethrough(isDone)

            if isHovering {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
