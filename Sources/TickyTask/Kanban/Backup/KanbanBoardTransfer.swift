import Foundation
import SwiftData

/// Moving boards between Macs (design 01 §7): a `.tickytask-board` file is the backup's
/// Kanban section filtered to the chosen boards and the people they reference. Import is
/// additive: every imported row gets a fresh id (so nothing can clash), each board comes in
/// as a new board (its key renamed if taken) or merges into an existing one, and people are
/// matched by id, then by name. Everything is resolved and checked before anything is
/// inserted, then saved once. History stays on the Mac it was made on (I-D9).
enum KanbanBoardTransfer {
    static let format = "tickytask-board"
    static let version = 2
    static let fileExtension = "tickytask-board"

    struct Envelope: Codable {
        var format: String
        var version: Int
        var kanban: KanbanBackupDTO
    }

    enum TransferError: LocalizedError, Equatable {
        case notABoardFile, newerVersion, missingPerson(String), noSuchBoard, rowPositions(String)

        var errorDescription: String? {
            switch self {
            case .notABoardFile: "That isn't a TickyTask board file."
            case .newerVersion: "That board file was made by a newer version of TickyTask."
            case let .missingPerson(name): "The file refers to a resource it doesn't include (on “\(name)”)."
            case .noSuchBoard: "The board to merge into no longer exists."
            case let .rowPositions(name): "“\(name)” has damaged positions or history numbering, so nothing was imported."
            }
        }
    }

    // MARK: - Export

    @MainActor
    static func export(_ projects: [KanbanProject], context: ModelContext, timeOffRange: (start: String, end: String)? = nil) throws -> Data {
        let all = try KanbanBackupDTO.snapshot(context: context)
        let ids = Set(projects.map(\.id))
        func inBoards(_ id: UUID?) -> Bool { id.map(ids.contains) ?? false }
        var dto = KanbanBackupDTO()
        dto.projects = all.projects.filter { ids.contains($0.id) }
        dto.columns = all.columns.filter { inBoards($0.projectId) }
        dto.labels = all.labels.filter { inBoards($0.projectId) }
        dto.resources = all.resources.filter { inBoards($0.projectId) }
        dto.tasks = all.tasks.filter { inBoards($0.projectId) }
        let taskIDs = Set(dto.tasks.map(\.id))
        dto.subtasks = all.subtasks.filter { $0.taskId.map(taskIDs.contains) ?? false }
        // Every person a membership names, archived memberships included.
        let personIDs = Set(dto.resources.compactMap(\.personId))
        dto.people = all.people.filter { personIDs.contains($0.id) }

        // Availability (v2+): the boards' overrides, and their people's time off that overlaps a
        // board's dates (whole entries, even those running past them). For a board without both
        // dates, the range given, or else the Availability tab's 12 weeks from this week.
        let resourceIDs = Set(dto.resources.map(\.id))
        let overrides = (all.availabilityOverrides ?? []).filter { $0.resourceId.map(resourceIDs.contains) ?? false }
        dto.availabilityOverrides = overrides.isEmpty ? nil : overrides
        let ranges: [(String, String)] = dto.projects.map { board in
            if let start = board.startDay, let end = board.endDay { return (start, end) }
            if let timeOffRange { return timeOffRange }
            return defaultTimeOffRange(startDay: board.startDay, endDay: board.endDay)
        }
        let timeOff = (all.timeOff ?? []).filter { entry in
            (entry.personId.map(personIDs.contains) ?? false) && ranges.contains { entry.startDay <= $0.1 && entry.endDay >= $0.0 }
        }
        dto.timeOff = timeOff.isEmpty ? nil : timeOff

        return try BackupCoding.encoder().encode(Envelope(format: format, version: version, kanban: dto.deterministicallySorted()))
    }

    /// For a board without both dates: from its start (or this week) for 12 weeks, ending at its
    /// end if that comes sooner. The export sheet offers this, and the user can change it.
    static func defaultTimeOffRange(startDay: String?, endDay: String?, today: KanbanDay = .today()) -> (start: String, end: String) {
        let end = endDay.flatMap(KanbanDay.init(key:))
        let start = startDay.flatMap(KanbanDay.init(key:)) ?? min(today.monday, end ?? today.monday)
        let twelve = start.adding(days: 83)
        return (start.key, min(twelve, end ?? twelve).key)
    }

    // MARK: - Plan (the preview)

    struct BoardChoice: Equatable, Identifiable {
        let id: UUID              // the board's id in the file
        var name: String
        var key: String
        /// The key was taken here, so `key` is a renamed one.
        let keyWasTaken: Bool
        /// Merge into this existing board instead of adding a new one.
        var mergeInto: UUID?
        let cards: Int
        /// When merging: take the file's board dates instead of keeping this board's.
        var useImportedDates = false
    }

    struct PersonChoice: Equatable, Identifiable {
        enum Match: Equatable { case sameID, sameName, none }
        let id: UUID              // the person's id in the file
        let name: String
        let match: Match
        /// The existing person to link to; nil creates a new one.
        var linkTo: UUID?
    }

    struct Plan: Equatable {
        var kanban: KanbanBackupDTO
        var boards: [BoardChoice]
        var people: [PersonChoice]
        /// What the validator repaired in the file (dropped cycles, cards sent to Unassigned).
        var report = KanbanImportReport()
        /// Time off here with a file entry's id but other content: keep this (default) or take the file's.
        var useIncomingTimeOff = false
        /// Weeks a matched membership already overrides: keep this (default) or take the file's.
        var useIncomingOverrides = false
        var counts: (boards: Int, cards: Int, people: Int) { (boards.count, kanban.tasks.count, people.count) }

        static func == (a: Plan, b: Plan) -> Bool {
            a.kanban == b.kanban && a.boards == b.boards && a.people == b.people && a.report == b.report
                && a.useIncomingTimeOff == b.useIncomingTimeOff && a.useIncomingOverrides == b.useIncomingOverrides
        }

        /// For the preview: file time off whose id is recorded here, for the person it maps to,
        /// with other content; and file overrides for a week a linked person's membership on the
        /// merge target already overrides.
        func availabilityConflicts(projects: [KanbanProject], people here: [KanbanPerson]) -> (timeOff: Int, overrides: Int) {
            let linked = Dictionary(people.compactMap { p in p.linkTo.map { (p.id, $0) } }, uniquingKeysWith: { a, _ in a })
            let recorded = Dictionary(here.flatMap(\.timeOff).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let timeOff = (kanban.timeOff ?? []).filter { dto in
                guard let person = dto.personId.flatMap({ linked[$0] }), let existing = recorded[dto.id],
                      existing.person?.id == person else { return false }
                var mapped = dto
                mapped.personId = person
                return KanbanTimeOffDTO(existing).meaning != mapped.meaning || existing.note != dto.note
            }.count
            var overrides = 0
            for board in boards {
                guard let target = board.mergeInto.flatMap({ id in projects.first { $0.id == id } }) else { continue }
                for dto in (kanban.availabilityOverrides ?? []) {
                    guard let resource = kanban.resources.first(where: { $0.id == dto.resourceId && $0.projectId == board.id }),
                          let person = resource.personId.flatMap({ linked[$0] }),
                          let membership = target.resources.first(where: { $0.archivedAt == nil && $0.person?.id == person }) else { continue }
                    if membership.availabilityOverrides.contains(where: { $0.weekStart == dto.weekStart && $0.halfDays != dto.halfDays }) { overrides += 1 }
                }
            }
            return (timeOff, overrides)
        }

        /// Per board in the file, the people whose active membership won't get a row of its own:
        /// a board has one active membership per person, so theirs joins one already there (on
        /// the merge target, or from earlier in the file, including an earlier board merged into
        /// the same one) and its allocation, role and dates are dropped. Mirrors `apply`.
        func reusedMemberships(projects: [KanbanProject], people here: [KanbanPerson]) -> [UUID: [String]] {
            let archivedHere = Set(here.filter { $0.archivedAt != nil }.map(\.id))
            let archivedInFile = Set(kanban.people.filter { $0.archivedAt != nil }.map(\.id))
            var taken: [String: Set<String>] = [:]   // destination board → whose active membership is there
            var reused: [UUID: [String]] = [:]
            for board in boards {
                // An existing board, or the new one this board becomes (never an existing id).
                let destination = board.mergeInto.map { "here:\($0)" } ?? "new:\(board.id)"
                if taken[destination] == nil {
                    let target = board.mergeInto.flatMap { id in projects.first { $0.id == id } }
                    // An archived person's membership is never reused, even if a store left it active.
                    taken[destination] = Set(target?.resources.filter { $0.archivedAt == nil }
                        .compactMap { $0.person.flatMap { $0.archivedAt == nil ? "here:\($0.id)" : nil } } ?? [])
                }
                for dto in kanban.resources.filter({ $0.projectId == board.id && $0.archivedAt == nil }).sorted(by: { $0.sortIndex < $1.sortIndex }) {
                    guard let choice = self.people.first(where: { $0.id == dto.personId }) else { continue }
                    // Someone archived (here, or in the file for a new person) arrives archived.
                    let arrivesArchived = choice.linkTo.map(archivedHere.contains) ?? archivedInFile.contains(choice.id)
                    if arrivesArchived { continue }
                    // Someone created by the import is nobody here yet.
                    let identity = choice.linkTo.map { "here:\($0)" } ?? "new:\(choice.id)"
                    if !taken[destination, default: []].insert(identity).inserted { reused[board.id, default: []].append(choice.name) }
                }
            }
            return reused
        }
    }

    @MainActor
    static func plan(_ data: Data, context: ModelContext) throws -> Plan {
        guard let envelope = try? BackupCoding.decoder().decode(Envelope.self, from: data), envelope.format == format else {
            throw TransferError.notABoardFile
        }
        guard envelope.version <= version, envelope.kanban.version <= KanbanBackupDTO.currentVersion else { throw TransferError.newerVersion }
        let people = Set(envelope.kanban.people.map(\.id))
        for resource in envelope.kanban.resources where resource.personId.map({ !people.contains($0) }) ?? true {
            let board = envelope.kanban.projects.first { $0.id == resource.projectId }?.name ?? ""
            throw TransferError.missingPerson(board)
        }
        let (kanban, report) = try KanbanBackupValidator.sanitized(envelope.kanban)
        let existingProjects = try context.fetch(FetchDescriptor<KanbanProject>())
        let existingPeople = try context.fetch(FetchDescriptor<KanbanPerson>())
        var takenKeys = Set(existingProjects.map { $0.key.uppercased() })
        let boards = kanban.projects.map { dto -> BoardChoice in
            let taken = takenKeys.contains(dto.key.uppercased())
            let key = taken ? uniqueKey(dto.key, taken: takenKeys) : dto.key
            takenKeys.insert(key.uppercased())
            return BoardChoice(id: dto.id, name: dto.name, key: key, keyWasTaken: taken, mergeInto: nil,
                               cards: kanban.tasks.filter { $0.projectId == dto.id }.count)
        }
        let choices = kanban.people.map { dto -> PersonChoice in
            if existingPeople.contains(where: { $0.id == dto.id }) { return PersonChoice(id: dto.id, name: dto.name, match: .sameID, linkTo: dto.id) }
            let sameName = existingPeople.first { normalized($0.name) == normalized(dto.name) && $0.archivedAt == nil }
            return PersonChoice(id: dto.id, name: dto.name, match: sameName == nil ? .none : .sameName, linkTo: sameName?.id)
        }
        return Plan(kanban: kanban, boards: boards, people: choices, report: report)
    }

    private static func normalized(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    /// "PLAT" → "PLAT2", "PLAT3", … whichever is free.
    static func uniqueKey(_ key: String, taken: Set<String>) -> String {
        var n = 2
        while taken.contains("\(key)\(n)".uppercased()) { n += 1 }
        return "\(key)\(n)"
    }

    // MARK: - Apply

    /// Imports the plan's boards. Returns the boards that received cards.
    @MainActor
    @discardableResult
    static func apply(_ plan: Plan, fileName: String, context: ModelContext, now: Date = Date()) throws -> [KanbanProject] {
        try RecurrenceMaterializer.checkpoint(context)
        let existingProjects = Dictionary(try context.fetch(FetchDescriptor<KanbanProject>()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let existingPeople = Dictionary(try context.fetch(FetchDescriptor<KanbanPerson>()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // New boards, rows and cards go after the last ones, and each board gets one more
        // change-log entry: past 2^52 (or non-finite) whole steps stop being exact, and a full
        // counter would trap. A store damaged that way is refused before anything is written.
        func unusable(_ position: Double) -> Bool { !position.isFinite || abs(position) >= 0x1p52 }
        if let board = existingProjects.values.first(where: { unusable($0.sortIndex) }) { throw TransferError.rowPositions(board.name) }
        var entries: [UUID: Int] = [:]
        for board in plan.boards {
            guard let id = board.mergeInto else { continue }
            guard let target = existingProjects[id] else { throw TransferError.noSuchBoard }
            if target.resources.contains(where: { unusable($0.sortIndex) }) || target.tasks.contains(where: { unusable($0.sortIndex) }) {
                throw TransferError.rowPositions(target.name)
            }
            entries[id, default: 0] += 1
            if target.nextActivitySeq > Int.max - entries[id, default: 0] { throw TransferError.rowPositions(target.name) }
        }
        for person in plan.people { if let id = person.linkTo, existingPeople[id] == nil { throw TransferError.missingPerson(person.name) } }
        let note = try KanbanActivityPayload().encoded()   // the informational "Imported from" entries

        // Nothing below throws: build and insert every row, then save once.
        let k = plan.kanban
        var people: [UUID: KanbanPerson] = [:]
        for dto in k.people {
            if let id = plan.people.first(where: { $0.id == dto.id })?.linkTo, let existing = existingPeople[id] {
                people[dto.id] = existing
                continue
            }
            let person = KanbanPerson(name: dto.name, initials: dto.initials)
            person.colorHex = dto.colorHex
            person.employmentRaw = dto.employmentRaw
            person.skills = dto.skills
            person.createdAt = dto.createdAt
            person.archivedAt = dto.archivedAt
            context.insert(person)
            people[dto.id] = person
        }

        var touched: [KanbanProject] = []
        var destinations: [UUID: Destination] = [:]
        var nextSort = (existingProjects.values.map(\.sortIndex).max() ?? -1) + 1
        for board in plan.boards {
            guard let dto = k.projects.first(where: { $0.id == board.id }) else { continue }
            let project: KanbanProject
            let merging: Bool
            if let target = board.mergeInto, let existing = existingProjects[target] {
                project = existing
                merging = true
                if board.useImportedDates, KanbanAvailability.boardDatesProblem(dto.startDay, dto.endDay) == nil {
                    project.startDay = dto.startDay
                    project.endDay = dto.endDay
                }
            } else {
                project = KanbanProject(name: board.name, key: board.key, sortIndex: nextSort)
                nextSort += 1
                copySettings(dto, to: project)
                project.createdAt = now
                project.updatedAt = now
                context.insert(project)
                merging = false
            }
            var destination = destinations[project.id] ?? Destination(project)
            insertBoard(dto.id, from: k, into: project, merging: merging, people: people, destination: &destination, now: now,
                        useIncoming: (plan.useIncomingTimeOff, plan.useIncomingOverrides), context: context)
            destinations[project.id] = destination
            let entry = KanbanActivity(seq: project.nextActivitySeq, at: now, kind: KanbanActivityKind.structure.rawValue,
                                       summary: "Imported from \(fileName)", payload: note)
            context.insert(entry)
            entry.project = project
            project.nextActivitySeq += 1
            touched.append(project)
        }

        do {
            try context.saveTransaction()
        } catch {
            context.undoFailedTransaction()
            throw error
        }
        return touched
    }

    /// A board receiving rows, tracked across the file's boards (two can merge into one), so
    /// reuse doesn't depend on inverse arrays catching up with unsaved inserts.
    private struct Destination {
        /// Person id → their active membership on the board (live people only).
        var active: [UUID: KanbanResource]
        var nextRow: Double

        /// The next whole position after `position`, in Doubles (no Int conversion to trap on a
        /// huge stored value); where +1 is lost to precision, the next representable value.
        static func after(_ position: Double) -> Double {
            let next = position.rounded(.down) + 1
            return next > position ? next : position.nextUp
        }

        init(_ project: KanbanProject) {
            let live = project.resources.filter { $0.archivedAt == nil && $0.person?.archivedAt == nil }
            active = Dictionary(live.compactMap { r in r.person.map { ($0.id, r) } }, uniquingKeysWith: { a, _ in a })
            // After the last row: positions can be sparse (a reverted addition isn't renumbered).
            nextRow = Self.after(project.resources.map(\.sortIndex).max() ?? -1)
        }
    }

    private static func copySettings(_ dto: KanbanProjectDTO, to project: KanbanProject) {
        project.details = dto.details
        project.colorHex = dto.colorHex
        project.symbolName = dto.symbolName
        project.startDay = dto.startDay
        project.endDay = dto.endDay
        project.workWeekDays = dto.workWeekDays
        project.hoursPerDay = dto.hoursPerDay
        project.defaultCapacityHoursPerWeek = dto.defaultCapacityHoursPerWeek
        project.wipPolicyRaw = dto.wipPolicyRaw
        project.loadMeasureRaw = dto.loadMeasureRaw
        project.openTaskTarget = dto.openTaskTarget
        project.defaultEstimateHours = dto.defaultEstimateHours
        project.weightedLoad = dto.weightedLoad
        project.dueSoonThresholdDays = dto.dueSoonThresholdDays
        project.suggestDoneWhenSubtasksComplete = dto.suggestDoneWhenSubtasksComplete
    }

    /// One board's columns, labels, memberships, cards and steps, on a new board or merged
    /// into an existing one (columns by name and kind, labels by name, an existing active
    /// membership reused for the same person). Imports availability overrides and time off (v2+).
    /// Non-throwing.
    @MainActor
    private static func insertBoard(_ source: UUID, from k: KanbanBackupDTO, into project: KanbanProject, merging: Bool,
                                    people: [UUID: KanbanPerson], destination: inout Destination, now: Date,
                                    useIncoming: (timeOff: Bool, overrides: Bool) = (false, false), context: ModelContext) {
        func mine(_ id: UUID?) -> Bool { id == source }

        var columns: [UUID: KanbanColumn] = [:]
        var ordered = project.orderedColumns
        for dto in k.columns.filter({ mine($0.projectId) }).sorted(by: { $0.sortIndex < $1.sortIndex }) {
            if merging, let match = ordered.first(where: { $0.name == dto.name && $0.kindRaw == dto.kindRaw }) {
                columns[dto.id] = match
                continue
            }
            // A merged board keeps its one backlog: an incoming backlog with another name joins it.
            if merging, dto.kindRaw == KanbanColumnKind.backlog.rawValue, let backlog = ordered.first(where: { $0.kind == .backlog }) {
                columns[dto.id] = backlog
                continue
            }
            let column = KanbanColumn(name: dto.name, kind: KanbanColumnKind(rawValue: dto.kindRaw) ?? .active)
            column.colorHex = dto.colorHex
            column.symbolName = dto.symbolName
            column.wipLimit = dto.wipLimit
            context.insert(column)
            column.project = project
            // New columns go before the first Done column of a merged board.
            let position = merging ? (ordered.firstIndex { $0.kind == .done } ?? ordered.count) : ordered.count
            ordered.insert(column, at: position)
            columns[dto.id] = column
        }
        for (index, column) in ordered.enumerated() { column.sortIndex = Double(index) }

        var labels: [UUID: KanbanLabel] = [:]
        var labelCount = project.labels.count
        for dto in k.labels.filter({ mine($0.projectId) }).sorted(by: { $0.sortIndex < $1.sortIndex }) {   // the file is in id order
            if merging, let match = project.labels.first(where: { $0.name == dto.name }) {
                labels[dto.id] = match
                continue
            }
            let label = KanbanLabel(name: dto.name, colorHex: dto.colorHex, sortIndex: Double(labelCount))
            labelCount += 1
            label.symbolName = dto.symbolName
            context.insert(label)
            label.project = project
            labels[dto.id] = label
        }

        var resources: [UUID: KanbanResource] = [:]
        for dto in k.resources.filter({ mine($0.projectId) }).sorted(by: { $0.sortIndex < $1.sortIndex }) {
            guard let person = dto.personId.flatMap({ people[$0] }) else { continue }
            // Reuse: one active membership per person and board.
            if dto.archivedAt == nil, person.archivedAt == nil, let existing = destination.active[person.id] {
                resources[dto.id] = existing
                continue
            }
            let resource = KanbanResource(person: person, sortIndex: destination.nextRow)
            destination.nextRow = Destination.after(destination.nextRow)
            resource.role = dto.role
            resource.assignmentRaw = dto.assignmentRaw
            resource.allocationPercent = dto.allocationPercent
            resource.capacityHoursPerWeekOverride = dto.capacityHoursPerWeekOverride
            resource.openTaskTargetOverride = dto.openTaskTargetOverride
            resource.startDate = dto.startDate
            resource.endDate = dto.endDate
            // Linked to someone archived here: the membership arrives archived (its cards Unassigned).
            resource.archivedAt = dto.archivedAt ?? person.archivedAt.map { _ in now }
            if resource.archivedAt == nil { destination.active[person.id] = resource }
            context.insert(resource)
            resource.project = project
            resources[dto.id] = resource
        }

        // Cards land at the end of their cell, in their file order.
        var nextInCell: [String: Double] = [:]
        func cellKey(_ column: KanbanColumn, _ resource: KanbanResource?) -> String { "\(column.id)|\(resource?.id.uuidString ?? "-")" }
        for card in project.tasks {
            guard let column = card.column else { continue }
            let key = cellKey(column, card.resource)
            nextInCell[key] = max(nextInCell[key] ?? 0, card.sortIndex + 1)
        }
        var tasks: [UUID: KanbanTask] = [:]
        for dto in k.tasks.filter({ mine($0.projectId) }).sorted(by: { $0.sortIndex < $1.sortIndex }) {
            guard let column = dto.columnId.flatMap({ columns[$0] }) else { continue }
            var resource = dto.resourceId.flatMap { resources[$0] }
            // A live card can't sit on an archived membership.
            if dto.archivedAt == nil, resource?.archivedAt != nil { resource = nil }
            let task = KanbanTask(title: dto.title, priority: dto.priority)
            task.notes = dto.notes
            task.notesRich = dto.notesRich
            task.isCritical = dto.isCritical
            task.dueDate = dto.dueDate
            task.startDate = dto.startDate
            task.estimateHours = dto.estimateHours
            task.complexity = dto.complexity.flatMap { KanbanComplexity(rawValue: $0)?.rawValue }
            task.jiraURL = dto.jiraURL
            task.isBlocked = dto.isBlocked
            task.blockedReason = dto.blockedReason
            task.createdAt = dto.createdAt
            task.updatedAt = dto.updatedAt
            // Complete exactly when in a Done column.
            task.completedAt = column.kind == .done ? (dto.completedAt ?? dto.updatedAt) : nil
            task.archivedAt = dto.archivedAt
            let key = cellKey(column, resource)
            task.sortIndex = nextInCell[key] ?? 0
            nextInCell[key] = task.sortIndex + 1
            context.insert(task)
            task.project = project
            task.column = column
            task.resource = resource
            task.labels = dto.labelIds.compactMap { labels[$0] }
            tasks[dto.id] = task
        }
        for dto in k.tasks where tasks[dto.id] != nil {
            tasks[dto.id]?.dependsOn = dto.dependsOnIds.compactMap { tasks[$0] }
        }
        // Each card's steps are renumbered 0, 1, 2… in the file's order: a position from the file
        // is only an order, and a huge one would stop later additions from going after it.
        var nextStep: [UUID: Double] = [:]
        for dto in k.subtasks.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            guard let task = dto.taskId.flatMap({ tasks[$0] }) else { continue }
            let position = nextStep[task.id, default: 0]
            nextStep[task.id] = position + 1
            let step = KanbanSubtask(title: dto.title, sortIndex: position)
            step.isDone = dto.isDone
            step.completedAt = dto.completedAt
            context.insert(step)
            step.task = task
            step.assignee = dto.assigneeId.flatMap { resources[$0] }.flatMap { $0.archivedAt == nil ? $0 : nil }
        }

        // Availability (v2+). Overrides follow the membership map (new or reused rows); one for a
        // week this membership already overrides keeps the existing value unless the preview chose
        // the file's. Time off belongs to the destination person: an entry already here (same id,
        // or the same person, days, half and type) isn't added twice; the same id with other
        // content keeps what's here unless the preview chose the file's; an id that's another
        // person's gets a fresh one.
        for dto in k.availabilityOverrides ?? [] {
            guard let resource = dto.resourceId.flatMap({ resources[$0] }), let monday = KanbanDay(key: dto.weekStart),
                  monday.monday == monday, (0...14).contains(dto.halfDays) else { continue }
            if let existing = resource.availabilityOverrides.first(where: { $0.weekStart == dto.weekStart }) {
                if useIncoming.overrides, existing.halfDays != dto.halfDays || existing.note != dto.note {
                    existing.halfDays = dto.halfDays
                    existing.note = dto.note
                    existing.updatedAt = now
                }
                continue
            }
            let override = KanbanAvailabilityOverride(weekStart: dto.weekStart, halfDays: dto.halfDays)
            override.note = dto.note
            override.createdAt = dto.createdAt
            override.updatedAt = now
            context.insert(override)
            override.resource = resource
        }
        for dto in k.timeOff ?? [] {
            guard let person = dto.personId.flatMap({ people[$0] }), (try? AvailabilityRecords.check(dto)) != nil else { continue }
            var mapped = dto
            if let existing = person.timeOff.first(where: { $0.id == dto.id }) {
                if useIncoming.timeOff {
                    existing.startDay = dto.startDay
                    existing.endDay = dto.endDay
                    existing.portionRaw = dto.portionRaw
                    existing.kindRaw = dto.kindRaw
                    existing.note = dto.note
                    existing.updatedAt = now
                }
                continue
            }
            mapped.personId = person.id
            guard !person.timeOff.contains(where: { KanbanTimeOffDTO($0).meaning == mapped.meaning }) else { continue }
            let taken = (try? context.fetchCount(FetchDescriptor<KanbanTimeOff>(predicate: #Predicate { $0.id == dto.id }))) ?? 0 > 0
            let entry = KanbanTimeOff(id: taken ? UUID() : dto.id, startDay: dto.startDay, endDay: dto.endDay,
                                      portion: KanbanTimeOffPortion(rawValue: dto.portionRaw) ?? .full,
                                      kind: KanbanTimeOffKind(rawValue: dto.kindRaw) ?? .other,
                                      origin: KanbanTimeOffOrigin(rawValue: dto.originRaw) ?? .manual)
            entry.note = dto.note
            entry.createdAt = dto.createdAt
            entry.updatedAt = now
            context.insert(entry)
            entry.person = person
        }
    }

    // MARK: - CSV

    /// One row per live card, RFC 4180 quoted, CRLF line ends.
    @MainActor
    static func csv(_ project: KanbanProject) -> String {
        let header = ["Title", "Column", "Assignee", "Priority", "Critical", "Due", "Start", "Estimate (h)", "Labels", "Jira", "Blocked", "Subtasks", "Complexity"]
        let day = Date.FormatStyle(date: .numeric, time: .omitted)
        let columns = Dictionary(project.orderedColumns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cards = project.tasks.filter { $0.archivedAt == nil }
            .sorted { (columns[$0.column?.id ?? UUID()] ?? .max, $0.sortIndex) < (columns[$1.column?.id ?? UUID()] ?? .max, $1.sortIndex) }
        let rows = cards.map { task -> [String] in
            let priority = TaskPriority(rawValue: min(max(task.priority, 0), 2)) ?? .low
            return [
                task.title, task.column?.name ?? "", task.resource.flatMap { $0.archivedAt == nil ? $0.displayName : nil } ?? "Unassigned",
                priority.label, task.isCritical ? "Yes" : "No", task.dueDate?.formatted(day) ?? "", task.startDate?.formatted(day) ?? "",
                task.estimateHours.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "",
                task.labels.sorted { $0.sortIndex < $1.sortIndex }.map(\.name).joined(separator: "; "),
                task.jiraURL ?? "", task.isBlocked ? "Yes" : "No", "\(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)",
                task.complexity.flatMap(KanbanComplexity.init(rawValue:))?.label ?? "",
            ]
        }
        return ([header] + rows).map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func quote(_ field: String) -> String {
        // A leading =, +, - or @ would run as a formula in a spreadsheet, also behind a tab,
        // return or other leading whitespace or control characters.
        let start = field.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
        let risky = start.map { "=+-@".unicodeScalars.contains($0) } == true || field.first.map { "\t\r".contains($0) } == true
        let safe = risky ? "'" + field : field
        guard safe.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
