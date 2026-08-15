import SwiftUI
import SwiftData

/// Month-grid calendar: a 6×7 grid where each day cell shows its tasks, plus a
/// side panel with the selected day's full agenda. Complements the default week
/// view (P2b).
struct CalendarMonthView: View {
    @Environment(AppState.self) private var app
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @Query(sort: [SortDescriptor(\TaskItem.sortIndex)]) private var allTasks: [TaskItem]

    var body: some View {
        let days = WeekMath.monthGridDays(containing: app.weekAnchor, weekStartsMonday: weekStartsMonday)
        let tasksByDay = Dictionary(grouping: allTasks.filter { $0.dayKey != nil }, by: { $0.dayKey! })

        HStack(spacing: 0) {
            VStack(spacing: 8) {
                weekdayHeader(sample: Array(days.prefix(7)))
                grid(days: days, tasksByDay: tasksByDay)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            DayAgendaView(dayKey: app.selectedDayKey)
                .frame(width: 300)
        }
    }

    private func weekdayHeader(sample: [Date]) -> some View {
        HStack(spacing: 4) {
            ForEach(sample, id: \.self) { day in
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// A month grid that scales to fill the available width and height: each week
    /// is a row taking an equal share of the height, and each day cell fills its
    /// column and row.
    private func grid(days: [Date], tasksByDay: [String: [TaskItem]]) -> some View {
        let todayKey = WeekMath.dayKey(for: Date())
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0 ..< min($0 + 7, days.count)]) }
        return VStack(spacing: 4) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 4) {
                    ForEach(week, id: \.self) { day in
                        let key = WeekMath.dayKey(for: day)
                        Button { app.select(day: day) } label: {
                            CalendarDayCell(
                                date: day,
                                inCurrentMonth: WeekMath.isSameMonth(day, as: app.weekAnchor),
                                isToday: key == todayKey,
                                isSelected: key == app.selectedDayKey,
                                tasks: tasksByDay[key] ?? []
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A single day cell in the month grid: day number, task count, and up to three
/// task previews.
private struct CalendarDayCell: View {
    let date: Date
    let inCurrentMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let tasks: [TaskItem]

    private var dayNumber: Int { Calendar.current.component(.day, from: date) }

    @State private var isHovering = false
    private var cellFill: Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        if isHovering { return Color.primary.opacity(0.08) }
        return Color.primary.opacity(0.03)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(dayNumber)")
                    .font(.caption)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(dayNumberColor)
                Spacer()
                if !tasks.isEmpty {
                    Text("\(tasks.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(tasks.prefix(3)) { task in
                HStack(spacing: 3) {
                    if task.isCritical {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Critical")
                    }
                    Circle()
                        .fill(task.priorityLevel.tint)
                        .frame(width: 5, height: 5)
                    Text(task.title.isEmpty ? "Untitled" : task.title)
                        .font(.caption2)
                        .lineLimit(1)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                }
            }

            if tasks.count > 3 {
                Text("+\(tasks.count - 3) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(cellFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isToday ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .opacity(inCurrentMonth ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var dayNumberColor: Color {
        if isToday { return .accentColor }
        return inCurrentMonth ? .primary : .secondary
    }
}
