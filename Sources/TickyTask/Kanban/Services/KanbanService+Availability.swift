import Foundation
import SwiftData

/// Time off, weekly overrides, remembered names (design 03) and public holidays (design 04).
/// Time off belongs to the person and holidays to everyone, so one entry here can change every
/// board. Each action is one undoable entry on the
/// board where it was taken, holding the records' before and after states.
extension KanbanService {
    /// Applies `delta` as one entry on `project`: every record must still be as `before` says,
    /// and every `after` must be valid. Nothing is written when nothing changes.
    @discardableResult
    func applyAvailability(_ delta: KanbanAvailabilityDelta, on project: KanbanProject, summary: String) throws -> Bool {
        try RecurrenceMaterializer.checkpoint(context)
        let delta = delta.changesOnly
        guard !delta.isEmpty else { return false }
        let records = try availabilityRecords()
        guard records.matches(delta, before: true) else {
            throw KanbanServiceError.conflict("Time off changed while you were editing it. Try again.")
        }
        let resources = try context.fetch(FetchDescriptor<KanbanResource>())
        let plan = try records.plan(delta, resources: resources)
        try records.checkCapacity(delta, resources: resources)
        let data = try KanbanActivityPayload(availability: delta).encoded()
        plan.apply(context)
        try save(project, kind: .availability, taskIDs: [], summary: summary, encodedPayload: data)
        return true
    }

    /// The inverse of an availability entry: the records must still be as it left them (wherever
    /// they were edited since, on any board), then they go back.
    func availabilityInverse(_ payload: KanbanActivityPayload) throws -> Inverse {
        guard let delta = payload.availability else { throw KanbanServiceError.conflict("That entry can't be read.") }
        let records = try availabilityRecords()
        guard records.matches(delta, before: false) else {
            throw KanbanServiceError.conflict("That time off or availability was changed again afterwards (on this or another board). Revert the newer changes first.")
        }
        let reversed = delta.reversed
        let plan = try records.plan(reversed, resources: try context.fetch(FetchDescriptor<KanbanResource>()))
        return Inverse(kind: .availability, payload: KanbanActivityPayload(availability: reversed)) { [context] in plan.apply(context) }
    }

    // MARK: Conveniences

    func addTimeOff(_ entry: KanbanTimeOffDTO, on project: KanbanProject) throws {
        try applyAvailability(KanbanAvailabilityDelta(timeOff: [.init(id: entry.id, before: nil, after: entry)]), on: project,
                              summary: "Added time off for \(personName(entry.personId)) (\(Self.span(entry)))")
    }

    func editTimeOff(_ entry: KanbanTimeOff, to updated: KanbanTimeOffDTO, on project: KanbanProject) throws {
        var updated = updated
        updated.id = entry.id
        updated.createdAt = entry.createdAt
        updated.updatedAt = now()
        try applyAvailability(KanbanAvailabilityDelta(timeOff: [.init(id: entry.id, before: KanbanTimeOffDTO(entry), after: updated)]),
                              on: project, summary: "Changed time off for \(personName(updated.personId)) (\(Self.span(updated)))")
    }

    func deleteTimeOff(_ entries: [KanbanTimeOff], on project: KanbanProject) throws {
        guard let first = entries.first else { return }
        let name = personName(first.person?.id)
        try applyAvailability(KanbanAvailabilityDelta(timeOff: entries.map { .init(id: $0.id, before: KanbanTimeOffDTO($0), after: nil) }),
                              on: project, summary: entries.count == 1 ? "Removed time off for \(name) (\(Self.span(KanbanTimeOffDTO(first))))"
                                  : "Removed \(entries.count) time-off entries")
    }

    /// Sets (or, with nil, clears) a membership's available days for the week starting `monday`.
    func setOverride(_ resource: KanbanResource, week monday: KanbanDay, halfDays: Int?, note: String? = nil) throws {
        guard let project = resource.project else { throw KanbanServiceError.notFound }
        if let halfDays {
            let possible = KanbanAvailability.cell(week: monday, board: .init(project), member: .init(resource), holidays: try holidays()).possibleHalfDays
            guard halfDays <= possible else {
                throw KanbanServiceError.invariant("That week has \(KanbanAvailability.days(possible)) possible days on this board.")
            }
        }
        let existing = resource.availabilityOverrides.first { $0.weekStart == monday.key }
        let after = halfDays.map { value in
            KanbanAvailabilityOverrideDTO(id: existing?.id ?? UUID(), resourceId: resource.id, weekStart: monday.key, halfDays: value,
                                          note: note.flatMap { $0.isEmpty ? nil : $0 }, createdAt: existing?.createdAt ?? now(), updatedAt: now())
        }
        let id = existing?.id ?? after?.id ?? UUID()
        let week = Self.weekLabel(monday)
        try applyAvailability(KanbanAvailabilityDelta(overrides: [.init(id: id, before: existing.map(KanbanAvailabilityOverrideDTO.init), after: after)]),
                              on: project, summary: halfDays.map { "Set \(resource.displayName)’s week of \(week) to \(KanbanAvailability.days($0)) days" }
                                  ?? "Cleared \(resource.displayName)’s override for the week of \(week)")
    }

    // MARK: Public holidays

    func addHoliday(_ holiday: KanbanHolidayDTO, on project: KanbanProject) throws {
        try applyAvailability(KanbanAvailabilityDelta(holidays: [.init(id: holiday.id, before: nil, after: holiday)]), on: project,
                              summary: "Added the public holiday \(holiday.name) (\(Self.dayLabel(holiday.day)))")
    }

    func editHoliday(_ holiday: KanbanHoliday, to updated: KanbanHolidayDTO, on project: KanbanProject) throws {
        var updated = updated
        updated.id = holiday.id
        updated.createdAt = holiday.createdAt
        updated.updatedAt = now()
        updated.workedBy = KanbanHoliday.normalized(updated.workedBy)
        try applyAvailability(KanbanAvailabilityDelta(holidays: [.init(id: holiday.id, before: KanbanHolidayDTO(holiday), after: updated)]),
                              on: project, summary: "Changed the public holiday \(updated.name) (\(Self.dayLabel(updated.day)))")
    }

    func deleteHolidays(_ holidays: [KanbanHoliday], on project: KanbanProject) throws {
        guard let first = holidays.first else { return }
        try applyAvailability(KanbanAvailabilityDelta(holidays: holidays.map { .init(id: $0.id, before: KanbanHolidayDTO($0), after: nil) }),
                              on: project, summary: holidays.count == 1 ? "Removed the public holiday \(first.name) (\(Self.dayLabel(first.day)))"
                                  : "Removed \(holidays.count) public holidays")
    }

    /// Whether `person` works `holiday` (an exception to it).
    func setWorks(_ person: KanbanPerson, holiday: KanbanHoliday, works: Bool, on project: KanbanProject) throws {
        var updated = KanbanHolidayDTO(holiday)
        var people = Set(updated.workedBy ?? [])
        if works { people.insert(person.id) } else { people.remove(person.id) }
        updated.workedBy = KanbanHoliday.normalized(Array(people))
        updated.updatedAt = now()
        try applyAvailability(KanbanAvailabilityDelta(holidays: [.init(id: holiday.id, before: KanbanHolidayDTO(holiday), after: updated)]),
                              on: project, summary: works ? "\(person.name) works on \(holiday.name) (\(Self.dayLabel(holiday.day)))"
                                  : "\(person.name) is off on \(holiday.name) (\(Self.dayLabel(holiday.day)))")
    }

    /// Every public holiday, for the arithmetic.
    func holidays() throws -> KanbanAvailability.Holidays {
        KanbanAvailability.Holidays(try context.fetch(FetchDescriptor<KanbanHoliday>()))
    }

    // MARK: Board dates

    /// Renames a board and sets or clears its dates, as one undoable entry. Days are `yyyyMMdd`.
    func editBoardDetails(_ project: KanbanProject, name: String, startDay: String?, endDay: String?) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw KanbanServiceError.invariant("A board needs a name.") }
        try Self.checkBoardDates(startDay, endDay)
        var changes: [KanbanFieldChange] = []
        if trimmed != project.name { changes.append(.init(entity: .project, id: project.id, field: "name", old: .string(project.name), new: .string(trimmed))) }
        if startDay != project.startDay {
            changes.append(.init(entity: .project, id: project.id, field: "startDay", old: project.startDay.map(KanbanValue.string), new: startDay.map(KanbanValue.string)))
        }
        if endDay != project.endDay {
            changes.append(.init(entity: .project, id: project.id, field: "endDay", old: project.endDay.map(KanbanValue.string), new: endDay.map(KanbanValue.string)))
        }
        try editProjectFields(project, changes)
    }

    static func checkBoardDates(_ startDay: String?, _ endDay: String?) throws {
        if let problem = KanbanAvailability.boardDatesProblem(startDay, endDay) { throw KanbanServiceError.invariant(problem) }
    }

    // MARK: Labels

    private func personName(_ id: UUID?) -> String {
        guard let id else { return "someone" }
        return (try? context.fetch(FetchDescriptor<KanbanPerson>(predicate: #Predicate { $0.id == id })).first?.name) ?? "someone"
    }

    /// "20–24 Oct 2026", "22 Oct 2026 (afternoon)".
    static func span(_ entry: KanbanTimeOffDTO) -> String {
        guard let start = KanbanDay(key: entry.startDay), let end = KanbanDay(key: entry.endDay) else { return entry.startDay }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: KanbanAvailabilityFormat.calendar, timeZone: TimeZone(identifier: "UTC")!)
        let portion = KanbanTimeOffPortion(rawValue: entry.portionRaw) ?? .full
        let suffix = portion == .full ? "" : " (\(portion.label.lowercased()))"
        return start == end ? start.utcDate.formatted(style) + suffix : "\(start.utcDate.formatted(style)) – \(end.utcDate.formatted(style))"
    }

    static func dayLabel(_ key: String) -> String {
        guard let day = KanbanDay(key: key) else { return key }
        return day.utcDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: KanbanAvailabilityFormat.calendar,
                                                      timeZone: TimeZone(identifier: "UTC")!))
    }

    static func weekLabel(_ monday: KanbanDay) -> String {
        monday.utcDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: KanbanAvailabilityFormat.calendar, timeZone: TimeZone(identifier: "UTC")!))
    }

    // MARK: Internals

    private func availabilityRecords() throws -> AvailabilityRecords {
        AvailabilityRecords(timeOff: Dictionary(try context.fetch(FetchDescriptor<KanbanTimeOff>()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                            overrides: Dictionary(try context.fetch(FetchDescriptor<KanbanAvailabilityOverride>()).map { ($0.id, $0) },
                                                  uniquingKeysWith: { a, _ in a }),
                            people: Dictionary(try context.fetch(FetchDescriptor<KanbanPerson>()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                            holidays: Dictionary(try context.fetch(FetchDescriptor<KanbanHoliday>()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }
}

/// The stored records an availability change touches, and a checked plan to change them.
struct AvailabilityRecords {
    var timeOff: [UUID: KanbanTimeOff]
    var overrides: [UUID: KanbanAvailabilityOverride]
    var people: [UUID: KanbanPerson]
    var holidays: [UUID: KanbanHoliday] = [:]

    /// Whether every record is as the delta's `before` (or `after`) says.
    func matches(_ delta: KanbanAvailabilityDelta, before: Bool) -> Bool {
        for t in delta.timeOff where timeOff[t.id].map(KanbanTimeOffDTO.init) != (before ? t.before : t.after) { return false }
        for o in delta.overrides where overrides[o.id].map(KanbanAvailabilityOverrideDTO.init) != (before ? o.before : o.after) { return false }
        for a in delta.aliases where people[a.personID]?.aliases != (before ? a.before : a.after) { return false }
        for h in delta.holidays where holidays[h.id].map(KanbanHolidayDTO.init) != (before ? h.before : h.after) { return false }
        return true
    }

    /// New overrides fit the week's possible days once the change's holidays are in (design 04).
    /// Undo skips this: it restores what was valid, and a stale override shows as needing review.
    @MainActor
    func checkCapacity(_ delta: KanbanAvailabilityDelta, resources: [KanbanResource]) throws {
        let overrides = delta.overrides.compactMap(\.after)
        guard !overrides.isEmpty else { return }
        var final = holidays.mapValues(KanbanHolidayDTO.init)
        for h in delta.holidays { final[h.id] = h.after }
        let all = KanbanAvailability.Holidays(final.values.compactMap { h in
            KanbanDay(key: h.day).map { KanbanAvailability.Holiday(id: h.id, day: $0, portion: KanbanTimeOffPortion(rawValue: h.portionRaw) ?? .full,
                                                                   workedBy: Set(h.workedBy ?? [])) }
        })
        let byID = Dictionary(resources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for o in overrides {
            guard let resource = o.resourceId.flatMap({ byID[$0] }), let project = resource.project, let monday = KanbanDay(key: o.weekStart) else { continue }
            let possible = KanbanAvailability.cell(week: monday, board: .init(project), member: .init(resource), holidays: all).possibleHalfDays
            guard o.halfDays <= possible else {
                throw KanbanServiceError.invariant("\(resource.displayName)’s week of \(KanbanService.weekLabel(monday)) has \(KanbanAvailability.days(possible)) possible days.")
            }
        }
    }

    /// Checks every `after` and resolves what it points at; throws before anything changes.
    func plan(_ delta: KanbanAvailabilityDelta, resources: [KanbanResource]) throws -> AvailabilityPlan {
        let peopleByID = people
        let resourcesByID = Dictionary(resources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var plan = AvailabilityPlan()
        for t in delta.timeOff {
            guard let after = t.after else {
                if let record = timeOff[t.id] { plan.deletions.append(record) }
                continue
            }
            try Self.check(after)
            guard let person = after.personId.flatMap({ peopleByID[$0] }) else {
                throw KanbanServiceError.conflict("That person is no longer in TickyTask.")
            }
            plan.timeOff.append((after, timeOff[t.id], person))
        }
        // One override per membership and week, counting what this change removes or moves.
        var taken = Set(overrides.values.compactMap { o in o.resource.map { "\($0.id)|\(o.weekStart)" } })
        for o in delta.overrides { if let record = overrides[o.id], let resource = record.resource { taken.remove("\(resource.id)|\(record.weekStart)") } }
        for o in delta.overrides {
            guard let after = o.after else {
                if let record = overrides[o.id] { plan.deletions.append(record) }
                continue
            }
            guard let monday = KanbanDay(key: after.weekStart), monday.monday == monday else {
                throw KanbanServiceError.invariant("An override starts on a Monday.")
            }
            guard (0...14).contains(after.halfDays) else { throw KanbanServiceError.invariant("A week has 0 to 7 days.") }
            guard let resource = after.resourceId.flatMap({ resourcesByID[$0] }) else {
                throw KanbanServiceError.conflict("That membership is no longer on the board.")
            }
            guard taken.insert("\(resource.id)|\(after.weekStart)").inserted else {
                throw KanbanServiceError.invariant("That week already has an override.")
            }
            plan.overrides.append((after, overrides[o.id], resource))
        }
        for a in delta.aliases {
            guard let person = peopleByID[a.personID] else { throw KanbanServiceError.conflict("That person is no longer in TickyTask.") }
            plan.aliases.append((person, a.after))
        }
        for h in delta.holidays {
            guard let after = h.after else {
                if let record = holidays[h.id] { plan.deletions.append(record) }
                continue
            }
            guard KanbanDay(key: after.day) != nil else { throw KanbanServiceError.invariant("A holiday needs a real day.") }
            guard !after.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw KanbanServiceError.invariant("A holiday needs a name.") }
            guard KanbanTimeOffPortion(rawValue: after.portionRaw) != nil else { throw KanbanServiceError.invariant("Unknown part of the day.") }
            // People deleted since keep no exception; undo can't bring an exception back for someone gone.
            var kept = after
            kept.workedBy = KanbanHoliday.normalized(after.workedBy?.filter { peopleByID[$0] != nil })
            plan.holidays.append((kept, holidays[h.id]))
        }
        return plan
    }

    static func check(_ entry: KanbanTimeOffDTO) throws {
        guard let start = KanbanDay(key: entry.startDay), let end = KanbanDay(key: entry.endDay) else {
            throw KanbanServiceError.invariant("Time off needs real start and end days.")
        }
        guard start <= end else { throw KanbanServiceError.invariant("Time off can't end before it starts.") }
        guard let portion = KanbanTimeOffPortion(rawValue: entry.portionRaw), KanbanTimeOffKind(rawValue: entry.kindRaw) != nil,
              KanbanTimeOffOrigin(rawValue: entry.originRaw) != nil else {
            throw KanbanServiceError.invariant("Unknown kind of time off.")
        }
        if portion != .full, start != end { throw KanbanServiceError.invariant("A morning or afternoon off is a single day.") }
    }
}

/// A checked change, applied without failing.
struct AvailabilityPlan {
    var timeOff: [(KanbanTimeOffDTO, KanbanTimeOff?, KanbanPerson)] = []
    var overrides: [(KanbanAvailabilityOverrideDTO, KanbanAvailabilityOverride?, KanbanResource)] = []
    var aliases: [(KanbanPerson, [String]?)] = []
    var holidays: [(KanbanHolidayDTO, KanbanHoliday?)] = []
    var deletions: [any PersistentModel] = []

    func apply(_ context: ModelContext) {
        for (dto, existing, person) in timeOff {
            let record = existing ?? {
                let model = KanbanTimeOff(id: dto.id, startDay: dto.startDay, endDay: dto.endDay)
                context.insert(model)
                return model
            }()
            record.startDay = dto.startDay
            record.endDay = dto.endDay
            record.portionRaw = dto.portionRaw
            record.kindRaw = dto.kindRaw
            record.note = dto.note
            record.originRaw = dto.originRaw
            record.createdAt = dto.createdAt
            record.updatedAt = dto.updatedAt
            record.person = person
        }
        for (dto, existing, resource) in overrides {
            let record = existing ?? {
                let model = KanbanAvailabilityOverride(id: dto.id, weekStart: dto.weekStart, halfDays: dto.halfDays)
                context.insert(model)
                return model
            }()
            record.weekStart = dto.weekStart
            record.halfDays = dto.halfDays
            record.note = dto.note
            record.createdAt = dto.createdAt
            record.updatedAt = dto.updatedAt
            record.resource = resource
        }
        for (person, aliases) in aliases { person.aliases = aliases }
        for (dto, existing) in holidays {
            let record = existing ?? {
                let model = KanbanHoliday(id: dto.id, day: dto.day, name: dto.name)
                context.insert(model)
                return model
            }()
            record.day = dto.day
            record.name = dto.name
            record.portionRaw = dto.portionRaw
            record.workedBy = dto.workedBy
            record.createdAt = dto.createdAt
            record.updatedAt = dto.updatedAt
        }
        deletions.forEach { context.delete($0) }
    }
}
