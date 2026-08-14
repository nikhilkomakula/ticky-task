import SwiftUI

/// A compact month calendar that **fills the available width** — unlike the
/// graphical `DatePicker`, which renders at its intrinsic size and centers,
/// leaving side gaps. Uses a flexible 7-column grid so day cells stretch to the
/// popover width. Selecting a day updates the shared `AppState`; month
/// navigation is local.
struct MiniMonthCalendar: View {
    @Environment(AppState.self) private var app
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @State private var monthAnchor = Date()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        let days = WeekMath.monthGridDays(containing: monthAnchor, weekStartsMonday: weekStartsMonday)
        let todayKey = WeekMath.dayKey(for: Date())

        VStack(spacing: 6) {
            header

            HStack(spacing: 2) {
                ForEach(Array(days.prefix(7)), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
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
    }

    private var header: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            Text(monthAnchor.formatted(.dateTime.month(.wide).year()))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
        }
    }

    private func dayCell(_ day: Date, todayKey: String) -> some View {
        let key = WeekMath.dayKey(for: day)
        let inMonth = WeekMath.isSameMonth(day, as: monthAnchor)
        let isSelected = key == app.selectedDayKey
        let isToday = key == todayKey

        return Button {
            app.select(day: day)
        } label: {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(
                    isSelected ? Color.accentColor.opacity(0.25) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isToday ? Color.accentColor : .clear, lineWidth: 1)
                )
                .foregroundStyle(inMonth ? (isToday ? Color.accentColor : .primary) : .secondary)
        }
        .buttonStyle(.plain)
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
        if let selected = WeekMath.date(fromDayKey: app.selectedDayKey) {
            monthAnchor = selected
        }
    }
}
