import SwiftUI
import SwiftData

/// The horizontal row of custom-list cards beneath the week grid. Each card is
/// sized to match a day column (same width formula + 8pt padding/gaps) so the
/// lists line up directly under the day columns above; the row scrolls
/// horizontally when there are more lists than day columns.
struct CustomListsRow: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @AppStorage("calendarColumns") private var calendarColumns = 5
    @Query(sort: [SortDescriptor(\CustomList.sortIndex)]) private var lists: [CustomList]
    var onEditTask: (TaskItem) -> Void

    var body: some View {
        GeometryReader { geo in
            let cardWidth = columnWidth(for: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(lists) { list in
                            CustomListColumn(list: list, onEditTask: onEditTask, onReorderList: reorderLists)
                                .frame(width: cardWidth)
                                .id(list.id)
                        }
                        addListButton
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .frame(minWidth: geo.size.width, alignment: .leading)
                }
                .onChange(of: app.highlightedTaskID) { _, id in scrollToOwningList(id, proxy: proxy) }
                .onAppear { scrollToOwningList(app.highlightedTaskID, proxy: proxy) }
            }
        }
    }

    /// When a searched-for task lives in a custom list, bring that list's column
    /// into the horizontal viewport (the column itself scrolls to the row).
    private func scrollToOwningList(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id, let owner = lists.first(where: { list in list.tasks.contains { $0.id == id } }) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(owner.id, anchor: .center) }
        }
    }

    /// Matches `WeekView`'s day-column width exactly: (width − 16pt outer padding
    /// − 8pt gaps) ÷ column count. No minimum floor (WeekView has none), so the
    /// cards track the day columns at every column count; `max(1, …)` only guards
    /// against a transient zero-width layout pass.
    private func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        let cols = CGFloat(max(1, min(12, calendarColumns)))
        let usable = totalWidth - 16 - 8 * (cols - 1)
        return max(1, usable / cols)
    }

    private var addListButton: some View {
        Button(action: addList) {
            Label("Add list", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.top, 4)
    }

    private func addList() {
        do {
            let service = DataService(context)
            _ = try service.addCustomList(name: "New List")
            try service.save()
        } catch {
            // Surfacing save errors in the UI is tracked as a P13 hardening item.
        }
    }

    /// Persist a manual reorder after a list card is dropped onto another card.
    private func reorderLists(_ draggedID: UUID, before beforeID: UUID?) {
        let newOrder = BehaviorService.reordered(lists, moving: draggedID, before: beforeID)
        try? DataService(context).reorderLists(newOrder)
    }
}
