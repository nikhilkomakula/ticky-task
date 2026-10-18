import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Availability through backups, board files and CSV (design 03): carried in full, older files
/// still read, and imports never duplicate or overwrite what's already recorded.
@MainActor
@Suite("Kanban availability export and import", .serialized)
struct KanbanAvailabilityTransferTests {
    private func source() throws -> (KanbanService, ModelContext, KanbanProject, KanbanPerson, KanbanResource) {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "Platform", key: "PLAT", startDay: "20261005", endDay: "20261127")
        let ravi = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        let membership = try s.addMembership(ravi, to: board)
        try s.addTimeOff(KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261022"), on: board)
        try s.addTimeOff(KanbanTimeOffDTO(personId: ravi.id, startDay: "20261105", endDay: "20261105", portion: .pm, kind: .training), on: board)
        try s.addTimeOff(KanbanTimeOffDTO(personId: ravi.id, startDay: "20270301", endDay: "20270302"), on: board)   // outside the board
        try s.setOverride(membership, week: KanbanDay(key: "20261012")!, halfDays: 6, note: "Conference")
        ravi.aliases = ["Ravi"]
        try context.save()
        return (s, context, board, ravi, membership)
    }

    @Test("A full backup carries board dates, time off, overrides and remembered names, and restores them")
    func fullBackup() throws {
        let (_, context, _, _, _) = try source()
        let snapshot = try BackupStore.makeSnapshot(context: context)
        let data = try BackupCoding.encoder().encode(snapshot)
        let decoded = try BackupCoding.decoder().decode(BackupStoreDTO.self, from: data)
        #expect(decoded.kanban?.version == 3)
        let fresh = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        try BackupStore.restore(decoded, context: fresh)
        let board = try #require(try fresh.fetch(FetchDescriptor<KanbanProject>()).first)
        #expect(board.startDay == "20261005" && board.endDay == "20261127")
        let ravi = try #require(try fresh.fetch(FetchDescriptor<KanbanPerson>()).first)
        #expect(ravi.timeOff.count == 3 && ravi.aliases == ["Ravi"])
        #expect(ravi.memberships.first?.availabilityOverrides.first?.halfDays == 6)
    }

    @Test("A version-1 backup (no availability keys) still decodes and restores")
    func olderBackup() throws {
        let (_, context, _, _, _) = try source()
        let snapshot = try BackupStore.makeSnapshot(context: context)
        var json = try #require(try JSONSerialization.jsonObject(with: try BackupCoding.encoder().encode(snapshot)) as? [String: Any])
        var kanban = try #require(json["kanban"] as? [String: Any])
        kanban["version"] = 1
        kanban.removeValue(forKey: "timeOff")
        kanban.removeValue(forKey: "availabilityOverrides")
        kanban["projects"] = (kanban["projects"] as? [[String: Any]])?.map { p in p.filter { !["startDay", "endDay"].contains($0.key) } }
        kanban["people"] = (kanban["people"] as? [[String: Any]])?.map { p in p.filter { $0.key != "aliases" } }
        json["kanban"] = kanban
        let old = try BackupCoding.decoder().decode(BackupStoreDTO.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(old.kanban?.timeOff == nil)
        let fresh = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        try BackupStore.restore(old, context: fresh)
        #expect(try fresh.fetchCount(FetchDescriptor<KanbanProject>()) == 1)
        #expect(try fresh.fetchCount(FetchDescriptor<KanbanTimeOff>()) == 0)
    }

    @Test("The validator refuses availability that points nowhere or isn't real")
    func validation() throws {
        let (_, context, _, _, _) = try source()
        var kanban = try KanbanBackupDTO.snapshot(context: context)
        kanban.timeOff?[0].personId = UUID()
        #expect(throws: BackupError.self) { try KanbanBackupValidator.validate(kanban) }
        kanban = try KanbanBackupDTO.snapshot(context: context)
        kanban.availabilityOverrides?[0].weekStart = "20261013"   // a Tuesday
        #expect(throws: BackupError.self) { try KanbanBackupValidator.validate(kanban) }
        kanban = try KanbanBackupDTO.snapshot(context: context)
        kanban.projects[0].endDay = "20260101"
        #expect(throws: BackupError.self) { try KanbanBackupValidator.validate(kanban) }
    }

    @Test("A board file carries dates, overrides and the time off overlapping the board; importing it twice adds nothing twice")
    func boardFile() throws {
        let (_, context, board, _, _) = try source()
        let file = try KanbanBoardTransfer.export([board], context: context)
        let envelope = try BackupCoding.decoder().decode(KanbanBoardTransfer.Envelope.self, from: file)
        #expect(envelope.version == 3)
        #expect(envelope.kanban.timeOff?.count == 2, "the March entry is outside the board's dates")
        #expect(envelope.kanban.availabilityOverrides?.count == 1)

        let other = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s2 = KanbanService(other)
        let here = try s2.createPerson(name: "Ravi Kumar", initials: "RK")   // a different id, matched by name
        try other.save()
        let plan = try KanbanBoardTransfer.plan(file, context: other)
        #expect(plan.people.first?.linkTo == here.id)
        let imported = try KanbanBoardTransfer.apply(plan, fileName: "f", context: other)
        #expect(imported.first?.startDay == "20261005")
        #expect(here.timeOff.count == 2, "time off goes to the person it was matched to")
        #expect(imported.first?.resources.first?.availabilityOverrides.count == 1)

        // Into the same store again, as a new board: the person's time off is already there.
        let again = try KanbanBoardTransfer.plan(file, context: other)
        try KanbanBoardTransfer.apply(again, fileName: "f", context: other)
        #expect(here.timeOff.count == 2)
    }

    @Test("Merging keeps the board's dates unless asked, and keeps an existing override for the same week")
    func merge() throws {
        let (_, context, board, _, _) = try source()
        let file = try KanbanBoardTransfer.export([board], context: context)
        let other = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s2 = KanbanService(other, history: KanbanHistory())
        let target = try s2.createProject(name: "Target", key: "TGT", startDay: "20260101", endDay: nil)
        let ravi = try s2.createPerson(name: "Ravi Kumar", initials: "RK")
        let membership = try s2.addMembership(ravi, to: target)
        try s2.setOverride(membership, week: KanbanDay(key: "20261012")!, halfDays: 2)
        var plan = try KanbanBoardTransfer.plan(file, context: other)
        plan.boards[0].mergeInto = target.id
        try KanbanBoardTransfer.apply(plan, fileName: "f", context: other)
        #expect(target.startDay == "20260101" && target.endDay == nil, "dates kept")
        #expect(membership.availabilityOverrides.count == 1 && membership.availabilityOverrides.first?.halfDays == 2, "existing override kept")

        var withDates = try KanbanBoardTransfer.plan(file, context: other)
        withDates.boards[0].mergeInto = target.id
        withDates.boards[0].useImportedDates = true
        try KanbanBoardTransfer.apply(withDates, fileName: "f", context: other)
        #expect(target.startDay == "20261005" && target.endDay == "20261127")
    }

    @Test("A version-1 board file (no availability) still imports")
    func olderBoardFile() throws {
        let (_, context, board, _, _) = try source()
        let file = try KanbanBoardTransfer.export([board], context: context)
        var json = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        json["version"] = 1
        var kanban = try #require(json["kanban"] as? [String: Any])
        kanban["version"] = 1
        kanban.removeValue(forKey: "timeOff")
        kanban.removeValue(forKey: "availabilityOverrides")
        json["kanban"] = kanban
        let other = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let imported = try KanbanBoardTransfer.apply(try KanbanBoardTransfer.plan(try JSONSerialization.data(withJSONObject: json), context: other),
                                                     fileName: "f", context: other)
        let timeOff = try other.fetchCount(FetchDescriptor<KanbanTimeOff>())
        #expect(imported.count == 1 && timeOff == 0)
    }

    @Test("The availability CSV has one row per member and week, with the worked-out and overridden days")
    func csv() throws {
        let (_, _, board, _, _) = try source()
        let weeks = KanbanAvailability.window(board: KanbanAvailability.Board(board), today: KanbanDay(key: "20261020")!)
        let lines = KanbanAvailabilityCSV.csv(board, weeks: weeks, calendar: .current).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == weeks.count + 1)
        #expect(lines[0].contains("Week start") && lines[0].contains("Holiday days"))
        let overridden = try #require(lines.first { $0.contains(",2026-10-12,") }).components(separatedBy: ",")
        #expect(overridden[3] == "Ravi Kumar" && overridden[7] == "5" && overridden[9] == "3" && overridden[10] == "3" && overridden[12] == "overridden")
        let off = try #require(lines.first { $0.contains(",2026-10-19,") }).components(separatedBy: ",")
        #expect(off[8] == "2" && off[9] == "" && off[10] == "2" && off[11] == "100", "Tue–Thu off leaves 2 of 5")
    }

    @Test("The availability CSV includes holiday days in the last column")
    func csvWithHolidays() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "Platform", key: "PLAT", startDay: "20261005", endDay: "20261127")
        let ravi = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        let membership = try s.addMembership(ravi, to: board)
        // Add a holiday on a work day (Monday 19 Oct 2026)
        try s.addHoliday(KanbanHolidayDTO(day: "20261019", name: "Thanksgiving", portion: .full), on: board)
        try context.save()
        let weeks = KanbanAvailability.window(board: KanbanAvailability.Board(board), today: KanbanDay(key: "20261020")!)
        let lines = KanbanAvailabilityCSV.csv(board, weeks: weeks, calendar: .current).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines[0].contains("Holiday days"))
        let holiday = try #require(lines.first { $0.contains(",2026-10-19,") }).components(separatedBy: ",")
        // 5 work days in week, 1 is a holiday → possible 4, holiday days 1
        #expect(holiday[7] == "4", "Possible days (without the holiday)")
        #expect(holiday[13] == "1", "Holiday days column")
    }

    @Test("Import conflicts are counted for the preview and keep what's here unless the file's version is chosen")
    func conflicts() throws {
        let (_, context, board, ravi, _) = try source()
        let file = try KanbanBoardTransfer.export([board], context: context)
        // Same store, merged back into the same board: change one entry and one override here first.
        let entry = try #require(ravi.timeOff.first { $0.startDay == "20261020" })
        entry.kindRaw = KanbanTimeOffKind.sick.rawValue
        let override = try #require(ravi.memberships.first?.availabilityOverrides.first)
        override.halfDays = 2
        try context.save()
        var plan = try KanbanBoardTransfer.plan(file, context: context)
        plan.boards[0].mergeInto = board.id
        let people = try context.fetch(FetchDescriptor<KanbanPerson>())
        let projects = try context.fetch(FetchDescriptor<KanbanProject>())
        let conflicts = plan.availabilityConflicts(projects: projects, people: people)
        #expect(conflicts.timeOff == 1 && conflicts.overrides == 1)
        try KanbanBoardTransfer.apply(plan, fileName: "f", context: context)
        #expect(entry.kind == .sick && override.halfDays == 2, "kept by default")

        var incoming = try KanbanBoardTransfer.plan(file, context: context)
        incoming.boards[0].mergeInto = board.id
        incoming.useIncomingTimeOff = true
        incoming.useIncomingOverrides = true
        try KanbanBoardTransfer.apply(incoming, fileName: "f", context: context)
        #expect(entry.kind == .pto && override.halfDays == 6)
        #expect(ravi.timeOff.count == 3, "nothing duplicated")
    }

    @Test("Importing a board that already has someone's time off adopts it: an older entry elsewhere can't revert it unnoticed")
    func adoption() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let a = try s.createProject(name: "A", key: "AAA", startDay: "20261005", endDay: "20261127")
        let ravi = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        _ = try s.addMembership(ravi, to: a)
        try s.addTimeOff(KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020"), on: a)
        let added = try #require(a.activities.max { $0.seq < $1.seq })
        let file = try KanbanBoardTransfer.export([a], context: context)
        try KanbanBoardTransfer.apply(try KanbanBoardTransfer.plan(file, context: context), fileName: "f", context: context)
        #expect(ravi.timeOff.count == 1)
        #expect(throws: KanbanServiceError.self) { try s.revert(added) }
        #expect(ravi.timeOff.count == 1)
    }

    @Test("Two incoming overrides for the same person and week count as a conflict, notes included")
    func incomingOverrideConflicts() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "A", key: "AAA")
        let one = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        let two = try s.createPerson(name: "Ravi K", initials: "RK")
        let m1 = try s.addMembership(one, to: board), m2 = try s.addMembership(two, to: board)
        try s.setOverride(m1, week: KanbanDay(key: "20261019")!, halfDays: 4)
        try s.setOverride(m2, week: KanbanDay(key: "20261019")!, halfDays: 4, note: "Offsite")
        let file = try KanbanBoardTransfer.export([board], context: context, timeOffRange: ("20261001", "20261231"))
        let other = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let here = try KanbanService(other).createPerson(name: "Ravi Kumar", initials: "RK")
        try other.save()
        var plan = try KanbanBoardTransfer.plan(file, context: other)
        for index in plan.people.indices { plan.people[index].linkTo = here.id }   // both onto one person
        #expect(plan.availabilityConflicts(projects: [], people: [here]).overrides == 1)
    }

    @Test("Week labels use Gregorian months whatever calendar the Mac uses")
    func labels() {
        #expect(KanbanAvailabilityFormat.week(KanbanDay(key: "20261019")!).hasPrefix("19–25 "))
        #expect(KanbanAvailabilityFormat.calendar.identifier == .gregorian)
    }

    @Test("An undated board's default export range starts at its start (or this week) and stops at its end")
    func defaultRange() {
        let today = KanbanDay(key: "20261021")!
        #expect(KanbanBoardTransfer.defaultTimeOffRange(startDay: nil, endDay: nil, today: today) == ("20261019", "20270110"))
        #expect(KanbanBoardTransfer.defaultTimeOffRange(startDay: "20270104", endDay: nil, today: today).start == "20270104")
        #expect(KanbanBoardTransfer.defaultTimeOffRange(startDay: nil, endDay: "20261106", today: today) == ("20261019", "20261106"))
    }

    @Test("A full backup carries holidays and restores them")
    func fullBackupWithHolidays() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "Platform", key: "PLAT", startDay: "20261005", endDay: "20261127")
        let ravi = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        _ = try s.addMembership(ravi, to: board)
        try s.addHoliday(KanbanHolidayDTO(day: "20261026", name: "Thanksgiving"), on: board)
        let holiday = try #require(try context.fetch(FetchDescriptor<KanbanHoliday>()).first)
        try s.setWorks(ravi, holiday: holiday, works: true, on: board)
        try context.save()

        let snapshot = try BackupStore.makeSnapshot(context: context)
        #expect(snapshot.kanban?.version == 3)
        #expect(snapshot.kanban?.holidays?.count == 1)
        let data = try BackupCoding.encoder().encode(snapshot)
        let decoded = try BackupCoding.decoder().decode(BackupStoreDTO.self, from: data)
        let fresh = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        try BackupStore.restore(decoded, context: fresh)
        let holidays = try fresh.fetch(FetchDescriptor<KanbanHoliday>())
        #expect(holidays.count == 1)
        #expect(holidays[0].day == "20261026" && holidays[0].name == "Thanksgiving")
        #expect(holidays[0].workedBy?.contains(ravi.id) ?? false)
    }

    @Test("A version-2 backup (no holidays) still decodes and restores")
    func olderBackupNoHolidays() throws {
        let (_, context, _, _, _) = try source()
        let snapshot = try BackupStore.makeSnapshot(context: context)
        var json = try #require(try JSONSerialization.jsonObject(with: try BackupCoding.encoder().encode(snapshot)) as? [String: Any])
        var kanban = try #require(json["kanban"] as? [String: Any])
        kanban["version"] = 2
        kanban.removeValue(forKey: "holidays")
        json["kanban"] = kanban
        let old = try BackupCoding.decoder().decode(BackupStoreDTO.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(old.kanban?.holidays == nil)
        let fresh = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        try BackupStore.restore(old, context: fresh)
        #expect(try fresh.fetchCount(FetchDescriptor<KanbanProject>()) == 1)
        #expect(try fresh.fetchCount(FetchDescriptor<KanbanHoliday>()) == 0)
    }

    @Test("The validator refuses holidays that are invalid or reference unknown people")
    func holidayValidation() throws {
        let (_, context, _, _, _) = try source()
        let ravi = try #require(try context.fetch(FetchDescriptor<KanbanPerson>()).first)
        var kanban = try KanbanBackupDTO.snapshot(context: context)
        kanban.holidays = [KanbanHolidayDTO(day: "20261026", name: "Thanksgiving", workedBy: [ravi.id])]
        try KanbanBackupValidator.validate(kanban)
        kanban.holidays = [KanbanHolidayDTO(day: "invalid", name: "Bad")]
        #expect(throws: BackupError.self) { try KanbanBackupValidator.validate(kanban) }
        kanban.holidays = [KanbanHolidayDTO(day: "20261026", name: "", workedBy: [ravi.id])]
        #expect(throws: BackupError.self) { try KanbanBackupValidator.validate(kanban) }
        kanban.holidays = [KanbanHolidayDTO(day: "20261026", name: "Good", workedBy: [UUID()])]
        #expect(throws: BackupError.self) { try KanbanBackupValidator.validate(kanban) }
    }

    @Test("A board file carries holidays in the date range and imports them")
    func boardFileWithHolidays() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "Platform", key: "PLAT", startDay: "20261005", endDay: "20261127")
        let ravi = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        _ = try s.addMembership(ravi, to: board)
        try s.addHoliday(KanbanHolidayDTO(day: "20261026", name: "Thanksgiving"), on: board)
        try s.addHoliday(KanbanHolidayDTO(day: "20270301", name: "Spring Equinox"), on: board)   // outside the board
        try context.save()

        let file = try KanbanBoardTransfer.export([board], context: context)
        let envelope = try BackupCoding.decoder().decode(KanbanBoardTransfer.Envelope.self, from: file)
        #expect(envelope.version == 3)
        #expect(envelope.kanban.holidays?.count == 1, "March entry is outside board dates")
        #expect(envelope.kanban.holidays?.first?.day == "20261026")

        let other = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s2 = KanbanService(other)
        let here = try s2.createPerson(name: "Ravi Kumar", initials: "RK")
        try other.save()
        let plan = try KanbanBoardTransfer.plan(file, context: other)
        let imported = try KanbanBoardTransfer.apply(plan, fileName: "f", context: other)
        let holidays = try other.fetch(FetchDescriptor<KanbanHoliday>())
        #expect(holidays.count == 1 && holidays[0].day == "20261026" && holidays[0].name == "Thanksgiving")
    }

    @Test("Importing a board with holidays twice adds nothing twice")
    func holidayImportIdempotent() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "Platform", key: "PLAT", startDay: "20261005", endDay: "20261127")
        let ravi = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        _ = try s.addMembership(ravi, to: board)
        try s.addHoliday(KanbanHolidayDTO(day: "20261026", name: "Thanksgiving"), on: board)
        try context.save()

        let file = try KanbanBoardTransfer.export([board], context: context)
        let other = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s2 = KanbanService(other)
        try s2.createPerson(name: "Ravi Kumar", initials: "RK")
        try other.save()

        let plan1 = try KanbanBoardTransfer.plan(file, context: other)
        try KanbanBoardTransfer.apply(plan1, fileName: "f", context: other)
        #expect(try other.fetchCount(FetchDescriptor<KanbanHoliday>()) == 1)

        let plan2 = try KanbanBoardTransfer.plan(file, context: other)
        try KanbanBoardTransfer.apply(plan2, fileName: "f", context: other)
        #expect(try other.fetchCount(FetchDescriptor<KanbanHoliday>()) == 1)
    }

    @Test("A version-2 board file (no holidays) still imports")
    func olderBoardFileNoHolidays() throws {
        let (_, context, board, _, _) = try source()
        let file = try KanbanBoardTransfer.export([board], context: context)
        var json = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        json["version"] = 2
        var kanban = try #require(json["kanban"] as? [String: Any])
        kanban["version"] = 2
        kanban.removeValue(forKey: "holidays")
        json["kanban"] = kanban
        let other = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let imported = try KanbanBoardTransfer.apply(try KanbanBoardTransfer.plan(try JSONSerialization.data(withJSONObject: json), context: other),
                                                     fileName: "f", context: other)
        let holidays = try other.fetchCount(FetchDescriptor<KanbanHoliday>())
        #expect(imported.count == 1 && holidays == 0)
    }

    @Test("Adoption protection: importing a board's holiday twice stops older change-log from deleting it")
    func holidayAdoption() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "A", key: "AAA", startDay: "20261005", endDay: "20261127")
        let ravi = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        _ = try s.addMembership(ravi, to: board)
        try s.addHoliday(KanbanHolidayDTO(day: "20261026", name: "Thanksgiving"), on: board)
        let added = try #require(board.activities.max { $0.seq < $1.seq })
        try context.save()

        let file = try KanbanBoardTransfer.export([board], context: context)
        try KanbanBoardTransfer.apply(try KanbanBoardTransfer.plan(file, context: context), fileName: "f", context: context)
        #expect(try context.fetchCount(FetchDescriptor<KanbanHoliday>()) == 1)
        #expect(throws: KanbanServiceError.self) { try s.revert(added) }
        #expect(try context.fetchCount(FetchDescriptor<KanbanHoliday>()) == 1)
    }

    @Test("Deleting a person removes them from all holidays' workedBy lists")
    func personDeletionRemovesFromHolidays() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "Board", key: "BRD")
        let ravi = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        let sita = try s.createPerson(name: "Sita", initials: "ST")
        _ = try s.addMembership(ravi, to: board)
        try s.addHoliday(KanbanHolidayDTO(day: "20261026", name: "Thanksgiving", workedBy: [ravi.id, sita.id]), on: board)
        let holiday = try #require(try context.fetch(FetchDescriptor<KanbanHoliday>()).first)
        #expect(holiday.workedBy?.count == 2)
        try context.save()

        try s.deletePerson(sita)   // Ravi is still on the board, so only Sita can go
        #expect(holiday.workedBy == [ravi.id])
    }

    @Test("Holiday exceptions follow the people they were matched to; the file's version keeps exceptions it can't know; holidays can be left out")
    func holidayExceptionsAcrossStores() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "Platform", key: "PLAT", startDay: "20261005", endDay: "20261127")
        let ravi = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        _ = try s.addMembership(ravi, to: board)
        try s.addHoliday(KanbanHolidayDTO(day: "20261026", name: "Diwali", workedBy: [ravi.id]), on: board)
        let file = try KanbanBoardTransfer.export([board], context: context)

        let other = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s2 = KanbanService(other, history: KanbanHistory())
        let target = try s2.createProject(name: "Here", key: "HERE")
        let here = try s2.createPerson(name: "Ravi Kumar", initials: "RK")   // another id, matched by name
        let mia = try s2.createPerson(name: "Mia Chen", initials: "MC")     // not in the file
        try s2.addHoliday(KanbanHolidayDTO(day: "20261026", name: "Diwali", workedBy: [mia.id]), on: target)
        let local = try #require(try other.fetch(FetchDescriptor<KanbanHoliday>()).first)

        var skip = try KanbanBoardTransfer.plan(file, context: other)
        #expect(skip.holidayChanges(here: [local], people: [here, mia]) == (0, 1), "same day and name, different exceptions")
        skip.importHolidays = false
        skip.useIncomingHolidays = true
        try KanbanBoardTransfer.apply(skip, fileName: "f", context: other)
        #expect(local.workedBy == [mia.id], "left out entirely")

        var incoming = try KanbanBoardTransfer.plan(file, context: other)
        incoming.useIncomingHolidays = true
        try KanbanBoardTransfer.apply(incoming, fileName: "f", context: other)
        #expect(Set(local.workedBy ?? []) == [here.id, mia.id], "Ravi's exception mapped here; Mia's kept")
        #expect(try other.fetchCount(FetchDescriptor<KanbanHoliday>()) == 1)
    }
}
