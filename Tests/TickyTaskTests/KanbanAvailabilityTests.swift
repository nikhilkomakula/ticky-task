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

    @Test("Older change-log entries (payload v1, no availability key) still read")
    func olderPayloads() throws {
        let v1 = Data(#"{"version":1,"transitions":[],"changes":[]}"#.utf8)
        let payload = try KanbanActivityPayload.decode(v1)
        #expect(payload.availability == nil && payload.version == 1)
        let delta = try JSONDecoder().decode(KanbanAvailabilityDelta.self, from: Data("{}".utf8))
        #expect(delta.isEmpty)
    }
}
