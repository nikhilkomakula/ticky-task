import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// The dashboard formulas (design 02-metrics.md), on a fixed calendar: Europe/London, weeks
/// starting Monday, now = Wed 2026-10-14 12:00, so week 0 is Mon 12 – Sun 18 October.
enum MetricsFixture {
    static func calendar(firstWeekday: Int = 2, zone: String = "Europe/London") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        cal.firstWeekday = firstWeekday
        return cal
    }

    static func date(_ month: Int, _ day: Int, _ hour: Int = 12, minute: Int = 0, cal: Calendar = calendar()) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    static let now = date(10, 14)
    static let backlog = UUID(), doing = UUID(), review = UUID(), done = UUID()
    static let columns: [MetricsSnapshot.Column] = [
        .init(id: backlog, name: "To Do", kind: .backlog), .init(id: doing, name: "Doing", kind: .active),
        .init(id: review, name: "Review", kind: .active), .init(id: done, name: "Done", kind: .done),
    ]

    static func member(_ name: String, allocation: Int = 100, employment: KanbanEmployment = .fte,
                       assignment: KanbanAssignment = .fullTime, person: UUID = UUID()) -> MetricsSnapshot.Member {
        .init(id: UUID(), personID: person, name: name, employment: employment, assignment: assignment, allocationPercent: allocation)
    }

    static func card(_ column: UUID = backlog, _ resource: MetricsSnapshot.Member? = nil, start: Date? = nil, due: Date? = nil,
                     hours: Double? = nil, created: Date = date(10, 1)) -> MetricsSnapshot.Card {
        .init(id: UUID(), column: column, resource: resource?.id, dueDate: due, startDate: start, estimateHours: hours,
              createdAt: created, updatedAt: created)
    }

    static func board(_ members: [MetricsSnapshot.Member] = [], _ cards: [MetricsSnapshot.Card] = [], hours: Bool = false,
                      cal: Calendar = calendar(), now: Date = now) -> MetricsSnapshot {
        MetricsSnapshot(projectID: UUID(), projectName: "Platform", loadMeasure: hours ? .hours : .taskCount,
                        columns: columns, members: members, cards: cards, now: now, calendar: cal)
    }
}

@MainActor
@Suite("Kanban metrics")
struct KanbanMetricsTests {
    typealias F = MetricsFixture
    typealias M = KanbanMetrics

    private func row(_ s: MetricsSnapshot, _ m: MetricsSnapshot.Member) throws -> M.LoadRow {
        try #require(M.loadVsCapacity(s).first { $0.memberID == m.id })
    }

    private func weeks(_ s: MetricsSnapshot, _ c: MetricsSnapshot.Card, _ n: Int = 3) -> [Double] {
        M.weeklyLoads(s, MetricsDays(s), c, weeks: n)
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    // MARK: - §0 Load, target, utilisation

    @Test func previewBaselineMatchesHeadlineNextWeekTaskIsZero() throws {
        let ravi = F.member("Ravi")
        let next = F.card(F.doing, ravi, start: F.date(10, 19), due: F.date(10, 23), hours: 10)
        let s = F.board([ravi], [next], hours: true)
        #expect(try row(s, ravi).load == 0)
        #expect(M.projectedLoad(s, member: ravi, dragged: [], toColumn: F.doing, toResource: ravi.id).load == 0)
        #expect(weeks(s, next) == [0, 10, 0])
    }

    @Test func loadCountsOnlyOpenUnarchived() throws {
        let ravi = F.member("Ravi")
        var archived = F.card(F.doing, ravi)
        archived.archived = true
        let s = F.board([ravi], [F.card(F.backlog, ravi), F.card(F.doing, ravi), F.card(F.done, ravi), archived])
        #expect(try row(s, ravi).load == 2)
    }

    @Test func partTime50TargetIs2_5() {
        #expect(M.target(F.board(), F.member("Mia", allocation: 50)) == 2.5)
    }

    @Test func overrideIsAbsoluteNotScaled() {
        var mia = F.member("Mia", allocation: 50)
        mia.openTaskTargetOverride = 4
        mia.capacityHoursOverride = 30
        #expect(M.target(F.board(), mia) == 4)
        #expect(M.target(F.board(hours: true), mia) == 30)
    }

    @Test func zeroTargetIsNoCapacityNotNaN() throws {
        let idle = F.member("Idle", allocation: 0)
        let s = F.board([idle], [F.card(F.doing, idle)])
        #expect(try row(s, idle).utilisation == .noCapacity(load: 1))
    }

    @Test func bandEdges80And100Inclusive() {
        #expect(M.utilisation(load: 4, target: 5).band == .green)
        #expect(M.utilisation(load: 5, target: 5).band == .amber)
        #expect(M.utilisation(load: 5.0001, target: 5).band == .red)
        #expect(M.utilisation(load: 0.8 * 3, target: 3).band == .green, "floating-point 0.8 stays green")
    }

    @Test func weightCriticalHighIsMax2() {
        var s = F.board()
        var c = F.card()
        #expect(M.weight(s, c) == 1)
        c.isCritical = true
        c.priority = TaskPriority.high.rawValue
        #expect(M.weight(s, c) == 1, "weighting is off by default")
        s.weightedLoad = true
        #expect(M.weight(s, c) == 2)
        c.isCritical = false
        #expect(M.weight(s, c) == 1.5)
        c.priority = TaskPriority.medium.rawValue
        #expect(M.weight(s, c) == 1)
    }

    @Test func hoursModeUsesDefaultEstimate() {
        #expect(M.measure(F.board(hours: true), F.card()) == 4)
        #expect(M.measure(F.board(), F.card(hours: 12)) == 1, "count mode ignores estimates")
    }

    @Test func explicitZeroEstimateIsZero() {
        #expect(M.measure(F.board(hours: true), F.card(hours: 0)) == 0)
    }

    // MARK: - (1) Load vs capacity

    @Test func hoursModeUsesCurrentWeekHours() throws {
        let ravi = F.member("Ravi")
        // Mon 12 – Fri 23: from today (Wed) that's 3 work days this week and 5 next.
        let s = F.board([ravi], [F.card(F.doing, ravi, start: F.date(10, 12), due: F.date(10, 23), hours: 16)], hours: true)
        let r = try row(s, ravi)
        #expect(close(r.load, 6) && r.target == 40)
    }

    @Test func backlogCoverageSeparate() throws {
        let ravi = F.member("Ravi")
        let s = F.board([ravi], [F.card(F.doing, ravi, start: F.date(10, 12), due: F.date(10, 23), hours: 16)], hours: true)
        let r = try row(s, ravi)
        #expect(r.backlogCoverageWeeks == 0.4)
        #expect(r.utilisation.flatMap(\.value).map { close($0, 6.0 / 40) } == true, "the band uses this week's hours")
        #expect(try row(F.board([ravi], []), ravi).backlogCoverageWeeks == nil, "count mode has no coverage")
    }

    @Test func stacksOnlyNonDoneColumnsInBoardOrder() throws {
        let ravi = F.member("Ravi")
        let s = F.board([ravi], [F.card(F.review, ravi), F.card(F.review, ravi), F.card(F.done, ravi)])
        let r = try row(s, ravi)
        #expect(r.segments.map(\.column) == [F.backlog, F.doing, F.review])
        #expect(r.segments.map(\.load) == [0, 0, 2] && r.load == 2)
    }

    @Test func filtersEmploymentAndAssignment() {
        let ravi = F.member("Ravi"), mia = F.member("Mia", employment: .contractor, assignment: .partTime)
        let s = F.board([ravi, mia])
        #expect(M.loadVsCapacity(s, filter: .init(employment: [.contractor])).map(\.memberID) == [nil, mia.id])
        #expect(M.loadVsCapacity(s, filter: .init(assignment: [.fullTime])).map(\.memberID) == [nil, ravi.id])
        #expect(M.loadVsCapacity(s, filter: .init(employment: [])).isEmpty)
    }

    @Test func unassignedRowHasNoTarget() throws {
        let s = F.board([], [F.card(F.doing), F.card(F.backlog)])
        let unassigned = try #require(M.loadVsCapacity(s).first)
        #expect(unassigned.memberID == nil && unassigned.load == 2 && unassigned.target == nil && unassigned.utilisation == nil)
    }

    @Test func archivedResourceExcluded() {
        var gone = F.member("Gone")
        gone.archived = true
        #expect(M.loadVsCapacity(F.board([gone])).map(\.memberID) == [nil])
    }

    // MARK: - Drag preview

    private let ravi = F.member("Ravi"), mia = F.member("Mia")

    @Test func dragInAddsOnlyUncounted() {
        let mine = F.card(F.doing, ravi), loose = F.card()
        let s = F.board([ravi], [mine, loose])
        #expect(M.projectedLoad(s, member: ravi, dragged: [mine.id, loose.id], toColumn: F.doing, toResource: ravi.id).load == 2)
    }

    @Test func dragOutSubtracts() {
        let mine = F.card(F.doing, ravi)
        let s = F.board([ravi, mia], [mine])
        #expect(M.projectedLoad(s, member: ravi, dragged: [mine.id], toColumn: F.doing, toResource: mia.id).load == 0)
        #expect(M.projectedLoad(s, member: mia, dragged: [mine.id], toColumn: F.doing, toResource: mia.id).load == 1)
    }

    @Test func dropIntoDoneSubtracts() {
        let mine = F.card(F.doing, ravi)
        let s = F.board([ravi], [mine])
        let p = M.projectedLoad(s, member: ravi, dragged: [mine.id], toColumn: F.done, toResource: ravi.id)
        #expect(p.load == 0 && p.target == 5)
    }

    @Test func sameResourceSameColumnIsZeroDelta() {
        let mine = F.card(F.doing, ravi)
        let s = F.board([ravi], [mine, F.card(F.review, ravi)])
        #expect(M.projectedLoad(s, member: ravi, dragged: [mine.id], toColumn: F.doing, toResource: ravi.id).load == 2)
    }

    @Test func multiSelectionMixedOwners() {
        let a = F.card(F.doing, ravi), b = F.card(F.doing, mia), c = F.card(F.done, mia)
        let s = F.board([ravi, mia], [a, b, c])
        let drag: Set = [a.id, b.id, c.id]
        #expect(M.projectedLoad(s, member: ravi, dragged: drag, toColumn: F.review, toResource: ravi.id).load == 3)
        #expect(M.projectedLoad(s, member: mia, dragged: drag, toColumn: F.review, toResource: ravi.id).load == 0)
    }

    @Test func hoursPreviewUsesThisWeeksShare() {
        let next = F.card(F.backlog, nil, start: F.date(10, 19), due: F.date(10, 20), hours: 8)
        let now = F.card(F.backlog, nil, due: F.date(10, 16), hours: 6)
        let s = F.board([ravi], [next, now], hours: true)
        #expect(M.projectedLoad(s, member: ravi, dragged: [next.id, now.id], toColumn: F.doing, toResource: ravi.id).load == 6)
    }

    // MARK: - (2) Capacity heatmap

    @Test func noDatesCurrentWeek() { #expect(weeks(F.board(), F.card()) == [1, 0, 0]) }

    @Test func dueOnlyDueWeek() { #expect(weeks(F.board(), F.card(due: F.date(10, 28))) == [0, 0, 1]) }

    @Test func startOnlyPastSpansToCurrentWeek() {
        #expect(weeks(F.board(), F.card(start: F.date(9, 30))) == [1, 0, 0])
        #expect(weeks(F.board(hours: true), F.card(start: F.date(9, 30), hours: 6)) == [6, 0, 0])
    }

    @Test func startOnlyFutureIsStartWeek() { #expect(weeks(F.board(), F.card(start: F.date(10, 21))) == [0, 1, 0]) }

    @Test func overdueClampedToCurrentWeek() {
        #expect(weeks(F.board(), F.card(due: F.date(10, 1))) == [1, 0, 0])
        #expect(weeks(F.board(hours: true), F.card(start: F.date(9, 1), due: F.date(10, 1), hours: 20)) == [20, 0, 0])
    }

    @Test func dueBeforeStartSwappedReachesLaterEndpoint() {
        #expect(weeks(F.board(), F.card(start: F.date(10, 30), due: F.date(10, 20))) == [0, 1, 1])
    }

    @Test func doneTasksExcluded() throws {
        let s = F.board([ravi], [F.card(F.done, ravi), F.card(F.doing, ravi)])
        let cells = try #require(M.capacityHeatmap(s, weeks: 2).first).weeks
        #expect(cells == [.ratio(load: 1, target: 5, .green), .ratio(load: 0, target: 5, .green)])
    }

    @Test func hoursSpreadAcrossWorkDays() {
        // Wed 14 – Tue 20: Wed, Thu, Fri this week, Mon, Tue next.
        let w = weeks(F.board(hours: true), F.card(start: F.date(10, 14), due: F.date(10, 20), hours: 10))
        #expect(close(w[0], 6) && close(w[1], 4) && w[2] == 0)
        #expect(close(w.reduce(0, +), 10), "the hours are spread, never copied")
    }

    @Test func weekendOnlyWindowGoesToEndWeek() {
        #expect(weeks(F.board(hours: true), F.card(start: F.date(10, 24), due: F.date(10, 25), hours: 8)) == [0, 8, 0])
    }

    @Test func resourceStartsMidWeekProRated3of5() throws {
        var starter = F.member("Starter")
        starter.startDate = F.date(10, 21)
        let cells = try #require(M.capacityHeatmap(F.board([starter]), weeks: 3).first).weeks
        #expect(cells == [.unavailable(load: 0), .ratio(load: 0, target: 3, .green), .ratio(load: 0, target: 5, .green)])
    }

    @Test func endedResourceCellUnavailableFlagsLoad() throws {
        var leaver = F.member("Leaver")
        leaver.endDate = F.date(10, 9)
        let cells = try #require(M.capacityHeatmap(F.board([leaver], [F.card(F.doing, leaver)]), weeks: 2).first).weeks
        #expect(cells == [.unavailable(load: 1), .unavailable(load: 0)])
    }

    @Test func emptyWorkWeekNoCapacity() throws {
        var s = F.board([ravi], [F.card(F.doing, ravi, hours: 4)], hours: true)
        s.workWeekDays = []
        #expect(try #require(M.capacityHeatmap(s, weeks: 2).first).weeks == [.noCapacity, .noCapacity])
        #expect(try row(s, ravi).load == 4, "with no work days the hours land in the end week")
    }

    @Test func heatmapWeeksAreClampedTo1Through26() throws {
        let s = F.board([ravi])
        #expect(try #require(M.capacityHeatmap(s, weeks: 0).first).weeks.count == 1)
        #expect(try #require(M.capacityHeatmap(s, weeks: 99).first).weeks.count == 26)
    }

    @Test func sundayWeekStart() {
        let sunday = F.calendar(firstWeekday: 1)
        let card = F.card(due: F.date(10, 18, cal: sunday))
        #expect(weeks(F.board(cal: sunday), card) == [0, 1, 0], "Sun 18 starts the next week")
        #expect(weeks(F.board(), card) == [1, 0, 0], "and ends this one when weeks start Monday")
    }

    @Test func dstChangeKeepsWholeDays() {
        // The clocks go back on Sun 25 October; the next week still has five work days.
        let w = weeks(F.board(hours: true), F.card(start: F.date(10, 26), due: F.date(10, 30), hours: 10))
        #expect(w == [0, 0, 10])
        let la = F.calendar(zone: "America/Los_Angeles")
        let laWeeks = weeks(F.board(hours: true, cal: la, now: F.date(10, 14, cal: la)),
                            F.card(start: F.date(10, 30, cal: la), due: F.date(11, 3, cal: la), hours: 6), 4)
        #expect(laWeeks == [0, 0, 2, 4], "Fri 30 Oct, then Mon 2 and Tue 3 Nov, across the US change")
    }

    // MARK: - (3) Composition

    private func contractor(_ name: String, endingIn days: Int) -> MetricsSnapshot.Member {
        var m = F.member(name, employment: .contractor)
        m.endDate = F.calendar().date(byAdding: .day, value: days, to: F.now)
        return m
    }

    @Test func gridCountsAndHours() {
        let half = F.member("Half", allocation: 50, assignment: .partTime)
        let c = M.composition(F.board([F.member("A"), F.member("B"), half, contractor("C", endingIn: 200)]))
        #expect(c.grid[.fte]?[.fullTime] == .init(count: 2, hours: 80))
        #expect(c.grid[.fte]?[.partTime] == .init(count: 1, hours: 20))
        #expect(c.grid[.contractor]?[.fullTime] == .init(count: 1, hours: 40))
        #expect(c.grid[.contractor]?[.partTime] == .init(count: 0, hours: 0))
    }

    @Test func notStartedListedSeparately() {
        var future = F.member("Future")
        future.startDate = F.date(10, 15)
        let c = M.composition(F.board([future]))
        #expect(c.notStarted == [future.id] && c.grid[.fte]?[.fullTime]?.count == 0)
    }

    @Test func rollOffBucketsDisjoint() {
        let ms = [30, 31, 60, 61, 90, 91].map { contractor("C\($0)", endingIn: $0) }
        let c = M.composition(F.board(ms, [F.card(F.doing, ms[0]), F.card(F.done, ms[0])]))
        #expect(c.rollOff[30]?.map(\.daysLeft) == [30] && c.rollOff[60]?.map(\.daysLeft) == [31, 60])
        #expect(c.rollOff[90]?.map(\.daysLeft) == [61, 90])
        #expect(c.rollOff[30]?.first?.openCards == 1)
    }

    @Test func endTodayIsBucket0() {
        let c = M.composition(F.board([contractor("Today", endingIn: 0)]))
        #expect(c.rollOff[30]?.map(\.daysLeft) == [0])
    }

    @Test func fteNeverInRollOff() {
        var fte = F.member("FTE")
        fte.endDate = F.date(10, 20)
        let none = M.composition(F.board([fte])).rollOff.values.allSatisfy { $0.isEmpty }
        #expect(none)
    }

    // MARK: - (3b) People rollup

    /// One person on several boards, with one 30-hour card due this week on each.
    private func shared(_ allocations: [Int], hours: [Bool], name: String = "Ravi") -> [MetricsSnapshot] {
        let person = UUID()
        let members = allocations.map { F.member(name, allocation: $0, person: person) }
        let boards = zip(members, hours).map { m, h in
            F.board([m], [F.card(F.doing, m, start: F.date(10, 12), due: F.date(10, 16), hours: 30)], hours: h)
        }
        return boards
    }

    @Test func allHoursBoardsBandUsesHours() throws {
        let boards = shared([50, 50], hours: [true, true])
        let p = try #require(M.peopleRollup(boards).first)
        #expect(p.hours == .init(load: 60, target: 40, utilisation: .ratio(1.5, .red)))
        #expect(p.count == .init(load: 2, target: 5, utilisation: .ratio(0.4, .green)))
        #expect(p.headline.band == .red && p.boards.count == 2)
    }

    @Test func mixedModesBandUsesCounts() throws {
        let boards = shared([50, 50], hours: [true, false])
        let p = try #require(M.peopleRollup(boards).first)
        #expect(p.hours == nil && p.headline == p.count.utilisation)
    }

    @Test func countNumeratorIndependentOfHoursBoards() throws {
        let boards = shared([50, 50], hours: [true, false])
        #expect(try #require(M.peopleRollup(boards).first).count.load == 2, "one card per board, not 30 h + 1")
    }

    @Test func combinedCountIsSumOfBoards() throws {
        var boards = shared([50, 50], hours: [false, false])
        boards[1].cards.append(F.card(F.review, boards[1].members[0]))
        let p = try #require(M.peopleRollup(boards).first)
        #expect(p.count.load == 3 && p.count.target == 5)
        #expect(p.boards.map(\.row.load) == [1, 2])
    }

    @Test func perBoardWeightingRespected() throws {
        var boards = shared([50, 50], hours: [false, false])
        for i in boards.indices { boards[i].cards[0].isCritical = true }
        boards[0].weightedLoad = true
        #expect(try #require(M.peopleRollup(boards).first).count.load == 3)
    }

    @Test func totalAllocationOver100Warns() throws {
        let boards = shared([60, 50], hours: [false, false])
        let p = try #require(M.peopleRollup(boards).first)
        #expect(p.totalAllocation == 110 && p.overAllocated)
        let exact = shared([50, 50], hours: [false, false])
        #expect(try #require(M.peopleRollup(exact).first).overAllocated == false)
    }

    @Test func endedMembershipExcluded() throws {
        var boards = shared([50, 50], hours: [false, false])
        boards[1].members[0].endDate = F.date(10, 13)
        let p = try #require(M.peopleRollup(boards).first)
        #expect(p.totalAllocation == 50 && p.boards.count == 1)
    }

    @Test func archivedProjectExcluded() throws {
        var boards = shared([50, 50], hours: [false, false])
        boards[0].projectArchived = true
        #expect(try #require(M.peopleRollup(boards).first).boards.map(\.projectID) == [boards[1].projectID])
        for i in boards.indices { boards[i].members[0].archived = true }
        #expect(M.peopleRollup(boards).isEmpty, "a person with no active memberships isn't listed")
    }

    @Test func zeroTargetNoCapacity() throws {
        let boards = shared([0], hours: [false])
        #expect(try #require(M.peopleRollup(boards).first).headline == .noCapacity(load: 1))
    }

    @Test func orderMostOverFirst() {
        let light = shared([100], hours: [false], name: "Light")
        let heavy = shared([10], hours: [false], name: "Heavy")
        let none = shared([0], hours: [false], name: "None")
        var empty = F.board([F.member("Empty", allocation: 0)])
        empty.projectName = "Empty"
        #expect(M.peopleRollup(light + heavy + none + [empty]).map(\.name) == ["None", "Heavy", "Light", "Empty"])
    }

    // MARK: - (4) By column and by resource

    @Test func includesDoneExcludesArchived() {
        var archived = F.card(F.done)
        archived.archived = true
        let byColumn = M.tasksByColumn(F.board([], [F.card(F.done), F.card(F.done), archived, F.card()]))
        #expect(byColumn.map(\.count) == [1, 0, 0, 2])
    }

    @Test func unassignedBucket() {
        let byResource = M.tasksByResource(F.board([ravi], [F.card(), F.card(F.doing, ravi)]))
        #expect(byResource[nil] == [F.backlog: 1] && byResource[ravi.id] == [F.doing: 1])
    }

    @Test func unweightedEvenWhenToggleOn() {
        var s = F.board([ravi], [F.card(F.doing, ravi)])
        s.weightedLoad = true
        s.cards[0].isCritical = true
        #expect(M.tasksByColumn(s)[1].load == 1 && M.tasksByResource(s)[ravi.id] == [F.doing: 1])
        #expect(M.priorityMatrix(s)[.critical] == [F.doing: 1])
    }

    // MARK: - (5) Unassigned backlog

    @Test func oldestFirstTieById() {
        let a = F.card(created: F.date(10, 5)), b = F.card(created: F.date(10, 2)), c = F.card(created: F.date(10, 5))
        let backlog = M.unassignedBacklog(F.board([ravi], [a, b, c, F.card(F.doing), F.card(F.backlog, ravi)]))
        #expect(backlog.items == [b.id] + [a, c].map(\.id).sorted { $0.uuidString < $1.uuidString })
        #expect(backlog.unassignedActiveCount == 1)
    }

    @Test func readyRequiresNotBlockedAndDepsDone() {
        let finished = F.card(F.done), pending = F.card(F.doing)
        var ready = F.card(), waiting = F.card(), blocked = F.card()
        ready.dependsOn = [finished.id]
        waiting.dependsOn = [finished.id, pending.id]
        blocked.isBlocked = true
        let backlog = M.unassignedBacklog(F.board([], [finished, pending, ready, waiting, blocked]))
        #expect(backlog.ready == [ready.id])
    }

    @Test func deletedDepDropsOut() {
        var card = F.card()
        card.dependsOn = [UUID()]
        #expect(M.unassignedBacklog(F.board([], [card])).ready == [card.id])
    }

    @Test func archivedDepBlocksWithRemedy() {
        var prerequisite = F.card(F.done)
        prerequisite.archived = true
        var card = F.card()
        card.dependsOn = [prerequisite.id]
        let backlog = M.unassignedBacklog(F.board([], [prerequisite, card]))
        #expect(backlog.ready.isEmpty && backlog.waitingOnArchived == [card.id])
    }

    @Test func multiLabelCountsPerLabel() {
        let feature = UUID(), bug = UUID()
        var both = F.card(), one = F.card()
        both.labels = [feature, bug]
        one.labels = [bug]
        var critical = F.card()
        critical.isCritical = true
        critical.priority = 2
        let backlog = M.unassignedBacklog(F.board([], [both, one, F.card(), critical]))
        #expect(backlog.byLabel == [feature: 1, bug: 2, nil: 2])
        #expect(backlog.byPriority == [.critical: 1, .high: 0, .medium: 0, .low: 3])
    }

    // MARK: - (6) Priority matrix, (7) label mix

    @Test func criticalRowExclusive() {
        var critical = F.card(F.doing)
        critical.isCritical = true
        critical.priority = 2
        var high = F.card(F.doing)
        high.priority = 2
        let matrix = M.priorityMatrix(F.board([], [critical, high]))
        #expect(matrix[.critical] == [F.doing: 1] && matrix[.high] == [F.doing: 1])
    }

    @Test func rowTotalsEqualColumnTotals() {
        let cards = (0..<12).map { i in
            var c = F.card(F.columns[i % 4].id)
            c.priority = i % 3
            c.isCritical = i % 5 == 0
            return c
        }
        let s = F.board([], cards)
        let matrix = M.priorityMatrix(s)
        for column in M.tasksByColumn(s) {
            #expect(matrix.values.reduce(0) { $0 + ($1[column.column] ?? 0) } == Double(column.count))
        }
    }

    @Test func multiLabelCountedOncePerLabel() {
        let feature = UUID(), bug = UUID()
        var both = F.card(F.doing)
        both.labels = [feature, bug]
        #expect(M.labelMix(F.board([], [both]))[F.doing] == [feature: 1, bug: 1])
    }

    @Test func unlabelledBucket() {
        #expect(M.labelMix(F.board([], [F.card(F.doing), F.card(F.doing)]))[F.doing] == [nil: 2])
    }

    // MARK: - (8) Blocked

    @Test func fallbackUpdatedAtThenCreatedAt() {
        var card = F.card(F.doing, created: F.date(10, 4))
        card.isBlocked = true
        card.updatedAt = F.date(10, 10)
        #expect(M.blockedTasks(F.board([], [card])).map(\.ageDays) == [4])
    }

    @Test func blankReasonPlaceholder() {
        var blank = F.card(F.doing, created: F.date(10, 4)), reasoned = F.card(F.doing, created: F.date(10, 12))
        blank.isBlocked = true
        blank.blockedReason = "  \n"
        reasoned.isBlocked = true
        reasoned.blockedReason = " Waiting on API "
        let blocked = M.blockedTasks(F.board([], [reasoned, blank]))
        #expect(blocked.map(\.reason) == ["No reason given", "Waiting on API"], "oldest first")
    }

    @Test func doneBlockedExcluded() {
        var card = F.card(F.done)
        card.isBlocked = true
        #expect(M.blockedTasks(F.board([], [card])).isEmpty)
    }

    @Test func ageFromLatestBlockedActivity() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: KanbanHistory())
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let card = try service.createTask(in: project, title: "Card", column: project.orderedColumns[1])
        func edit(_ blocked: Bool, at date: Date) throws {
            try service.edit(card, [.isBlocked: .bool(blocked)])
            let entry = try #require(project.activities.max { $0.seq < $1.seq })
            entry.at = date
        }
        try edit(true, at: F.date(10, 2))
        let first = MetricsSnapshot(project: project, now: F.now, calendar: F.calendar())
        #expect(M.blockedTasks(first).map(\.ageDays) == [12])

        // reblockResetsAge
        try edit(false, at: F.date(10, 5))
        try edit(true, at: F.date(10, 11))
        let again = MetricsSnapshot(project: project, now: F.now, calendar: F.calendar())
        #expect(M.blockedTasks(again).map(\.ageDays) == [3])
    }

    // MARK: - (9) Due dates

    @Test func bucketsMutuallyExclusive() {
        let cards = [F.date(10, 1), F.date(10, 14), F.date(10, 18), F.date(10, 19), F.date(10, 25), F.date(10, 26)].map { F.card(due: $0) }
        let due = M.dueBuckets(F.board([], cards))
        #expect(due.overdue == [cards[0].id] && due.thisWeek == [cards[1].id, cards[2].id] && due.nextWeek == [cards[3].id, cards[4].id])
        #expect(Set(due.overdue + due.thisWeek + due.nextWeek).count == 5)
    }

    @Test func earlierThisWeekIsOverdue() {
        let mondayCard = F.card(due: F.date(10, 12))
        #expect(M.dueBuckets(F.board([], [mondayCard])).overdue == [mondayCard.id])
    }

    @Test func dueTodayIsThisWeek() {
        let today = F.card(due: F.date(10, 14, 0))
        #expect(M.dueBuckets(F.board([], [today])).thisWeek == [today.id])
    }

    @Test func lateEveningDueUsesLocalDay() {
        let yesterdayLate = F.card(due: F.date(10, 13, 23, minute: 30)), tonight = F.card(due: F.date(10, 14, 23, minute: 30))
        let due = M.dueBuckets(F.board([], [yesterdayLate, tonight]))
        #expect(due.overdue == [yesterdayLate.id] && due.thisWeek == [tonight.id])
    }

    @Test func overdueGroupedByResource() {
        let older = F.card(F.doing, ravi, due: F.date(10, 1)), newer = F.card(F.doing, ravi, due: F.date(10, 9))
        let loose = F.card(due: F.date(10, 5))
        let due = M.dueBuckets(F.board([ravi], [newer, loose, older]))
        #expect(due.overdue == [older.id, loose.id, newer.id], "most overdue first")
        #expect(due.overdueByResource == [ravi.id: [older.id, newer.id], nil: [loose.id]])
    }

    @Test func doneNeverOverdue() {
        #expect(M.dueBuckets(F.board([], [F.card(F.done, due: F.date(10, 1))])).overdue.isEmpty)
    }

    // MARK: - (13) Hygiene

    @Test func hygieneChecks() {
        var good = F.card(F.doing, ravi, due: F.date(10, 20), hours: 2)
        good.jiraURL = "https://jira.example.com/browse/PLAT-1"
        var bad = F.card(F.doing, ravi)
        bad.jiraURL = "PLAT-2"
        bad.subtasksTotal = 2
        bad.subtasksDone = 2
        var finished = F.card(F.done)
        finished.subtasksTotal = 2
        finished.subtasksDone = 1
        var leaver = F.member("Leaver")
        leaver.endDate = F.date(10, 1)
        leaver.archived = true
        let idle = F.member("Idle")
        var s = F.board([ravi, idle, leaver], [good, bad, finished, F.card(F.doing, leaver)], hours: true)
        let h = M.hygieneReport(s)
        #expect(Set(h.missingDue) == Set([bad.id, s.cards[3].id]) && Set(h.missingJira) == Set([bad.id, s.cards[3].id]))
        #expect(Set(h.missingEstimate) == Set([bad.id, s.cards[3].id]))
        #expect(h.subtasksDoneNotDone == [bad.id] && h.doneWithOpenSubtasks == [finished.id])
        #expect(h.idleResources == [idle.id] && h.pastEndHoldingWork == [leaver.id], "archived memberships included")
        s.loadMeasure = .taskCount
        #expect(M.hygieneReport(s).missingEstimate.isEmpty)
    }

    // MARK: - All projects overview and the builder

    @Test func projectSummary() {
        var leaving = contractor("Mia", endingIn: 10)
        leaving.allocationPercent = 20
        let s = F.board([ravi, leaving], [
            F.card(F.doing, ravi, due: F.date(10, 1)), F.card(F.doing, leaving), F.card(F.review, leaving), F.card(F.done, ravi),
        ])
        let summary = M.summary(s)
        #expect(summary.load == 3 && summary.target == 6 && summary.utilisation == .ratio(0.5, .green))
        #expect(summary.openCards == 3 && summary.doneCards == 1 && summary.overdue == 1)
        #expect(summary.rollingOffWithin30Days == 1 && summary.membersOverCapacity == 1)
    }

    @Test func snapshotFromABoard() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: KanbanHistory())
        let project = try service.createProject(name: "Platform", key: "PLAT")
        let person = try service.createPerson(name: "Mia", initials: "MI", employment: .contractor)
        let mia = try service.addMembership(person, to: project, allocationPercent: 50, assignment: .partTime)
        let card = try service.createTask(in: project, title: "Card", column: project.orderedColumns[1], row: .resource(mia.id))
        try service.setLabels(card, Array(project.labels.prefix(2)))
        _ = try service.addSubtask(to: card, title: "Step")
        let s = MetricsSnapshot(project: project, now: F.now, calendar: F.calendar())
        #expect(s.columns.map(\.kind) == [.backlog, .active, .done])
        #expect(s.members == [.init(id: mia.id, personID: person.id, name: "Mia", employment: .contractor, assignment: .partTime,
                                    allocationPercent: 50)])
        let snap = try #require(s.cards.first)
        #expect(snap.column == project.orderedColumns[1].id && snap.resource == mia.id && snap.labels.count == 2)
        #expect(snap.subtasksTotal == 1 && snap.subtasksDone == 0)
        #expect(M.loadVsCapacity(s).last?.load == 1)
    }

    // MARK: - Performance

    @Test func metricsBudgetReferenceFixture() {
        let members = (0..<20).map { F.member("M\($0)", allocation: $0 % 4 == 0 ? 50 : 100) }
        var columns = F.columns
        columns.insert(contentsOf: (0..<6).map { .init(id: UUID(), name: "Stage \($0)", kind: .active) }, at: 2)
        let labels = (0..<7).map { _ in UUID() }
        let cards = (0..<500).map { i -> MetricsSnapshot.Card in
            var c = F.card(columns[i % columns.count].id, i % 7 == 0 ? nil : members[i % 20],
                           start: i % 3 == 0 ? F.date(10, 1 + i % 28) : nil, due: i % 2 == 0 ? F.date(11, 1 + i % 28) : nil,
                           hours: Double(i % 9))
            c.labels = [labels[i % 7]]
            c.isBlocked = i % 11 == 0
            return c
        }
        var s = F.board(members, cards, hours: true)
        s.columns = columns
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = M.loadVsCapacity(s)
            _ = M.capacityHeatmap(s, weeks: 12)
            _ = M.composition(s)
            _ = M.peopleRollup([s, s])
            _ = M.tasksByColumn(s)
            _ = M.tasksByResource(s)
            _ = M.unassignedBacklog(s)
            _ = M.priorityMatrix(s)
            _ = M.labelMix(s)
            _ = M.blockedTasks(s)
            _ = M.dueBuckets(s)
            _ = M.hygieneReport(s)
            _ = M.summary(s)
        }
        #if DEBUG
        #expect(elapsed < .milliseconds(300), "Debug canary: \(elapsed)")
        #else
        #expect(elapsed < .milliseconds(100), "\(elapsed)")
        #endif
    }
}
