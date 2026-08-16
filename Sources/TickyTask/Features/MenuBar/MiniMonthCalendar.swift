import SwiftUI
import SwiftData

/// A compact month calendar that fills the available width (unlike the graphical
/// `DatePicker`). The menu-bar calendar is always **Sunday → Saturday** and
/// highlights the weekend (Sat/Sun) columns so they're distinguishable at a
/// glance. Selecting a day updates the shared `AppState`; month navigation is
/// local.
struct MiniMonthCalendar: View {
    /// Menu-bar-local selection (independent of the main window), so the popover
    /// can default to today on each open without moving the main window.
    @Binding var selectedDayKey: String
    @Environment(\.modelContext) private var context
    @Environment(DragController.self) private var drag
    @Query(sort: [SortDescriptor(\TaskItem.sortIndex)]) private var allTasks: [TaskItem]
    @State private var monthAnchor = Date()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        // Menu-bar calendar is fixed to a Sunday-first week per product decision.
        let days = WeekMath.monthGridDays(containing: monthAnchor, weekStartsMonday: false)
        let todayKey = WeekMath.dayKey(for: Date())

        VStack(spacing: 6) {
            header

            HStack(spacing: 2) {
                ForEach(Array(days.prefix(7)), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isWeekend(day) ? Color.red.opacity(0.8) : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(days, id: \.self) { day in
                    dayCell(day, todayKey: todayKey)
                }
            }
        }
        .onAppear(perform: alignMonthToSelection)
        // Realign the visible month when the selection resets — e.g. the popover
        // reopens on today after the user had navigated to another month.
        .onChange(of: selectedDayKey) { _, _ in alignMonthToSelection() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            Text(monthAnchor.formatted(.dateTime.month(.wide).year()))
                .font(.subheadline.weight(.semibold))
            Button(action: goToToday) {
                Text("Today").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Jump to today")
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
        }
    }

    /// Jump the popover's selection and visible month back to today. Sets
    /// `monthAnchor` directly too, because if today is already the selection the
    /// `selectedDayKey` change wouldn't fire `alignMonthToSelection()` (so a user
    /// who navigated months away could otherwise get stuck).
    private func goToToday() {
        let today = Date()
        selectedDayKey = WeekMath.dayKey(for: today)
        monthAnchor = today
    }

    private func dayCell(_ day: Date, todayKey: String) -> some View {
        let key = WeekMath.dayKey(for: day)
        let inMonth = WeekMath.isSameMonth(day, as: monthAnchor)
        let isSelected = key == selectedDayKey
        let isToday = key == todayKey
        let weekend = isWeekend(day)

        // Selection is a tap gesture (not a Button) so it coexists with the drag
        // engine; the cell is an append drop target for cross-day moves in the popover.
        return Text("\(Calendar.current.component(.day, from: day))")
            .font(.callout)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.25)
                    : (weekend ? Color.red.opacity(0.08) : Color.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isToday ? Color.accentColor : .clear, lineWidth: 1)
            )
            .foregroundStyle(inMonth ? (isToday ? Color.accentColor : .primary) : .secondary)
            .contentShape(Rectangle())
            .onTapGesture { selectedDayKey = key }
            .publishContainerFrame(.monthDay(key), accepts: .task, axis: .vertical,
                                   isEmpty: allTasks.filter { $0.dayKey == key }.isEmpty)
    }

    /// Saturday (7) or Sunday (1) in the Gregorian calendar — independent of the
    /// locale's weekend definition, matching the requested Sat/Sun highlight.
    private func isWeekend(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    private func shiftMonth(_ delta: Int) {
        // Normalize to the first of the month before shifting, so navigating from
        // a 29–31 date can't skip a shorter month (e.g. Jan 31 + 1 → March).
        let firstOfCurrent = WeekMath.firstOfMonth(containing: monthAnchor)
        if let shifted = Calendar.current.date(byAdding: .month, value: delta, to: firstOfCurrent) {
            monthAnchor = shifted
        }
    }

    private func alignMonthToSelection() {
        if let selected = WeekMath.date(fromDayKey: selectedDayKey) {
            monthAnchor = selected
        }
    }
}
