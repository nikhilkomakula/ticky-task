import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Weekly availability (design 03): days, weeks, half days, overlaps, ranges, overrides,
/// the 60 % bands and the window.
@Suite("Kanban availability arithmetic")
struct KanbanAvailabilityTests {
    private func day(_ key: String) -> KanbanDay { KanbanDay(key: key)! }
    private let weekdays: Set<Int> = [2, 3, 4, 5, 6]

    private func member(_ absences: [KanbanAvailability.Absence] = [], start: String? = nil, end: String? = nil,
                        overrides: [KanbanDay: Int] = [:]) -> KanbanAvailability.Member {
        .init(resourceID: UUID(), start: start.map(day), end: end.map(day), absences: absences, overrides: overrides)
    }

    private func off(_ start: String, _ end: String, _ portion: KanbanTimeOffPortion = .full) -> KanbanAvailability.Absence {
        .init(id: UUID(), start: day(start), end: day(end), portion: portion)
    }

    @Test("Day keys: only real days, Mondays, weekdays and arithmetic across months and years")
    func days() {
        #expect(KanbanDay(key: "20261019")?.key == "20261019")
        #expect(KanbanDay(key: "20260231") == nil && KanbanDay(key: "2026-10-19") == nil && KanbanDay(key: "abc") == nil)
        #expect(day("20261019").weekday == 2, "19 Oct 2026 is a Monday")
        #expect(day("20261025").monday == day("20261019") && day("20261019").monday == day("20261019"))
        #expect(day("20261230").adding(days: 3) == day("20270102"))
        #expect(day("20261019").days(to: day("20261102")) == 14)
    }

    @Test("A full week is 5 of 5; a full day off takes one day, a morning half of one")
    func basics() {
        let board = KanbanAvailability.Board(start: nil, end: nil, workWeekDays: weekdays)
        let week = day("20261019")
        #expect(KanbanAvailability.cell(week: week, board: board, member: member()).effectiveHalfDays == 10)
        let oneDay = KanbanAvailability.cell(week: week, board: board, member: member([off("20261021", "20261021")]))
        #expect(oneDay.effectiveHalfDays == 8 && oneDay.possibleHalfDays == 10)
        let afternoon = KanbanAvailability.cell(week: week, board: board, member: member([off("20261022", "20261022", .pm)]))
        #expect(KanbanAvailability.days(afternoon.effectiveHalfDays) == "4.5")
        // A range across a weekend counts only work days.
        let across = KanbanAvailability.cell(week: week, board: board, member: member([off("20261023", "20261027")]))
        #expect(across.effectiveHalfDays == 8, "only Friday falls in this week")
    }

    @Test("Overlapping and duplicate time off counts once; morning and afternoon make a day")
    func overlaps() {
        let board = KanbanAvailability.Board(start: nil, end: nil, workWeekDays: weekdays)
        let cell = KanbanAvailability.cell(week: day("20261019"), board: board, member: member([
            off("20261020", "20261021"), off("20261021", "20261021"), off("20261022", "20261022", .am), off("20261022", "20261022", .pm),
        ]))
        #expect(cell.absentHalfDays == 6, "Tue, Wed and Thu once each")
        #expect(cell.absenceIDs.count == 4)
    }

    @Test("Board and membership dates shorten the week; outside them a week shows nothing")
    func ranges() {
        let board = KanbanAvailability.Board(start: day("20261021"), end: nil, workWeekDays: weekdays)
        let partial = KanbanAvailability.cell(week: day("20261019"), board: board, member: member())
        #expect(partial.possibleHalfDays == 6 && partial.band == .green, "3 of 3 is green")
        let before = KanbanAvailability.cell(week: day("20261012"), board: board, member: member())
        #expect(!before.isActive && before.band == nil)
        let leaving = KanbanAvailability.cell(week: day("20261026"), board: board, member: member(end: "20261027"))
        #expect(leaving.possibleHalfDays == 4)
        let noWorkDays = KanbanAvailability.cell(week: day("20261019"), board: .init(start: nil, end: nil, workWeekDays: []), member: member())
        #expect(!noWorkDays.isActive)
    }

    @Test("Bands are scaled to the week: above 60 % green, exactly 60 % yellow, below red")
    func bands() {
        #expect(KanbanAvailability.band(10, of: 10) == .green && KanbanAvailability.band(7, of: 10) == .green)
        #expect(KanbanAvailability.band(6, of: 10) == .yellow, "3 of 5")
        #expect(KanbanAvailability.band(5, of: 10) == .red, "2.5 of 5")
        #expect(KanbanAvailability.band(0, of: 10) == .red && KanbanAvailability.band(0, of: 0) == nil)
        #expect(KanbanAvailability.band(6, of: 6) == .green, "a full 3-day week")
    }

    @Test("Team bands: 5*available ≥ 4*possible green, 5*available ≥ 3*possible amber, else red")
    func teamBands() {
        // Green: 5*available >= 4*possible (80% and above, floored)
        #expect(KanbanAvailability.teamBand(available: 100, possible: 100) == .green, "5*100 >= 4*100")
        #expect(KanbanAvailability.teamBand(available: 80, possible: 100) == .green, "5*80 >= 4*100")
        #expect(KanbanAvailability.teamBand(available: 40, possible: 50) == .green, "5*40 >= 4*50")
        // Amber: 5*available >= 3*possible but < 4*possible (60–79%, floored)
        #expect(KanbanAvailability.teamBand(available: 79, possible: 100) == .yellow, "5*79 < 4*100, >= 3*100")
        #expect(KanbanAvailability.teamBand(available: 60, possible: 100) == .yellow, "5*60 >= 3*100")
        #expect(KanbanAvailability.teamBand(available: 39, possible: 50) == .yellow, "78%: 5*39 >= 3*50")
        #expect(KanbanAvailability.teamBand(available: 30, possible: 50) == .yellow, "60%: 5*30 >= 3*50")
        // Red: 5*available < 3*possible (below 60%)
        #expect(KanbanAvailability.teamBand(available: 59, possible: 100) == .red, "5*59 < 3*100")
        #expect(KanbanAvailability.teamBand(available: 0, possible: 100) == .red)
        #expect(KanbanAvailability.teamBand(available: 29, possible: 50) == .red, "58%: 5*29 < 3*50")
        // Boundary: 79.6% displays as "79%" amber (not green)
        #expect(KanbanAvailability.teamBand(available: 398, possible: 500) == .yellow, "398/500 = 79.6%, 5*398 = 1990 < 4*500 = 2000")
        // Nil when no work days
        #expect(KanbanAvailability.teamBand(available: 0, possible: 0) == nil)
        #expect(KanbanAvailability.percent(398, of: 500) == 79 && KanbanAvailability.percent(299, of: 500) == 59, "floored, never rounded up")
    }

    @Test("An override replaces the week; one above the possible days needs review and isn't used")
    func overrides() {
        let week = day("20261019")
        let board = KanbanAvailability.Board(start: nil, end: nil, workWeekDays: weekdays)
        let set = KanbanAvailability.cell(week: week, board: board, member: member([off("20261020", "20261020")], overrides: [week: 5]))
        #expect(set.isOverridden && set.effectiveHalfDays == 5 && set.computedHalfDays == 8 && set.band == .red)
        let short = KanbanAvailability.Board(start: day("20261022"), end: nil, workWeekDays: weekdays)
        let stale = KanbanAvailability.cell(week: week, board: short, member: member(overrides: [week: 10]))
        #expect(stale.overrideNeedsReview && !stale.isOverridden && stale.effectiveHalfDays == 4)
    }

    @Test("The team total adds days, not percentages, and skips weeks nobody can work")
    func total() {
        let cells = [KanbanAvailability.Cell(possibleHalfDays: 10, absentHalfDays: 4, overrideHalfDays: nil, absenceIDs: []),
                     KanbanAvailability.Cell(possibleHalfDays: 4, absentHalfDays: 0, overrideHalfDays: nil, absenceIDs: []),
                     KanbanAvailability.Cell(possibleHalfDays: 0, absentHalfDays: 0, overrideHalfDays: nil, absenceIDs: [])]
        #expect(KanbanAvailability.total(cells)! == (10, 14))
        #expect(KanbanAvailability.total([]) == nil)
    }

    @Test("Days convert in Gregorian terms whatever calendar the Mac uses")
    func calendars() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let date = buddhist.date(from: DateComponents(year: 2569, month: 10, day: 19, hour: 9))!   // 19 Oct 2026
        #expect(KanbanDay(date, calendar: buddhist) == day("20261019"))
        #expect(KanbanDay(day("20261019").date(in: buddhist), calendar: buddhist) == day("20261019"))
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = TimeZone(identifier: "UTC")!
        #expect(KanbanDay(day("20260320").utcDate, calendar: hebrew) == day("20260320"), "no crash on a 13-month year")
    }

    @Test("The arrows move an open window from where it starts, never past its bound")
    func shifting() {
        let today = day("20261021")
        let future = KanbanAvailability.Board(start: day("20270104"), end: nil, workWeekDays: weekdays)
        #expect(KanbanAvailability.window(board: future, today: today, shift: 4).first == day("20270201"), "one click moves it")
        #expect(KanbanAvailability.window(board: future, today: today, shift: -4).first == day("20270104"))
        let past = KanbanAvailability.Board(start: nil, end: day("20260306"), workWeekDays: weekdays)
        #expect(KanbanAvailability.window(board: past, today: today, shift: -4).last == day("20260202"))
        #expect(KanbanAvailability.window(board: past, today: today, shift: 4).last == day("20260302"))
    }

    @Test("The window: every week of a dated board; otherwise 12 weeks kept inside the set bound")
    func window() {
        let today = day("20261021")
        let dated = KanbanAvailability.window(board: .init(start: day("20261001"), end: day("20261231"), workWeekDays: weekdays), today: today)
        #expect(dated.first == day("20260928") && dated.last == day("20261228") && dated.count == 14)
        let open = KanbanAvailability.window(board: .init(start: nil, end: nil, workWeekDays: weekdays), today: today)
        #expect(open.first == day("20261019") && open.count == 12)
        let started = KanbanAvailability.window(board: .init(start: day("20261102"), end: nil, workWeekDays: weekdays), today: today, shift: -5)
        #expect(started.first == day("20261102"), "can't go before the start")
        let ending = KanbanAvailability.window(board: .init(start: nil, end: day("20261106"), workWeekDays: weekdays), today: today)
        #expect(ending.last == day("20261102") && ending.count == 12)
    }
}

/// Time off, overrides and board dates through the service: one undoable entry each, global
/// time off checked across boards.
@MainActor
@Suite("Kanban availability service", .serialized)
struct KanbanAvailabilityServiceTests {
    private func setup() throws -> (KanbanService, KanbanProject, KanbanProject, KanbanPerson, KanbanResource, ModelContext) {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let platform = try s.createProject(name: "Platform", key: "PLAT")
        let data = try s.createProject(name: "Data", key: "DATA")
        let ravi = try s.createPerson(name: "Ravi", initials: "RV")
        let membership = try s.addMembership(ravi, to: platform)
        _ = try s.addMembership(ravi, to: data)
        return (s, platform, data, ravi, membership, context)
    }

    @Test("Adding, editing and removing time off are each undoable; time off belongs to the person")
    func timeOff() throws {
        let (s, platform, _, ravi, _, _) = try setup()
        try s.addTimeOff(KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261021"), on: platform)
        #expect(ravi.timeOff.count == 1)
        let entry = try #require(ravi.timeOff.first)
        var changed = KanbanTimeOffDTO(entry)
        changed.endDay = "20261023"
        try s.editTimeOff(entry, to: changed, on: platform)
        #expect(entry.endDay == "20261023")
        try s.undo(in: platform)
        #expect(entry.endDay == "20261021")
        try s.redo(in: platform)
        #expect(entry.endDay == "20261023")
        try s.deleteTimeOff([entry], on: platform)
        #expect(ravi.timeOff.isEmpty)
        try s.undo(in: platform)
        #expect(ravi.timeOff.first?.endDay == "20261023", "the same entry comes back")
    }

    @Test("Bad time off is refused before anything changes")
    func validation() throws {
        let (s, platform, _, ravi, _, _) = try setup()
        for bad in [KanbanTimeOffDTO(personId: ravi.id, startDay: "20261024", endDay: "20261020"),
                    KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261021", portion: .am),
                    KanbanTimeOffDTO(personId: ravi.id, startDay: "20260231", endDay: "20260301"),
                    KanbanTimeOffDTO(personId: UUID(), startDay: "20261020", endDay: "20261020")] {
            #expect(throws: KanbanServiceError.self) { try s.addTimeOff(bad, on: platform) }
        }
        #expect(ravi.timeOff.isEmpty)
    }

    @Test("Undo refuses when the time off was changed again from another board")
    func crossBoardConflict() throws {
        let (s, platform, data, ravi, _, _) = try setup()
        try s.addTimeOff(KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020"), on: platform)
        let entry = try #require(ravi.timeOff.first)
        var later = KanbanTimeOffDTO(entry)
        later.kindRaw = KanbanTimeOffKind.sick.rawValue
        try s.editTimeOff(entry, to: later, on: data)
        #expect(throws: KanbanServiceError.self) { try s.undo(in: platform) }
        #expect(entry.kind == .sick)
    }

    @Test("Overrides: one per week, set, changed and cleared, each undoable; Mondays only")
    func overrides() throws {
        let (s, platform, _, _, membership, _) = try setup()
        let monday = KanbanDay(key: "20261019")!
        try s.setOverride(membership, week: monday, halfDays: 6, note: "Conference")
        try s.setOverride(membership, week: monday, halfDays: 4)
        #expect(membership.availabilityOverrides.count == 1 && membership.availabilityOverrides.first?.halfDays == 4)
        try s.undo(in: platform)
        #expect(membership.availabilityOverrides.first?.halfDays == 6)
        try s.setOverride(membership, week: monday, halfDays: nil)
        #expect(membership.availabilityOverrides.isEmpty)
        #expect(throws: KanbanServiceError.self) { try s.setOverride(membership, week: KanbanDay(key: "20261020")!, halfDays: 4) }
        #expect(throws: KanbanServiceError.self) { try s.setOverride(membership, week: monday, halfDays: 15) }
    }

    @Test("Board dates: set and cleared in one undoable edit; an end before the start is refused")
    func boardDates() throws {
        let (s, platform, _, _, _, _) = try setup()
        try s.editBoardDetails(platform, name: "Platform", startDay: "20261001", endDay: "20261231")
        #expect(platform.startDay == "20261001" && platform.endDay == "20261231")
        try s.editBoardDetails(platform, name: "Platform v2", startDay: nil, endDay: "20261231")
        #expect(platform.startDay == nil && platform.name == "Platform v2")
        try s.undo(in: platform)
        #expect(platform.startDay == "20261001" && platform.name == "Platform")
        #expect(throws: KanbanServiceError.self) { try s.editBoardDetails(platform, name: "P", startDay: "20261231", endDay: "20261001") }
        let dated = try s.createProject(name: "Dated", key: "DTD", startDay: "20261005", endDay: nil)
        #expect(dated.startDay == "20261005")
    }

    @Test("Time off goes with the person; overrides go with the membership; a board delete keeps time off")
    func deletion() throws {
        let (s, platform, data, ravi, membership, context) = try setup()
        try s.addTimeOff(KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020"), on: platform)
        try s.setOverride(membership, week: KanbanDay(key: "20261019")!, halfDays: 6)
        try s.deleteProject(platform)
        #expect(try context.fetchCount(FetchDescriptor<KanbanAvailabilityOverride>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<KanbanTimeOff>()) == 1)
        _ = data
    }

    @Test("Revert can't leave a board's dates out of order, or delete a membership's overrides")
    func revertGuards() throws {
        let (s, platform, _, ravi, _, context) = try setup()
        try s.editBoardDetails(platform, name: "Platform", startDay: "20261010", endDay: "20261020")
        try s.editBoardDetails(platform, name: "Platform", startDay: "20261010", endDay: "20261030")
        let extension_ = try #require(platform.activities.max { $0.seq < $1.seq })
        try s.editBoardDetails(platform, name: "Platform", startDay: "20261025", endDay: "20261030")
        #expect(throws: KanbanServiceError.self) { try s.revert(extension_) }
        #expect(platform.startDay == "20261025" && platform.endDay == "20261030")

        let sam = try s.createPerson(name: "Sam", initials: "SA")
        let added = try s.addMembership(sam, to: platform)
        let addition = try #require(platform.activities.max { $0.seq < $1.seq })
        try s.setOverride(added, week: KanbanDay(key: "20261026")!, halfDays: 4)
        #expect(throws: KanbanServiceError.self) { try s.revert(addition) }
        #expect(try context.fetchCount(FetchDescriptor<KanbanAvailabilityOverride>()) == 1)
        _ = ravi
    }

    @Test("An override can't be more than the week's possible days")
    func overrideLimit() throws {
        let (s, platform, _, _, membership, _) = try setup()
        try s.editBoardDetails(platform, name: "Platform", startDay: "20261021", endDay: nil)
        #expect(throws: KanbanServiceError.self) { try s.setOverride(membership, week: KanbanDay(key: "20261019")!, halfDays: 8) }
        try s.setOverride(membership, week: KanbanDay(key: "20261019")!, halfDays: 6)
    }

    @Test("Older change-log entries (payload v1, no availability key) still read")
    func olderPayloads() throws {
        let v1 = Data(#"{"version":1,"transitions":[],"changes":[]}"#.utf8)
        let payload = try KanbanActivityPayload.decode(v1)
        #expect(payload.availability == nil && payload.version == 1)
        let delta = try JSONDecoder().decode(KanbanAvailabilityDelta.self, from: Data("{}".utf8))
        #expect(delta.isEmpty)
    }
}

extension KanbanAvailabilityTests {
    @Test("Holidays aren't working days: out of possible, never subtracted twice, PTO on them not counted, per-record exceptions")
    func holidays() {
        let week = day("20261123")   // Thanksgiving Thursday 26 Nov
        let board = KanbanAvailability.Board(start: nil, end: nil, workWeekDays: weekdays)
        let person = UUID()
        func h(_ key: String, _ portion: KanbanTimeOffPortion = .full, worked: Set<UUID> = []) -> KanbanAvailability.Holiday {
            .init(id: UUID(), day: day(key), portion: portion, workedBy: worked)
        }
        var m = member([off("20261126", "20261127")])
        m.personID = person
        let thanksgiving = h("20261126")
        let one = KanbanAvailability.cell(week: week, board: board, member: m, holidays: .init([thanksgiving]))
        #expect(one.possibleHalfDays == 8 && one.holidayHalfDays == 2 && one.absentHalfDays == 2, "4 working days, Friday off")
        #expect(one.effectiveHalfDays == 6 && one.band == .green && one.holidayIDs == [thanksgiving.id])
        let duplicate = KanbanAvailability.cell(week: week, board: board, member: m, holidays: .init([thanksgiving, h("20261126", .pm)]))
        #expect(duplicate.possibleHalfDays == 8 && duplicate.holidayHalfDays == 2, "overlapping holidays count once")
        let half = KanbanAvailability.cell(week: week, board: board, member: member(), holidays: .init([h("20261124", .pm)]))
        #expect(half.possibleHalfDays == 9 && half.effectiveHalfDays == 9)
        // Working one holiday doesn't exempt another on the same day.
        let works = KanbanAvailability.cell(week: week, board: board, member: m, holidays: .init([h("20261126", worked: [person])]))
        #expect(works.possibleHalfDays == 10 && works.absentHalfDays == 4 && works.holidayHalfDays == 0)
        let mixed = KanbanAvailability.cell(week: week, board: board, member: m,
                                            holidays: .init([h("20261126", worked: [person]), h("20261126", .am)]))
        #expect(mixed.possibleHalfDays == 9 && mixed.absentHalfDays == 3)
        // A weekend holiday only matters on a board that works weekends.
        let saturday = KanbanAvailability.Holidays([h("20261128")])
        #expect(KanbanAvailability.cell(week: week, board: board, member: member(), holidays: saturday).possibleHalfDays == 10)
        let sixDays = KanbanAvailability.Board(start: nil, end: nil, workWeekDays: weekdays.union([7]))
        #expect(KanbanAvailability.cell(week: week, board: sixDays, member: member(), holidays: saturday).possibleHalfDays == 10)
        // All work days are holidays: its own state, not "—".
        let shutdown = KanbanAvailability.Holidays(["20261123", "20261124", "20261125", "20261126", "20261127"].map { h($0) })
        let closed = KanbanAvailability.cell(week: week, board: board, member: member(), holidays: shutdown)
        #expect(!closed.isActive && closed.isAllHoliday && closed.band == nil)
        #expect(!KanbanAvailability.cell(week: day("20261019"), board: .init(start: nil, end: nil, workWeekDays: []), member: member()).isAllHoliday)
        // An override is capped by the holiday-aware possible days.
        var capped = member(overrides: [week: 10])
        capped.personID = person
        #expect(KanbanAvailability.cell(week: week, board: board, member: capped, holidays: .init([thanksgiving])).overrideNeedsReview)
        // The weekly total ignores holidays: everyone working all their working days is 100 %.
        let total = KanbanAvailability.total([one, KanbanAvailability.cell(week: week, board: board, member: member(), holidays: .init([thanksgiving])), closed])
        #expect(total.map { KanbanAvailability.percent($0.available, of: $0.possible) } == 87, "14 of 16 half days; the closed cell adds nothing")
    }

    @Test("VoiceOver says how many holiday days a week excludes, and names them")
    func spokenFormat() {
        let board = KanbanAvailability.Board(start: nil, end: nil, workWeekDays: weekdays)
        let week = day("20261123")
        func h(_ key: String, _ portion: KanbanTimeOffPortion = .full) -> KanbanAvailability.Holiday {
            .init(id: UUID(), day: day(key), portion: portion)
        }
        let plain = KanbanAvailability.cell(week: week, board: board, member: member())
        #expect(KanbanAvailabilityFormat.spoken(plain, timeOff: []) == "5 of 5 days available")
        let one = KanbanAvailability.cell(week: week, board: board, member: member(), holidays: .init([h("20261126")]))
        #expect(KanbanAvailabilityFormat.spoken(one, timeOff: [], holidays: ["Thanksgiving"])
                == "4 of 4 days available. 1 day of public holidays excluded (Thanksgiving)")
        let half = KanbanAvailability.cell(week: week, board: board, member: member(), holidays: .init([h("20261124", .pm)]))
        #expect(KanbanAvailabilityFormat.spoken(half, timeOff: [], holidays: ["Early close"]).hasSuffix("Half a day of public holidays excluded (Early close)"))
        let closed = KanbanAvailability.cell(week: week, board: board, member: member(),
                                             holidays: .init(["20261123", "20261124", "20261125", "20261126", "20261127"].map { h($0) }))
        #expect(KanbanAvailabilityFormat.spoken(closed, timeOff: []) == "Public holiday all week")
    }
}

extension KanbanAvailabilityServiceTests {
    @Test("Public holidays: add, edit, works-it and delete are each undoable, logged at payload v3")
    func holidays() throws {
        let (s, platform, _, ravi, _, context) = try setup()
        try s.addHoliday(KanbanHolidayDTO(day: "20261126", name: "Thanksgiving"), on: platform)
        let holiday = try #require(try context.fetch(FetchDescriptor<KanbanHoliday>()).first)
        let logged = try #require(platform.activities.max { $0.seq < $1.seq })
        #expect(try KanbanActivityPayload.decode(logged.payload).version == 3)
        try s.setWorks(ravi, holiday: holiday, works: true, on: platform)
        #expect(holiday.workedBy == [ravi.id])
        var moved = KanbanHolidayDTO(holiday)
        moved.day = "20261127"
        try s.editHoliday(holiday, to: moved, on: platform)
        #expect(holiday.day == "20261127" && holiday.workedBy == [ravi.id], "an edit keeps who works it")
        try s.undo(in: platform)
        #expect(holiday.day == "20261126")
        try s.undo(in: platform)
        #expect(holiday.workedBy == nil)
        try s.redo(in: platform)
        try s.deleteHolidays([holiday], on: platform)
        #expect(try context.fetchCount(FetchDescriptor<KanbanHoliday>()) == 0)
        try s.undo(in: platform)
        let back = try #require(try context.fetch(FetchDescriptor<KanbanHoliday>()).first)
        #expect(back.id == holiday.id && back.workedBy == [ravi.id], "the same holiday comes back with its exception")
    }

    @Test("Bad holidays are refused, unknown people included; undo after a deletion logs what it restores")
    func holidayValidation() throws {
        let (s, platform, _, ravi, _, context) = try setup()
        for bad in [KanbanHolidayDTO(day: "20260231", name: "Nope"), KanbanHolidayDTO(day: "20261126", name: "  ")] {
            #expect(throws: KanbanServiceError.self) { try s.addHoliday(bad, on: platform) }
        }
        #expect(throws: KanbanServiceError.self) {
            try s.addHoliday(KanbanHolidayDTO(day: "20261126", name: "Thanksgiving", workedBy: [ravi.id, UUID()]), on: platform)
        }
        #expect(try context.fetchCount(FetchDescriptor<KanbanHoliday>()) == 0)
        // Undo after the person is deleted brings the holiday back without them, and redo still matches.
        let sita = try s.createPerson(name: "Sita", initials: "ST")
        try s.addHoliday(KanbanHolidayDTO(day: "20261126", name: "Thanksgiving", workedBy: [ravi.id, sita.id]), on: platform)
        let holiday = try #require(try context.fetch(FetchDescriptor<KanbanHoliday>()).first)
        try s.deleteHolidays([holiday], on: platform)
        try s.deletePerson(sita)
        try s.undo(in: platform)
        let back = try #require(try context.fetch(FetchDescriptor<KanbanHoliday>()).first)
        #expect(back.workedBy == [ravi.id])
        try s.redo(in: platform)
        #expect(try context.fetchCount(FetchDescriptor<KanbanHoliday>()) == 0)
    }

    @Test("Undo refuses when the holiday was changed again from another board")
    func holidayCrossBoard() throws {
        let (s, platform, data, ravi, _, context) = try setup()
        try s.addHoliday(KanbanHolidayDTO(day: "20261126", name: "Thanksgiving"), on: platform)
        let holiday = try #require(try context.fetch(FetchDescriptor<KanbanHoliday>()).first)
        try s.setWorks(ravi, holiday: holiday, works: true, on: data)
        #expect(throws: KanbanServiceError.self) { try s.undo(in: platform) }
        #expect(try context.fetchCount(FetchDescriptor<KanbanHoliday>()) == 1)
    }

    @Test("Overrides are capped by the holiday-aware week, also when one change adds both")
    func holidayCapacity() throws {
        let (s, platform, _, _, membership, _) = try setup()
        let week = KanbanDay(key: "20261123")!
        try s.addHoliday(KanbanHolidayDTO(day: "20261126", name: "Thanksgiving"), on: platform)
        #expect(throws: KanbanServiceError.self) { try s.setOverride(membership, week: week, halfDays: 9) }
        try s.setOverride(membership, week: week, halfDays: 8)
        // Ten half days fit the week of 30 Nov until the same change closes its Monday.
        let closed = KanbanHolidayDTO(day: "20261130", name: "Closed")
        let override = KanbanAvailabilityOverrideDTO(id: UUID(), resourceId: membership.id, weekStart: "20261130", halfDays: 10,
                                                     note: nil, createdAt: Date(), updatedAt: Date())
        let both = KanbanAvailabilityDelta(overrides: [.init(id: override.id, before: nil, after: override)],
                                           holidays: [.init(id: closed.id, before: nil, after: closed)])
        #expect(throws: KanbanServiceError.self) { try s.applyAvailability(both, on: platform, summary: "x") }
        #expect(membership.availabilityOverrides.count == 1, "nothing from the refused change")
    }

    @Test("A failed holiday save changes nothing and logs nothing")
    func holidaySaveFailure() throws {
        let (s, platform, _, ravi, _, context) = try setup()
        try s.addHoliday(KanbanHolidayDTO(day: "20261126", name: "Thanksgiving"), on: platform)
        let holiday = try #require(try context.fetch(FetchDescriptor<KanbanHoliday>()).first)
        let entries = platform.activities.count
        defer { PersistenceFaults.armed = [] }
        PersistenceFaults.armed = [.transaction]
        #expect(throws: (any Error).self) { try s.setWorks(ravi, holiday: holiday, works: true, on: platform) }
        PersistenceFaults.armed = [.transaction]
        #expect(throws: (any Error).self) { try s.addHoliday(KanbanHolidayDTO(day: "20261127", name: "Day after"), on: platform) }
        let kept = try context.fetch(FetchDescriptor<KanbanHoliday>())
        #expect(kept.count == 1 && kept.first?.workedBy == nil)
        #expect(platform.activities.count == entries)
    }
}
