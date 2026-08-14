import SwiftUI
import SwiftData

/// The horizontal row of custom-list cards beneath the week grid. Lists are
/// user-created, date-independent, and renamable.
struct CustomListsRow: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\CustomList.sortIndex)]) private var lists: [CustomList]
    var onEditTask: (TaskItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(lists) { list in
                    CustomListColumn(list: list, onEditTask: onEditTask)
                        .frame(width: 260)
                }
                addListButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .frame(maxHeight: .infinity, alignment: .top)
        }
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
}
