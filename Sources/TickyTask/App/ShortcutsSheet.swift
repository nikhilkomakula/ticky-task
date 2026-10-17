import SwiftUI

/// Every keyboard shortcut in one place (⌘/), filtered by which modules are visible.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ModulePolicy.showPlannerKey) private var showPlanner = true
    @AppStorage(ModulePolicy.showKanbanKey) private var showKanban = true

    private typealias Group = (title: String, rows: [(keys: String, action: String)])

    private var groups: [Group] {
        let policy = ModulePolicy(showPlanner: showPlanner, showKanban: showKanban)
        var groups: [Group] = [("Everywhere", [
            ("⌘F", "Search tasks and cards"), ("⇧⌘Y", "Weekly Summary"), ("⌘,", "Settings"), ("⌘/", "This list"),
        ] + (policy.showsSwitcher ? [(ModuleShortcuts.shared.summary, "Planner / Kanban")] : []))]
        if policy.isVisible(.kanban) {
            groups.append(("Kanban board", [
                ("⌘N", "New card in the backlog"), ("⌘Z / ⇧⌘Z", "Undo / redo a board change"),
                ("⌃⌘↑ / ⌃⌘↓", "Collapse / expand all rows"), ("⌘-click", "Select several cards"), ("Esc", "Clear the selection"),
            ]))
            groups.append(("Focused card", [
                ("↑ ↓ ← →", "Move between cards"), ("⌘← / ⌘→", "Previous / next column"), ("⌘↑ / ⌘↓", "Previous / next person"),
                ("⌥⌘ arrows", "Reorder within the cell"), ("Return", "Open"), ("Space", "Quick look"), ("M", "Move…"), ("⌘D", "Duplicate"),
            ]))
            groups.append(("Focused column or row header", [("⌥⌘ arrows", "Reorder columns or rows")]))
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard Shortcuts").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).font(.subheadline.weight(.semibold))
                            ForEach(group.rows, id: \.action) { row in
                                HStack {
                                    Text(row.keys).font(.body.monospaced()).frame(width: 130, alignment: .leading)
                                    Text(row.action)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 440, height: 480)
        .accessibilityIdentifier("shortcuts-sheet")
    }
}
