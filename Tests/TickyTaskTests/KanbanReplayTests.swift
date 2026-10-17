import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// The time metrics (design 02 §3): replay, cumulative flow, throughput, aging and burn-up,
/// on a real board whose change-log entries are dated by hand. Calendar: Europe/London,
/// weeks from Monday, now = Wed 2026-10-14 12:00 (MetricsFixture).
@MainActor
@Suite("Kanban replay", .serialized)
struct KanbanReplayTests {
    typealias F = MetricsFixture
    typealias R = KanbanReplay

    @MainActor
    final class Board {
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()))
        let project: KanbanProject
        init() throws { project = try service.createProject(name: "Platform", key: "PLAT") }
        var todo: KanbanColumn { project.orderedColumns[0] }
        var doing: KanbanColumn { project.orderedColumns[1] }
        var done: KanbanColumn { project.orderedColumns.last! }

        /// Dates the newest change-log entry (fetched: the inverse array can lag).
        func at(_ date: Date) { entries().max { $0.seq < $1.seq }?.at = date }

        func entries() -> [KanbanActivity] {
            let id = project.id
            return (try? project.modelContext?.fetch(FetchDescriptor<KanbanActivity>(predicate: #Predicate { $0.project?.id == id }))) ?? []
        }

        /// Removes a card's change-log entries, as for data from before the log existed.
        func forget(_ task: KanbanTask, kind: KanbanActivityKind? = nil) {
            for entry in entries() where entry.taskIDs.contains(task.id) && (kind == nil || entry.kindRaw == kind?.rawValue) {
                project.modelContext?.delete(entry)
            }
        }

        func card(_ title: String, in column: KanbanColumn? = nil, on date: Date) throws -> KanbanTask {
            let task = try service.createTask(in: project, title: title, column: column)
            at(date)
            task.createdAt = date
            return task
        }

        func move(_ task: KanbanTask, to column: KanbanColumn, on date: Date) throws {
            try service.move(.cards([task.id], to: .columnHeader(column.id)), in: project)
            at(date)
        }

        func snapshot(hours: Bool = false) -> MetricsSnapshot {
            var s = MetricsSnapshot(project: project, now: F.now, calendar: F.calendar())
            if hours { s.loadMeasure = .hours }
            return s
        }

        var activities: [MetricsActivity] { MetricsActivity.records(of: project) }
    }

    private func counts(_ day: R.Day) -> [String: Int] {
        Dictionary(day.bands.map { ($0.name, $0.count) }, uniquingKeysWith: +)
    }

    /// Counts of a day that may be missing (so a failure shows the values).
    private func countsOn(_ day: R.Day?) -> [String: Int] { day.map(counts) ?? ["<no day>": 0] }

    private func day(_ days: [R.Day], _ date: Date) -> R.Day? {
        let target = F.calendar().startOfDay(for: date)
        return days.first { $0.day == target }
    }

    // MARK: - Replay

    @Test func replayMatchesCurrentBoardToday() throws {
        let b = try Board()
        let a = try b.card("A", on: F.date(10, 1)), c = try b.card("C", on: F.date(10, 2))
        try b.move(a, to: b.doing, on: F.date(10, 5))
        try b.move(c, to: b.done, on: F.date(10, 8))
        let days = R.cfd(b.snapshot(), activities: b.activities, days: 14)
        #expect(days.count == 14)
        #expect(countsOn(days.last) == ["To Do": 0, "In Progress": 1, "Done": 1])
        #expect(countsOn(day(days, F.date(10, 3))) == ["To Do": 2, "In Progress": 0, "Done": 0])
        #expect(days.last?.bands.map(\.kind) == [.done, .active, .backlog], "Done at the bottom, the backlog on top")
    }

    @Test func replayOrdersBySeqNotAt() throws {
        let b = try Board()
        let a = try b.card("A", on: F.date(10, 1))
        try b.move(a, to: b.doing, on: F.date(10, 5))
        try b.move(a, to: b.done, on: F.date(10, 4))   // a clock skew: the later entry is dated earlier
        let days = R.cfd(b.snapshot(), activities: b.activities, days: 14)
        #expect(countsOn(day(days, F.date(10, 6))) == ["To Do": 0, "In Progress": 0, "Done": 1], "applied in seq order")
    }

    @Test func groupedAndInverseTransitionsReplay() throws {
        let b = try Board()
        let a = try b.card("A", on: F.date(10, 1)), c = try b.card("C", on: F.date(10, 1))
        try b.service.move(.cards([a.id, c.id], to: .columnHeader(b.doing.id)), in: b.project)
        b.at(F.date(10, 3))
        try b.service.revert(try #require(b.entries().max { $0.seq < $1.seq }))
        b.at(F.date(10, 5))
        let days = R.cfd(b.snapshot(), activities: b.activities, days: 14)
        #expect(countsOn(day(days, F.date(10, 4)))["In Progress"] == 2)
        #expect(countsOn(day(days, F.date(10, 6)))["To Do"] == 2, "the revert's inverse moves them back")
    }

    @Test func resourceOnlyMoveKeepsColumn() throws {
        let b = try Board()
        let ravi = try b.service.addMembership(try b.service.createPerson(name: "Ravi", initials: "RV"), to: b.project)
        let a = try b.card("A", in: b.doing, on: F.date(10, 1))
        try b.service.move(.cards([a.id], to: .rowHeader(.resource(ravi.id))), in: b.project)
        b.at(F.date(10, 3))
        #expect(countsOn(R.cfd(b.snapshot(), activities: b.activities, days: 14).last)["In Progress"] == 1)
        #expect(R.agingWIP(b.snapshot(), activities: b.activities).first?.ageDays == 13, "aging ignores the reassignment")
    }

    @Test func archiveRestoreToggles() throws {
        let b = try Board()
        let a = try b.card("A", on: F.date(10, 1))
        try b.service.archiveTask(a)
        b.at(F.date(10, 4))
        try b.service.restoreTask(a)
        b.at(F.date(10, 7))
        let days = R.cfd(b.snapshot(), activities: b.activities, days: 14)
        #expect(countsOn(day(days, F.date(10, 5)))["To Do"] == 0)
        #expect(countsOn(day(days, F.date(10, 8)))["To Do"] == 1)
    }

    @Test func deletedTaskKeepsHistory() throws {
        let b = try Board()
        let a = try b.card("A", on: F.date(10, 1))
        try b.service.deleteTask(a)
        b.at(F.date(10, 6))
        let days = R.cfd(b.snapshot(), activities: b.activities, days: 14)
        #expect(countsOn(day(days, F.date(10, 3)))["To Do"] == 1, "it existed then")
        #expect(countsOn(days.last)["To Do"] == 0)
    }

    @Test func deletedColumnGreyBandUsesSnapshotName() throws {
        let b = try Board()
        let review = try b.service.addColumn(to: b.project, name: "Review", at: 2)
        let a = try b.card("A", in: review, on: F.date(10, 1))
        _ = a
        try b.service.deleteColumn(review, movingTasksTo: b.doing)
        b.at(F.date(10, 6))
        let days = R.cfd(b.snapshot(), activities: b.activities, days: 14)
        let before = try #require(day(days, F.date(10, 3)))
        let band = try #require(before.bands.first { $0.name == "Review" })
        #expect(band.isDeleted && band.count == 1 && band.kind == .active)
        #expect(before.bands.last?.name == "Review", "deleted columns stack above the live ones")
        #expect(countsOn(days.last)["In Progress"] == 1)
    }

    @Test func legacyTaskSynthesisedCreate() throws {
        let b = try Board()
        let a = try b.card("A", on: F.date(10, 1))
        // Drop its `created` entry, as for data from before the log existed.
        b.forget(a, kind: .created)
        a.createdAt = F.date(10, 2)
        let days = R.cfd(b.snapshot(), activities: b.activities, days: 14)
        #expect(countsOn(day(days, F.date(10, 1)))["To Do"] == 0)
        #expect(countsOn(day(days, F.date(10, 2)))["To Do"] == 1)
    }

    @Test func dstWeekHasOnePointPerDay() throws {
        let b = try Board()
        _ = try b.card("A", on: F.date(10, 20))
        var s = b.snapshot()
        s.now = F.date(10, 28)
        let days = R.cfd(s, activities: b.activities, days: 7)
        #expect(days.map { F.calendar().component(.day, from: $0.day) } == [22, 23, 24, 25, 26, 27, 28], "the clocks go back on the 25th")
    }

    // MARK: - Throughput, burn-up

    @Test func throughputCountsLatestCompletionOnly() throws {
        let b = try Board()
        let direct = try b.card("Direct", in: b.done, on: F.date(10, 1))
        _ = direct
        let reopened = try b.card("Reopened", on: F.date(9, 21))
        try b.move(reopened, to: b.done, on: F.date(9, 23))     // week of 21 Sep
        try b.move(reopened, to: b.doing, on: F.date(9, 30))    // reopened
        try b.move(reopened, to: b.done, on: F.date(10, 13))    // completed again this week
        let finished = try b.card("Finished", on: F.date(10, 1))
        try b.move(finished, to: b.done, on: F.date(10, 6))     // week of 5 Oct
        let other = try b.service.addColumn(to: b.project, name: "Shipped", at: b.project.columns.count)
        try b.service.editColumn(other, kind: .done)
        try b.move(finished, to: other, on: F.date(10, 7))      // Done → Done
        let archived = try b.card("Archived", on: F.date(10, 1))
        try b.move(archived, to: b.done, on: F.date(10, 7))
        try b.service.archiveTask(archived)
        let weeks = R.throughput(b.snapshot(), activities: b.activities, weeks: 4)
        #expect(weeks.map { F.calendar().component(.day, from: $0.start) } == [21, 28, 5, 12])
        #expect(weeks.map(\.completed) == [0, 0, 2, 1], "created-in-Done and Done→Done don't count; the reopen moved out of 21 Sep")
        #expect(weeks.map(\.reopened) == [0, 1, 0, 0])
        #expect(weeks.map(\.partial) == [false, false, false, true])
    }

    @Test func burnUpScopeAndCompletedFromBands() throws {
        let b = try Board()
        let a = try b.card("A", on: F.date(10, 1)), c = try b.card("C", on: F.date(10, 2))
        try b.service.edit(a, [.estimateHours: .double(3)])
        try b.move(a, to: b.done, on: F.date(10, 5))
        _ = c
        let points = R.burnUp(b.snapshot(), activities: b.activities, days: 14)
        let cfd = R.cfd(b.snapshot(), activities: b.activities, days: 14)
        for (point, day) in zip(points, cfd) {
            #expect(point.scope == Double(day.bands.reduce(0) { $0 + $1.count }))
            #expect(point.completed == Double(day.bands.filter { $0.kind == .done }.reduce(0) { $0 + $1.count }))
        }
        let hours = R.burnUp(b.snapshot(hours: true), activities: b.activities, days: 14)
        #expect(hours.last == R.BurnUpPoint(day: F.calendar().startOfDay(for: F.now), scope: 7, completed: 3), "today's estimates (3 h + 4 h default)")
    }

    @Test func agingFallsBackToCreatedAt() throws {
        let b = try Board()
        let a = try b.card("A", in: b.doing, on: F.date(10, 4))
        try b.move(a, to: b.todo, on: F.date(10, 6))
        try b.move(a, to: b.doing, on: F.date(10, 10))
        let legacy = try b.card("Legacy", in: b.doing, on: F.date(10, 1))
        b.forget(legacy)
        let aging = R.agingWIP(b.snapshot(), activities: b.activities)
        #expect(aging.map(\.ageDays) == [13, 4], "Legacy from createdAt; A from its latest entry into In Progress")
    }

    @Test func replayBudget() throws {
        let b = try Board()
        let cards = try (0..<200).map { try b.card("Card \($0)", on: F.date(9, 1 + $0 % 28)) }
        for (i, card) in cards.enumerated() where i % 2 == 0 { try b.move(card, to: b.doing, on: F.date(10, 1 + i % 13)) }
        let s = b.snapshot(), activities = b.activities
        let elapsed = ContinuousClock().measure { _ = R.cfd(s, activities: activities, days: 90) }
        #expect(elapsed < .milliseconds(300), "\(elapsed)")
    }
}
