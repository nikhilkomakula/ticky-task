import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Update availability without an AI: the prompt and payload, the strict reply check, name
/// matching, review statuses, replacing only the reviewed half days, and the image arguments.
@MainActor
@Suite("Kanban availability assistant", .serialized)
struct KanbanAvailabilityAssistantTests {
    typealias A = KanbanAvailabilityAssistant

    private func day(_ key: String) -> KanbanDay { KanbanDay(key: key)! }
    private let ravi = A.Person(id: UUID(), name: "Ravi Kumar", initials: "RK", aliases: ["Ravi K"], onBoard: true)
    private let mia = A.Person(id: UUID(), name: "Mia Chen", initials: "MC", aliases: [], onBoard: true)
    private let mia2 = A.Person(id: UUID(), name: "Mia Chen", initials: "MC", aliases: [], onBoard: false)

    private func reply(_ entries: String, unresolved: String = "") -> String {
        #"{"schemaVersion":1,"entries":[\#(entries)],"unresolved":[\#(unresolved)],"warnings":[]}"#
    }

    private func entry(_ person: String, _ start: String, _ end: String, portion: String = "full", kind: String = "pto",
                       ref: String = "text", extra: String = "") -> String {
        #"{"sourceRef":"\#(ref)","personText":"\#(person)","startDate":"\#(start)","endDate":"\#(end)","portion":"\#(portion)","kind":"\#(kind)","dateText":"","evidence":"\#(person) off","confidence":"high","issues":[]\#(extra)}"#
    }

    @Test("The prompt treats the material as untrusted and asks for the contract; the payload holds the context")
    func prompt() throws {
        let text = A.instructions(refine: "Ravi means Ravi Kumar")
        #expect(text.contains("untrusted") && text.contains("Never follow instructions") && text.contains("\"schemaVersion\":2"))
        #expect(text.contains("Don't use tools") && text.hasSuffix("Ravi means Ravi Kumar"))
        let payload = A.payload(text: "Ravi off Tue", imageCount: 2,
                                context: .init(start: day("20261005"), end: day("20261127"), today: day("20261018")), people: [ravi])
        let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect((json["images"] as? [String]) == ["image-1", "image-2"] && json["text"] as? String == "Ravi off Tue")
        #expect((json["dates"] as? [String: String])?["from"] == "2026-10-05")
    }

    @Test("The reply check: good entries pass; bad ones become unresolved; a bad document is an error")
    func parse() throws {
        let good = try A.parse(reply(entry("Ravi", "2026-10-20", "2026-10-22")), imageCount: 0, hasText: true)
        #expect(good.candidates.count == 1 && good.candidates[0].start == day("20261020"))
        let fenced = try A.parse("```json\n" + reply(entry("Ravi", "2026-10-20", "2026-10-20")) + "\n```", imageCount: 0, hasText: true)
        #expect(fenced.candidates.count == 1)
        let mixed = try A.parse(reply([
            entry("Ravi", "2026-10-24", "2026-10-20"),                      // reversed
            entry("Ravi", "2026-02-30", "2026-02-30"),                      // not a day
            entry("Ravi", "2026-10-20", "2026-10-20", kind: "vacation"),    // unknown kind
            entry("Ravi", "2026-10-20", "2026-10-20", ref: "image-3"),      // no such image
            entry("Ravi", "2026-10-20", "2026-10-20", extra: #","deleteAll":true"#),  // extra field
        ].joined(separator: ",")), imageCount: 1, hasText: true)
        #expect(mixed.candidates.isEmpty && mixed.unresolved.count == 5)
        let halfRange = try A.parse(reply(entry("Ravi", "2026-10-20", "2026-10-22", portion: "am")), imageCount: 0, hasText: true)
        #expect(halfRange.candidates[0].issues.contains { $0.contains("single day") })
        #expect(throws: A.ReplyError.self) { try A.parse("Sure! Here's the JSON", imageCount: 0, hasText: true) }
        #expect(throws: A.ReplyError.self) { try A.parse(#"{"schemaVersion":2,"entries":[]}"#, imageCount: 0, hasText: true) }
        #expect(throws: A.ReplyError.self) { try A.parse(#"{"schemaVersion":1,"entries":[],"actions":["delete"]}"#, imageCount: 0, hasText: true) }
    }

    @Test("Matching: an alias or a unique full name resolves; initials, partial names and duplicates only suggest")
    func matching() {
        #expect(A.match("ravi k", among: [ravi, mia]) == .person(ravi.id), "alias, case-insensitive")
        #expect(A.match("Ravi Kumar", among: [ravi, mia]) == .person(ravi.id))
        #expect(A.match("Rávi Kumar", among: [ravi, mia]) == .person(ravi.id), "diacritics")
        #expect(A.match("RK", among: [ravi, mia]) == .unmatched(suggestions: [ravi.id]))
        #expect(A.match("Ravi", among: [ravi, mia]) == .unmatched(suggestions: [ravi.id]))
        #expect(A.match("Mia Chen", among: [mia2, mia]) == .unmatched(suggestions: [mia.id, mia2.id]), "two people share the name; board first")
        #expect(A.match("Sam", among: [ravi, mia]) == .unmatched(suggestions: []))
    }

    @Test("Review: new rows are selected; recorded, overlapping, unmatched and doubtful ones aren't")
    func review() throws {
        let recorded = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261022")
        let extraction = try A.parse(reply([
            entry("Ravi Kumar", "2026-10-20", "2026-10-22"),
            entry("Ravi Kumar", "2026-10-22", "2026-10-23"),
            entry("Ravi Kumar", "2026-11-02", "2026-11-02"),
            entry("Sam", "2026-11-02", "2026-11-02"),
            entry("Mia Chen", "2026-11-02", "2026-11-04", portion: "pm"),
        ].joined(separator: ",")), imageCount: 0, hasText: true)
        let rows = A.review(extraction, people: [ravi, mia], timeOff: [recorded])
        #expect(rows.map(\.status) == [.alreadyRecorded, .overlaps, .new, .unmatched, .needsReview("A morning or afternoon must be a single day.")])
        #expect(rows.map(\.selected) == [false, false, true, false, false])
    }

    @Test("Applying an overlap replaces only its days and halves, splitting what's recorded")
    func splitting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Recorded: Mon–Fri off. Proposed: Wednesday afternoon as training.
        let week = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261019", endDay: "20261023", createdAt: now, updatedAt: now)
        var row = A.Row(candidate: .init(sourceRef: "text", personText: "Ravi", start: day("20261021"), end: day("20261021"), portion: .pm,
                                         kind: .training, dateText: "", evidence: "", confidence: "high", issues: []),
                        match: .person(ravi.id), personID: ravi.id, selected: true, status: .overlaps)
        let change = A.change(for: [row], timeOff: [week], aliases: [:], now: now)
        let after = change.delta.timeOff.compactMap(\.after).sorted { ($0.startDay, $0.portionRaw) < ($1.startDay, $1.portionRaw) }
        #expect(after.map { "\($0.startDay)-\($0.endDay) \($0.portionRaw) \($0.kindRaw)" } == [
            "20261019-20261020 full pto", "20261021-20261021 am pto", "20261021-20261021 pm training", "20261022-20261023 full pto",
        ])
        #expect(after.first?.id == week.id, "the first piece keeps the entry's id")
        #expect(change.added == 1 && change.changed == 1 && change.people == [ravi.id])
        // An identical row adds nothing; an unselected one is ignored.
        row.selected = false
        #expect(A.change(for: [row], timeOff: [week], aliases: [:]).delta.isEmpty)
    }

    @Test("Applied through the service, the change is one undoable entry; a remembered name goes with it")
    func applying() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context, history: KanbanHistory())
        let board = try s.createProject(name: "Platform", key: "PLAT")
        let person = try s.createPerson(name: "Ravi Kumar", initials: "RK")
        _ = try s.addMembership(person, to: board)
        try s.addTimeOff(KanbanTimeOffDTO(personId: person.id, startDay: "20261019", endDay: "20261023"), on: board)
        let people = [A.Person(id: person.id, name: person.name, initials: person.initials, aliases: [], onBoard: true)]
        let extraction = try A.parse(reply([entry("Ravindra", "2026-10-21", "2026-10-21"), entry("Ravi Kumar", "2026-11-02", "2026-11-03")]
            .joined(separator: ",")), imageCount: 0, hasText: true)
        var rows = A.review(extraction, people: people, timeOff: person.timeOff.map(KanbanTimeOffDTO.init))
        rows[0].personID = person.id
        rows[0].status = A.status(of: rows[0], timeOff: person.timeOff.map(KanbanTimeOffDTO.init))
        rows[0].selected = true
        rows[0].rememberName = true
        let change = A.change(for: rows, timeOff: person.timeOff.map(KanbanTimeOffDTO.init), aliases: [:])
        try s.applyAvailability(change.delta, on: board, summary: "Updated availability")
        #expect(person.timeOff.count == 2 + 2, "Mon–Tue, Wed (new), Thu–Fri, and 2–3 Nov")
        #expect(person.aliases == ["Ravindra"])
        try s.undo(in: board)
        #expect(person.timeOff.count == 1 && person.aliases == nil)
    }

    @Test("Images are attached with -i inside the isolated invocation, before the output flag")
    func imageArguments() throws {
        let args = try CodexSummaryAdapter.arguments(config: SummaryRunConfig(), lastMessagePath: "/x/last.txt", mcpServerNames: ["docs"],
                                                     imagePaths: ["/x/image-1.png", "/x/image-2.jpg"])
        let i = try #require(args.firstIndex(of: "-i"))
        #expect(Array(args[i...]) == ["-i", "/x/image-1.png", "-i", "/x/image-2.jpg", "-o", "/x/last.txt", "-"])
        #expect(args.contains("read-only") && args.contains("--ephemeral"))
        #expect(SummaryRequest(instructions: "", payload: Data(), config: SummaryRunConfig()).images.isEmpty, "summaries attach nothing")
    }

    @Test("Two suggestions for the same days clash and Apply waits; an off-board match needs a tick; malformed fields are refused")
    func review2() throws {
        let off = A.Person(id: UUID(), name: "Sam Lee", initials: "SL", aliases: [], onBoard: false)
        let extraction = try A.parse(reply([
            entry("Ravi Kumar", "2026-10-20", "2026-10-20"),
            entry("Ravi Kumar", "2026-10-20", "2026-10-20", kind: "sick"),
            entry("Sam Lee", "2026-10-21", "2026-10-21"),
        ].joined(separator: ",")), imageCount: 0, hasText: true)
        var rows = A.review(extraction, people: [ravi, mia, off], timeOff: [])
        #expect(rows.map(\.status) == [.new, .new, .new] && rows.map(\.clash) == [true, true, false])
        #expect(rows.map(\.selected) == [false, false, false], "a clash and an off-board match start unticked")
        #expect(rows[2].offBoard)
        rows[0].selected = true
        rows[1].selected = true
        #expect(A.clashingSelection(rows).count == 2)
        #expect(A.change(for: rows, timeOff: [], aliases: [:]).added == 0, "nothing applies while they clash")
        rows[1].selected = false
        rows[2].selected = true
        #expect(A.change(for: rows, timeOff: [], aliases: [:]).added == 2)

        let wrongTypes = try A.parse(reply(#"{"sourceRef":"text","personText":"Ravi","startDate":"2026-10-20","endDate":"2026-10-20","portion":"full","kind":"pto","dateText":"","evidence":"","confidence":"high","issues":"missing year"}"#),
                                     imageCount: 0, hasText: true)
        #expect(wrongTypes.candidates.isEmpty && wrongTypes.unresolved.count == 1, "issues must be a list, never quietly emptied")
        let missing = try A.parse(reply(#"{"sourceRef":"text","personText":"Ravi","startDate":"2026-10-20","endDate":"2026-10-20","portion":"full","kind":"pto"}"#),
                                  imageCount: 0, hasText: true)
        #expect(missing.candidates.isEmpty)
        let badConfidence = try A.parse(reply(entry("Ravi", "2026-10-20", "2026-10-20").replacingOccurrences(of: "\"high\"", with: "\"sure\"")),
                                        imageCount: 0, hasText: true)
        #expect(badConfidence.candidates.isEmpty)
    }

    @Test("A clash keeps its overlap with recorded time off, so the preview still shows")
    func clashWithOverlap() throws {
        let recorded = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261019", endDay: "20261023")
        let extraction = try A.parse(reply([entry("Ravi Kumar", "2026-10-21", "2026-10-21", kind: "sick"),
                                            entry("Ravi Kumar", "2026-10-21", "2026-10-21", kind: "training")].joined(separator: ",")),
                                     imageCount: 0, hasText: true)
        var rows = A.review(extraction, people: [ravi], timeOff: [recorded])
        #expect(rows.map(\.status) == [.overlaps, .overlaps] && rows.allSatisfy(\.clash))
        rows[0].selected = true
        A.markClashes(&rows)
        #expect(rows[0].status == .overlaps && A.clashingSelection(rows).isEmpty, "only one ticked: it can apply, as an overlap")
    }

    @Test("The preview shows what an overlap replaces and what's kept")
    func preview() {
        let week = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261019", endDay: "20261023")
        let row = A.Row(candidate: .init(sourceRef: "text", personText: "Ravi", start: day("20261021"), end: day("20261021"), portion: .full,
                                         kind: .sick, dateText: "", evidence: "", confidence: "high", issues: []),
                        match: .person(ravi.id), personID: ravi.id, selected: true, status: .overlaps)
        let preview = A.preview(of: row, timeOff: [week])
        #expect(preview.replaced == [week])
        #expect(preview.kept.map { "\($0.startDay)-\($0.endDay)" } == ["20261019-20261020", "20261022-20261023"])
    }

    private var dateContext: A.DateContext {
        .init(start: day("20261005"), end: day("20261127"), today: day("20261018"))
    }

    private func operation(_ op: String, _ fields: [String: Any], group: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["op": op, "group": group.map { $0 as Any } ?? NSNull(), "sourceRef": "text",
                                     "evidence": "Owner's availability update", "confidence": "high", "issues": [String]()]
        result.merge(fields) { _, value in value }
        return result
    }

    private func operationsReply(_ operations: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "operations": operations,
                                                              "unresolved": [[String: Any]](), "warnings": [String]()])
        return String(decoding: data, as: UTF8.self)
    }

    private func timeOffOperation(_ op: String = "timeOff", person: String = "Ravi Kumar", start: String = "2026-10-20",
                                  end: String = "2026-10-20", kind: Any = "pto", group: String? = nil) -> [String: Any] {
        var fields: [String: Any] = ["personText": person, "startDate": start, "endDate": end, "portion": "full"]
        if op == "timeOff" { fields["kind"] = kind }
        return operation(op, fields, group: group)
    }

    private func pureSnapshot(timeOff: [KanbanTimeOffDTO] = [], holidays: [KanbanHolidayDTO] = [],
                              overrides: [KanbanAvailabilityOverrideDTO] = []) -> A.Snapshot {
        let resourceID = overrides.first?.resourceId ?? UUID()
        let member = KanbanAvailability.Member(resourceID: resourceID, personID: ravi.id, start: nil, end: nil,
                                               absences: [], overrides: [:])
        return A.Snapshot(timeOff: timeOff, holidays: holidays, overrides: overrides,
                          board: .init(start: nil, end: nil, workWeekDays: [2, 3, 4, 5, 6]), members: [member])
    }

    private func planRows(_ operations: [[String: Any]], snapshot: A.Snapshot, people: [A.Person]? = nil) throws -> [A.PlanRow] {
        let extraction = try A.parse(operationsReply(operations), imageCount: 0, hasText: true)
        return A.review(extraction, people: people ?? [ravi], snapshot: snapshot, context: dateContext)
    }

    private func liveSnapshot(_ context: ModelContext, board: KanbanProject) throws -> A.Snapshot {
        let timeOff = try context.fetch(FetchDescriptor<KanbanTimeOff>()).map(KanbanTimeOffDTO.init)
        let holidays = try context.fetch(FetchDescriptor<KanbanHoliday>()).map(KanbanHolidayDTO.init)
        return A.Snapshot(project: board, timeOff: timeOff, holidays: holidays)
    }

    @Test("Schema 2 accepts all operation shapes and preserves groups; v1 remains readable")
    func schema2() throws {
        let operations = [
            timeOffOperation(group: "move"), timeOffOperation("removeTimeOff", group: "move"),
            operation("override", ["personText": ravi.name, "weekStart": "2026-10-19", "days": 3.5]),
            operation("override", ["personText": ravi.name, "weekStart": "2026-10-26", "days": NSNull()]),
            operation("holiday", ["date": "2026-10-21", "name": "Diwali", "portion": "full"]),
            operation("removeHoliday", ["date": "2026-10-20", "name": NSNull()]),
            operation("holidayException", ["personText": ravi.name, "date": "2026-10-20", "name": "Diwali", "works": true]),
        ]
        let extraction = try A.parse(operationsReply(operations), imageCount: 0, hasText: true)
        #expect(extraction.operations.count == operations.count && extraction.unresolved.isEmpty)
        #expect(extraction.operations[0].group == "move" && extraction.operations[1].group == "move")
        let old = try A.parse(reply(entry(ravi.name, "2026-10-20", "2026-10-20")), imageCount: 0, hasText: true)
        #expect(old.candidates.count == 1)
        let legacyRows = A.review(old, people: [ravi], snapshot: pureSnapshot(), context: dateContext)
        #expect(legacyRows.count == 1 && legacyRows[0].operations.count == 1)

        var instructed = timeOffOperation()
        instructed["sourceRef"] = "instructions"
        let fromInstructions = try A.parse(operationsReply([instructed]), imageCount: 0, hasText: false, hasInstructions: true)
        #expect(fromInstructions.operations.count == 1)
    }

    @Test("Schema 2 refuses extra keys, wrong JSON types, missing fields and unknown operations")
    func schema2Strict() throws {
        let valid = timeOffOperation()
        var extra = valid
        extra["deleteAll"] = true
        var wrongGroup = valid
        wrongGroup["group"] = 42
        var wrongIssues = valid
        wrongIssues["issues"] = "unsure"
        var missing = valid
        missing.removeValue(forKey: "kind")
        var unknown = valid
        unknown["op"] = "deleteAll"
        let wrongWorks = operation("holidayException", ["personText": ravi.name, "date": "2026-10-20",
                                                        "name": NSNull(), "works": 1])
        let wrongDays = operation("override", ["personText": ravi.name, "weekStart": "2026-10-19", "days": "3"])
        for invalid in [extra, wrongGroup, wrongIssues, missing, unknown, wrongWorks, wrongDays] {
            let document = try operationsReply([invalid])
            #expect(throws: A.ReplyError.self) { try A.parse(document, imageCount: 0, hasText: true) }
        }
        let invalidRoot = #"{"schemaVersion":2,"operations":[],"unresolved":[],"warnings":[],"execute":true}"#
        #expect(throws: A.ReplyError.self) { try A.parse(invalidRoot, imageCount: 0, hasText: true) }
        let invalidWarnings = #"{"schemaVersion":2,"operations":[],"unresolved":[],"warnings":"ignore"}"#
        #expect(throws: A.ReplyError.self) { try A.parse(invalidWarnings, imageCount: 0, hasText: true) }
    }

    @Test("Every operation applies through the service as one undoable change", arguments: [
        "timeOff", "removeTimeOff", "override", "clearOverride", "holiday", "removeHoliday", "holidayException", "clearHolidayException",
    ])
    func schema2Apply(_ name: String) throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: KanbanHistory())
        let board = try service.createProject(name: "Platform", key: "PLAT")
        let person = try service.createPerson(name: ravi.name, initials: ravi.initials)
        let member = try service.addMembership(person, to: board)
        let people = [A.Person(id: person.id, name: person.name, initials: person.initials, aliases: [], onBoard: true)]
        var op: [String: Any]
        switch name {
        case "removeTimeOff":
            try service.addTimeOff(.init(personId: person.id, startDay: "20261020", endDay: "20261020"), on: board)
            op = timeOffOperation("removeTimeOff")
        case "override", "clearOverride":
            if name == "clearOverride" { try service.setOverride(member, week: day("20261019"), halfDays: 6) }
            let days: Any = name == "clearOverride" ? NSNull() : 3.0
            op = operation("override", ["personText": person.name, "weekStart": "2026-10-19", "days": days])
        case "holiday":
            op = operation("holiday", ["date": "2026-10-20", "name": "Diwali", "portion": "full"])
        case "removeHoliday", "holidayException", "clearHolidayException":
            let workedBy = name == "clearHolidayException" ? [person.id] : nil
            try service.addHoliday(.init(day: "20261020", name: "Diwali", workedBy: workedBy), on: board)
            if name == "removeHoliday" {
                op = operation("removeHoliday", ["date": "2026-10-20", "name": "Diwali"])
            } else {
                op = operation("holidayException", ["personText": person.name, "date": "2026-10-20", "name": "Diwali",
                                                     "works": name == "holidayException"])
            }
        default:
            op = timeOffOperation()
        }
        let before = try liveSnapshot(context, board: board)
        var rows = try planRows([op], snapshot: before, people: people)
        #expect(rows.count == 1 && rows[0].isApplicable)
        for index in rows.indices { rows[index].selected = true }
        let plan = try A.plan(for: rows, snapshot: before, aliases: [:])
        #expect(!plan.delta.isEmpty)
        try service.applyAvailability(plan.delta, on: board, summary: "Updated availability")
        let after = try liveSnapshot(context, board: board)
        #expect(before != after)
        try service.undo(in: board)
        #expect(try liveSnapshot(context, board: board) == before)
        try service.redo(in: board)
        #expect(try liveSnapshot(context, board: board) == after)
    }

    @Test("A mixed request removes, adds and edits records in one undo entry")
    func mixedApply() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: KanbanHistory())
        let board = try service.createProject(name: "Platform", key: "PLAT")
        let person = try service.createPerson(name: ravi.name, initials: ravi.initials)
        _ = try service.addMembership(person, to: board)
        try service.addTimeOff(.init(personId: person.id, startDay: "20261021", endDay: "20261021"), on: board)
        try service.addHoliday(.init(day: "20261019", name: "Removed holiday"), on: board)
        try service.addHoliday(.init(day: "20261020", name: "Kept holiday"), on: board)
        let people = [A.Person(id: person.id, name: person.name, initials: person.initials, aliases: [], onBoard: true)]
        let before = try liveSnapshot(context, board: board)
        let operations = [
            operation("override", ["personText": person.name, "weekStart": "2026-11-02", "days": 4]),
            timeOffOperation(start: "2026-10-23", end: "2026-10-23"),
            timeOffOperation("removeTimeOff", start: "2026-10-21", end: "2026-10-21"),
            operation("holidayException", ["personText": person.name, "date": "2026-10-20", "name": "Kept holiday", "works": true]),
            operation("holiday", ["date": "2026-10-22", "name": "New holiday", "portion": "full"]),
            operation("removeHoliday", ["date": "2026-10-19", "name": "Removed holiday"]),
        ]
        var rows = try planRows(operations, snapshot: before, people: people)
        #expect(rows.count == 6 && rows.allSatisfy(\.isApplicable))
        for index in rows.indices { rows[index].selected = true }
        let plan = try A.plan(for: rows, snapshot: before, aliases: [:])
        #expect(plan.delta.timeOff.count == 2 && plan.delta.holidays.count == 3 && plan.delta.overrides.count == 1)
        try service.applyAvailability(plan.delta, on: board, summary: "Updated availability")
        let after = try liveSnapshot(context, board: board)
        #expect(after.timeOff.count == 1 && after.timeOff[0].startDay == "20261023")
        #expect(after.holidays.count == 2 && after.overrides.first?.halfDays == 8)
        try service.undo(in: board)
        #expect(try liveSnapshot(context, board: board) == before)
        try service.redo(in: board)
        #expect(try liveSnapshot(context, board: board) == after)
    }

    @Test("A grouped holiday move keeps its identity and every exception, including off-board people")
    func holidayMove() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: KanbanHistory())
        let board = try service.createProject(name: "Platform", key: "PLAT")
        let person = try service.createPerson(name: ravi.name, initials: ravi.initials)
        let offBoard = try service.createPerson(name: "Sam Lee", initials: "SL")
        _ = try service.addMembership(person, to: board)
        let people = [A.Person(id: person.id, name: person.name, initials: person.initials, aliases: [], onBoard: true)]
        let created = Date(timeIntervalSince1970: 100)
        let holiday = KanbanHolidayDTO(day: "20261020", name: "Diwali", workedBy: [person.id, offBoard.id], createdAt: created, updatedAt: created)
        try service.addHoliday(holiday, on: board)
        let snapshot = try liveSnapshot(context, board: board)
        let remove = operation("removeHoliday", ["date": "2026-10-20", "name": "Diwali"], group: "move")
        let add = operation("holiday", ["date": "2026-10-21", "name": NSNull(), "portion": "full"], group: "move")
        var rows = try planRows([remove, add], snapshot: snapshot, people: people)
        #expect(rows.count == 1 && !rows[0].selected && rows[0].isApplicable)
        rows[0].selected = true
        let plan = try A.plan(for: rows, snapshot: snapshot, aliases: [:])
        #expect(plan.delta.holidays.count == 1)
        let change = try #require(plan.delta.holidays.first)
        let moved = try #require(change.after)
        #expect(change.before == holiday && change.id == holiday.id && moved.id == holiday.id)
        #expect(moved.createdAt == created && moved.day == "20261021" && moved.name == "Diwali")
        #expect(Set(moved.workedBy ?? []) == [person.id, offBoard.id])
        try service.applyAvailability(plan.delta, on: board, summary: "Moved holiday")
        let after = try liveSnapshot(context, board: board)
        #expect(after.holidays == [moved])
        try service.undo(in: board)
        #expect(try liveSnapshot(context, board: board) == snapshot)
        try service.redo(in: board)
        #expect(try liveSnapshot(context, board: board) == after)
    }

    @Test("A grouped whole PTO move keeps identity, creation time, kind and private note")
    func timeOffMove() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let service = KanbanService(context, history: KanbanHistory())
        let board = try service.createProject(name: "Platform", key: "PLAT")
        let person = try service.createPerson(name: ravi.name, initials: ravi.initials)
        _ = try service.addMembership(person, to: board)
        let people = [A.Person(id: person.id, name: person.name, initials: person.initials, aliases: [], onBoard: true)]
        let created = Date(timeIntervalSince1970: 100)
        let recorded = KanbanTimeOffDTO(personId: person.id, startDay: "20261020", endDay: "20261020", kind: .training,
                                        note: "A private note", createdAt: created, updatedAt: created)
        try service.addTimeOff(recorded, on: board)
        let snapshot = try liveSnapshot(context, board: board)
        let remove = timeOffOperation("removeTimeOff", group: "move")
        let add = timeOffOperation(start: "2026-10-22", end: "2026-10-22", kind: NSNull(), group: "move")
        var rows = try planRows([remove, add], snapshot: snapshot, people: people)
        #expect(rows.count == 1 && rows[0].isApplicable && !rows[0].selected)
        rows[0].selected = true
        let plan = try A.plan(for: rows, snapshot: snapshot, aliases: [:])
        #expect(plan.delta.timeOff.count == 1)
        let change = try #require(plan.delta.timeOff.first)
        let moved = try #require(change.after)
        #expect(change.before == recorded && moved.id == recorded.id && moved.createdAt == created)
        #expect(moved.startDay == "20261022" && moved.endDay == "20261022")
        #expect(moved.kindRaw == "training" && moved.note == "A private note")
        try service.applyAvailability(plan.delta, on: board, summary: "Moved time off")
        let after = try liveSnapshot(context, board: board)
        #expect(after.timeOff == [moved])
        try service.undo(in: board)
        #expect(try liveSnapshot(context, board: board) == snapshot)
        try service.redo(in: board)
        #expect(try liveSnapshot(context, board: board) == after)
    }

    @Test("An alias and full name in one PTO move resolve to the same person")
    func aliasTimeOffMove() throws {
        let recorded = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020", kind: .training, note: "Private note")
        let snapshot = pureSnapshot(timeOff: [recorded])
        let remove = timeOffOperation("removeTimeOff", person: "Ravi K", group: "move")
        let add = timeOffOperation(person: ravi.name, start: "2026-10-22", end: "2026-10-22", kind: NSNull(), group: "move")
        var rows = try planRows([remove, add], snapshot: snapshot)
        #expect(rows.count == 1 && rows[0].personID == ravi.id && rows[0].status == .changes && !rows[0].selected)
        rows[0].selected = true
        let plan = try A.plan(for: rows, snapshot: snapshot, aliases: [:])
        let moved = try #require(plan.delta.timeOff.first?.after)
        #expect(plan.delta.timeOff.count == 1 && moved.id == recorded.id)
        #expect(moved.startDay == "20261022" && moved.kindRaw == "training" && moved.note == "Private note")
    }

    @Test("Every proposed time-off kind is visible and spoken in each review state", arguments: KanbanTimeOffKind.allCases)
    func timeOffKindPresentation(_ kind: KanbanTimeOffKind) throws {
        let states: [A.Status] = [.new, .alreadyRecorded, .overlaps, .unmatched, .needsReview("Confirm the dates.")]
        for state in states {
            var op = timeOffOperation(kind: kind.rawValue)
            var recorded: [KanbanTimeOffDTO] = []
            switch state {
            case .alreadyRecorded:
                recorded = [.init(personId: ravi.id, startDay: "20261020", endDay: "20261020", kind: kind)]
            case .overlaps:
                recorded = [.init(personId: ravi.id, startDay: "20261020", endDay: "20261020", portion: .am, kind: kind)]
            case .unmatched:
                op["personText"] = "Ravi"
            case .needsReview:
                op["issues"] = ["Confirm the dates."]
            default: break
            }
            let snapshot = pureSnapshot(timeOff: recorded)
            let row = try #require(try planRows([op], snapshot: snapshot).first)
            #expect(row.status == state)
            let detail = try #require(row.detail(snapshot: snapshot))
            #expect(detail.contains(kind.label))
            #expect(row.accessibilityLabel(snapshot: snapshot).contains(kind.label))
        }
        let snapshot = pureSnapshot()
        let invalidDates = timeOffOperation(start: "2026-02-30", kind: kind.rawValue)
        let row = try #require(try planRows([invalidDates], snapshot: snapshot).first)
        #expect(!row.isApplicable)
        let detail = try #require(row.detail(snapshot: snapshot))
        #expect(detail.contains(kind.label))
        #expect(row.accessibilityLabel(snapshot: snapshot).contains(kind.label))
        let recorded = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020", kind: kind)
        let removalSnapshot = pureSnapshot(timeOff: [recorded])
        let removal = timeOffOperation("removeTimeOff")
        let removalRow = try #require(try planRows([removal], snapshot: removalSnapshot).first)
        #expect(removalRow.status == .removals)
        let removalDetail = try #require(removalRow.detail(snapshot: removalSnapshot))
        #expect(removalDetail.contains(kind.label))
        #expect(removalRow.accessibilityLabel(snapshot: removalSnapshot).contains(kind.label))
    }

    @Test("A grouped move presents the actual replacement kind, including inheritance", arguments: [false, true])
    func groupedTimeOffKindPresentation(_ explicitKind: Bool) throws {
        let recorded = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020", kind: .training)
        let snapshot = pureSnapshot(timeOff: [recorded])
        let replacementKind: Any = explicitKind ? "sick" : NSNull()
        let remove = timeOffOperation("removeTimeOff", group: "move")
        let add = timeOffOperation(start: "2026-10-22", end: "2026-10-22", kind: replacementKind, group: "move")
        var row = try #require(try planRows([remove, add], snapshot: snapshot).first)
        let expectedKind: KanbanTimeOffKind = explicitKind ? .sick : .training
        #expect(row.status == .changes && !row.selected)
        let detail = try #require(row.detail(snapshot: snapshot))
        let destinationDetail = try #require(detail.components(separatedBy: "; ").first { $0.contains("2026-10-22") })
        #expect(destinationDetail.contains(expectedKind.label))
        #expect(row.accessibilityLabel(snapshot: snapshot).contains(expectedKind.label))
        row.selected = true
        let plan = try A.plan(for: [row], snapshot: snapshot)
        #expect(plan.delta.timeOff.first?.after?.kindRaw == expectedKind.rawValue)
    }

    @Test("Choosing a person resolves a partial and matched name in either move order", arguments: [false, true])
    func resolveGroupedTimeOffPerson(_ reverseOperations: Bool) throws {
        let recorded = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020", kind: .training,
                                        note: "Private note")
        let snapshot = pureSnapshot(timeOff: [recorded])
        let remove = timeOffOperation("removeTimeOff", person: "Ravi", group: "move")
        let add = timeOffOperation(start: "2026-10-22", end: "2026-10-22", kind: NSNull(), group: "move")
        let operations = reverseOperations ? [add, remove] : [remove, add]
        var row = try #require(try planRows(operations, snapshot: snapshot).first)
        #expect(!row.isApplicable && !row.selected)
        A.choosePerson(ravi.id, for: &row, people: [ravi], snapshot: snapshot)
        #expect(row.personID == ravi.id && row.samePerson && row.sourceTimeOffID == recorded.id)
        #expect(row.status == .changes && row.isApplicable && !row.selected && !row.offBoard)
        let detail = try #require(row.detail(snapshot: snapshot))
        #expect(detail.contains(KanbanTimeOffKind.training.label))
        #expect(row.accessibilityLabel(snapshot: snapshot).contains(KanbanTimeOffKind.training.label))
        row.selected = true
        row.rememberName = true
        let plan = try A.plan(for: [row], snapshot: snapshot)
        let change = try #require(plan.delta.timeOff.first)
        let moved = try #require(change.after)
        #expect(plan.delta.timeOff.count == 1 && change.before == recorded && moved.id == recorded.id)
        #expect(moved.personId == ravi.id && moved.startDay == "20261022" && moved.endDay == "20261022")
        #expect(moved.kindRaw == "training" && moved.note == recorded.note && moved.createdAt == recorded.createdAt)
        #expect(plan.delta.aliases.first?.after == ["Ravi"], "Remember the explicitly resolved name in either operation order")
        #expect(snapshot.timeOff == [recorded], "Planning leaves the source snapshot untouched")
    }

    @Test("Choosing a different person cannot override a grouped operation's known identity")
    func differentGroupedTimeOffChoice() throws {
        let recorded = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020", kind: .training)
        let snapshot = pureSnapshot(timeOff: [recorded])
        let remove = timeOffOperation("removeTimeOff", person: "Ravi", group: "move")
        let add = timeOffOperation(start: "2026-10-22", end: "2026-10-22", kind: NSNull(), group: "move")
        var row = try #require(try planRows([remove, add], snapshot: snapshot, people: [ravi, mia]).first)
        A.choosePerson(mia.id, for: &row, people: [ravi, mia], snapshot: snapshot)
        #expect(!row.samePerson && !row.isApplicable && !row.selected)
        guard case .needsReview = row.status else { Issue.record("Different identities must need review"); return }
        row.selected = true
        #expect(throws: A.ReplyError.self) { try A.plan(for: [row], snapshot: snapshot) }
        A.choosePerson(ravi.id, for: &row, people: [ravi, mia], snapshot: snapshot)
        #expect(row.samePerson && row.personID == ravi.id && row.sourceTimeOffID == recorded.id)
        #expect(row.status == .changes && !row.selected)
    }

    @Test("A group of two matched people still needs review after a picker choice", arguments: [false, true])
    func groupedTimeOffDifferentPeople(_ chooseOtherPerson: Bool) throws {
        let raviRecord = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020")
        let miaRecord = KanbanTimeOffDTO(personId: mia.id, startDay: "20261020", endDay: "20261020")
        let snapshot = pureSnapshot(timeOff: [raviRecord, miaRecord])
        let remove = timeOffOperation("removeTimeOff", group: "move")
        let add = timeOffOperation(person: mia.name, start: "2026-10-22", end: "2026-10-22", kind: NSNull(), group: "move")
        var row = try #require(try planRows([remove, add], snapshot: snapshot, people: [ravi, mia]).first)
        guard case .needsReview = row.status else { Issue.record("Two matched people must need review"); return }
        let chosenID = chooseOtherPerson ? mia.id : ravi.id
        A.choosePerson(chosenID, for: &row, people: [ravi, mia], snapshot: snapshot)
        #expect(!row.samePerson && !row.isApplicable && !row.selected)
        guard case .needsReview = row.status else { Issue.record("Picking cannot merge two matched people"); return }
        row.selected = true
        #expect(throws: A.ReplyError.self) { try A.plan(for: [row], snapshot: snapshot) }
    }

    @Test("Changing an unresolved move's person refreshes its source, inherited kind and board scope")
    func groupedTimeOffPersonRechoice() throws {
        let offBoard = A.Person(id: UUID(), name: "Sam Lee", initials: "SL", aliases: [], onBoard: false)
        let raviRecord = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020", kind: .training)
        let samRecord = KanbanTimeOffDTO(personId: offBoard.id, startDay: "20261020", endDay: "20261020", kind: .sick)
        let snapshot = pureSnapshot(timeOff: [raviRecord, samRecord])
        let people = [ravi, mia, offBoard]
        let remove = timeOffOperation("removeTimeOff", person: "Someone", group: "move")
        let add = timeOffOperation(person: "That person", start: "2026-10-22", end: "2026-10-22", kind: NSNull(), group: "move")
        var row = try #require(try planRows([remove, add], snapshot: snapshot, people: people).first)
        A.choosePerson(ravi.id, for: &row, people: people, snapshot: snapshot)
        #expect(row.personID == ravi.id && row.sourceTimeOffID == raviRecord.id && !row.offBoard)
        let raviDetail = try #require(row.detail(snapshot: snapshot))
        #expect(raviDetail.contains(KanbanTimeOffKind.training.label))
        A.choosePerson(offBoard.id, for: &row, people: people, snapshot: snapshot)
        #expect(row.personID == offBoard.id && row.sourceTimeOffID == samRecord.id && row.samePerson)
        #expect(row.status == .changes && row.offBoard && !row.selected)
        let samDetail = try #require(row.detail(snapshot: snapshot))
        #expect(samDetail.contains(KanbanTimeOffKind.sick.label) && !samDetail.contains(KanbanTimeOffKind.training.label))
        #expect(row.accessibilityLabel(snapshot: snapshot).contains(KanbanTimeOffKind.sick.label))
        row.selected = true
        let plan = try A.plan(for: [row], snapshot: snapshot)
        let moved = try #require(plan.delta.timeOff.first?.after)
        #expect(plan.delta.timeOff.count == 1 && moved.id == samRecord.id && moved.personId == offBoard.id)
        #expect(moved.startDay == "20261022" && moved.kindRaw == "sick")
        A.choosePerson(mia.id, for: &row, people: people, snapshot: snapshot)
        #expect(row.personID == mia.id && row.sourceTimeOffID == nil && !row.offBoard)
        #expect(!row.isApplicable && !row.selected, "A missing source cannot retain the previous person's move")
        guard case .needsReview = row.status else { Issue.record("A move without its source must need review"); return }
    }

    @Test("A move onto an existing identical record needs review and preserves both originals", arguments: ["holiday", "timeOff"])
    func moveDestinationCollision(_ kind: String) throws {
        let snapshot: A.Snapshot
        let operations: [[String: Any]]
        if kind == "holiday" {
            let original = KanbanHolidayDTO(day: "20261020", name: "Diwali", workedBy: [ravi.id])
            let destination = KanbanHolidayDTO(day: "20261021", name: "Diwali")
            snapshot = pureSnapshot(holidays: [original, destination])
            operations = [
                operation("removeHoliday", ["date": "2026-10-20", "name": "Diwali"], group: "move"),
                operation("holiday", ["date": "2026-10-21", "name": NSNull(), "portion": "full"], group: "move"),
            ]
        } else {
            let original = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020", note: "Keep my private note")
            let destination = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261021", endDay: "20261021")
            snapshot = pureSnapshot(timeOff: [original, destination])
            operations = [timeOffOperation("removeTimeOff", group: "move"),
                          timeOffOperation(start: "2026-10-21", end: "2026-10-21", kind: NSNull(), group: "move")]
        }
        var rows = try planRows(operations, snapshot: snapshot)
        #expect(rows.count == 1 && !rows[0].selected && !rows[0].isApplicable)
        guard case .needsReview = rows[0].status else { Issue.record("A destination collision must need review"); return }
        rows[0].selected = true
        #expect(throws: A.ReplyError.self) { try A.plan(for: rows, snapshot: snapshot, aliases: [:]) }
    }

    @Test("Grouped moves with conflicting sources or destinations clash", arguments: ["holiday", "timeOff", "inheritedKinds"])
    func conflictingMoves(_ kind: String) throws {
        let snapshot: A.Snapshot
        var operations: [[String: Any]] = []
        if kind == "holiday" {
            snapshot = pureSnapshot(holidays: [.init(day: "20261020", name: "Diwali")])
            for (group, destination) in [("first", "2026-10-21"), ("second", "2026-10-22")] {
                operations.append(operation("removeHoliday", ["date": "2026-10-20", "name": "Diwali"], group: group))
                operations.append(operation("holiday", ["date": destination, "name": NSNull(), "portion": "full"], group: group))
            }
        } else if kind == "inheritedKinds" {
            let training = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020", kind: .training)
            let sick = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261021", endDay: "20261021", kind: .sick)
            snapshot = pureSnapshot(timeOff: [training, sick])
            for (group, source) in [("first", "2026-10-20"), ("second", "2026-10-21")] {
                operations.append(timeOffOperation("removeTimeOff", start: source, end: source, group: group))
                operations.append(timeOffOperation(start: "2026-10-22", end: "2026-10-22", kind: NSNull(), group: group))
            }
        } else {
            snapshot = pureSnapshot(timeOff: [.init(personId: ravi.id, startDay: "20261020", endDay: "20261020")])
            for (group, destination) in [("first", "2026-10-21"), ("second", "2026-10-22")] {
                operations.append(timeOffOperation("removeTimeOff", group: group))
                operations.append(timeOffOperation(start: destination, end: destination, kind: NSNull(), group: group))
            }
        }
        var rows = try planRows(operations, snapshot: snapshot)
        #expect(rows.count == 2 && rows.allSatisfy(\.isApplicable))
        for index in rows.indices { rows[index].selected = true }
        #expect(A.clashingSelection(rows).count == 2)
        #expect(throws: A.ReplyError.self) { try A.plan(for: rows, snapshot: snapshot, aliases: [:]) }
    }

    @Test("Different people's holiday exceptions combine; opposing exceptions for one person clash")
    func holidayExceptionClashes() throws {
        let holiday = KanbanHolidayDTO(day: "20261020", name: "Diwali")
        let snapshot = pureSnapshot(holidays: [holiday])
        let raviWorks = operation("holidayException", ["personText": ravi.name, "date": "2026-10-20", "name": "Diwali", "works": true])
        let miaWorks = operation("holidayException", ["personText": mia.name, "date": "2026-10-20", "name": "Diwali", "works": true])
        var compatible = try planRows([raviWorks, miaWorks], snapshot: snapshot, people: [ravi, mia])
        let allOK1 = compatible.allSatisfy(\.isApplicable)
        #expect(allOK1)
        for index in compatible.indices { compatible[index].selected = true }
        #expect(A.clashingSelection(compatible).isEmpty)
        let combined = try A.plan(for: compatible, snapshot: snapshot, aliases: [:])
        let after = try #require(combined.delta.holidays.first?.after)
        #expect(Set(after.workedBy ?? []) == [ravi.id, mia.id])

        let raviOff = operation("holidayException", ["personText": ravi.name, "date": "2026-10-20", "name": "Diwali", "works": false])
        var opposing = try planRows([raviWorks, raviOff], snapshot: snapshot)
        // Both intended actions participate even though one matches the original record.
        for index in opposing.indices { opposing[index].status = .holidays; opposing[index].selected = true }
        #expect(A.clashingSelection(opposing).count == 2)
        #expect(throws: A.ReplyError.self) { try A.plan(for: opposing, snapshot: snapshot, aliases: [:]) }
    }

    @Test("Dates must use four, two and two ASCII digits", arguments: ["2026-1-020", "2026-+1-20", "2026-10-+2", "2026-010-2"])
    func strictISODates(_ malformed: String) throws {
        let document = try operationsReply([timeOffOperation(start: malformed, end: malformed)])
        let extraction = try A.parse(document, imageCount: 0, hasText: true)
        #expect(extraction.operations.count == 1 && extraction.operations[0].start == nil && !extraction.operations[0].issues.isEmpty)
        let rows = A.review(extraction, people: [ravi], snapshot: pureSnapshot(), context: dateContext)
        #expect(rows.count == 1 && !rows[0].isApplicable && !rows[0].selected)
    }

    @Test("A removal starts unticked and previews exact removed, kept and weekly records")
    func removalPreview() throws {
        let recorded = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261019", endDay: "20261023")
        let snapshot = pureSnapshot(timeOff: [recorded])
        let remove = timeOffOperation("removeTimeOff", start: "2026-10-21", end: "2026-10-21")
        var rows = try planRows([remove], snapshot: snapshot)
        #expect(rows.count == 1 && rows[0].status == .removals && !rows[0].selected)
        rows[0].selected = true
        let plan = try A.plan(for: rows, snapshot: snapshot, aliases: [:])
        let preview = try #require(plan.previews[rows[0].id])
        #expect(preview.removed == [recorded])
        #expect(preview.kept.map { "\($0.startDay)-\($0.endDay)" }.sorted() == ["20261019-20261020", "20261022-20261023"])
        let week = try #require(preview.weeks.first { $0.personID == ravi.id && $0.week == day("20261019") })
        #expect(week.before == 0 && week.after == 2)
        #expect(!plan.delta.isEmpty && !plan.impact.isEmpty)
        #expect(try A.plan(for: rows, snapshot: snapshot, aliases: [:]) == plan, "Repeated planning keeps the same record ids and timestamps")
    }

    @Test("Two selected removals preview the final kept pieces of their shared recorded week")
    func combinedRemovalPreview() throws {
        let recorded = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261019", endDay: "20261023")
        let snapshot = pureSnapshot(timeOff: [recorded])
        let tuesday = timeOffOperation("removeTimeOff", start: "2026-10-20", end: "2026-10-20")
        let thursday = timeOffOperation("removeTimeOff", start: "2026-10-22", end: "2026-10-22")
        var rows = try planRows([tuesday, thursday], snapshot: snapshot)
        #expect(rows.count == 2 && rows.allSatisfy { $0.status == .removals && !$0.selected })
        for index in rows.indices { rows[index].selected = true }
        let plan = try A.plan(for: rows, snapshot: snapshot, aliases: [:])
        let expected = ["20261019-20261019", "20261021-20261021", "20261023-20261023"]
        for row in rows {
            let preview = try #require(plan.previews[row.id])
            #expect(preview.removed == [recorded])
            #expect(preview.kept.map { "\($0.startDay)-\($0.endDay)" }.sorted() == expected)
            let week = try #require(preview.weeks.first { $0.personID == ravi.id && $0.week == day("20261019") })
            #expect(week.before == 0 && week.after == 4)
        }
        #expect(plan.delta.timeOff.compactMap(\.after).count == 3)
    }

    @Test("Selected holiday and override rows both preview the final holiday-aware plan")
    func combinedHolidayOverridePreview() throws {
        let snapshot = pureSnapshot()
        let holiday = operation("holiday", ["date": "2026-10-20", "name": "Diwali", "portion": "full"])
        let override = operation("override", ["personText": ravi.name, "weekStart": "2026-10-19", "days": 3])
        var rows = try planRows([holiday, override], snapshot: snapshot)
        #expect(rows.count == 2 && rows.allSatisfy(\.isApplicable))
        for index in rows.indices { rows[index].selected = true }
        let plan = try A.plan(for: rows, snapshot: snapshot, aliases: [:])
        #expect(plan.delta.holidays.count == 1 && plan.delta.overrides.first?.after?.halfDays == 6)
        for row in rows {
            let preview = try #require(plan.previews[row.id])
            let week = try #require(preview.weeks.first { $0.personID == ravi.id && $0.week == day("20261019") })
            #expect(week.before == 10 && week.after == 6)
        }
    }

    @Test("A group moving two holidays is ambiguous and cannot be applied")
    func ambiguousHolidayGroup() throws {
        let holidays = [KanbanHolidayDTO(day: "20261020", name: "First"), KanbanHolidayDTO(day: "20261021", name: "Second")]
        let snapshot = pureSnapshot(holidays: holidays)
        let operations = [
            operation("removeHoliday", ["date": "2026-10-20", "name": "First"], group: "both"),
            operation("removeHoliday", ["date": "2026-10-21", "name": "Second"], group: "both"),
            operation("holiday", ["date": "2026-10-22", "name": "First", "portion": "full"], group: "both"),
            operation("holiday", ["date": "2026-10-23", "name": "Second", "portion": "full"], group: "both"),
        ]
        let rows = try planRows(operations, snapshot: snapshot)
        #expect(rows.count == 1 && !rows[0].isApplicable && !rows[0].selected)
        guard case .needsReview = rows[0].status else { Issue.record("Ambiguous group must need review"); return }
    }

    @Test("A holiday name is required when two records share its date")
    func ambiguousHolidayDate() throws {
        let holidays = [KanbanHolidayDTO(day: "20261020", name: "First"), KanbanHolidayDTO(day: "20261020", name: "Second")]
        let snapshot = pureSnapshot(holidays: holidays)
        var rows = try planRows([operation("removeHoliday", ["date": "2026-10-20", "name": NSNull()])], snapshot: snapshot)
        #expect(rows.count == 1 && !rows[0].isApplicable)
        guard case .needsReview = rows[0].status else { Issue.record("Ambiguous holiday must need review"); return }
        rows[0].holidayID = holidays[1].id
        rows[0].status = A.reviewStatus(of: rows[0], snapshot: snapshot, context: dateContext)
        rows[0].selected = true
        let chosen = try A.plan(for: rows, snapshot: snapshot, aliases: [:])
        #expect(chosen.delta.holidays.count == 1 && chosen.delta.holidays.first?.id == holidays[1].id)
    }

    @Test("Overrides resolve to this board's membership and respect final holiday-aware capacity")
    func overrideLimits() throws {
        let offBoard = A.Person(id: UUID(), name: "Sam Lee", initials: "SL", aliases: [], onBoard: false)
        let override = operation("override", ["personText": offBoard.name, "weekStart": "2026-10-19", "days": 3])
        let unresolved = try planRows([override], snapshot: pureSnapshot(), people: [ravi, offBoard])
        #expect(unresolved.count == 1 && unresolved[0].status == .unmatched && !unresolved[0].isApplicable && !unresolved[0].selected)

        let holiday = operation("holiday", ["date": "2026-10-20", "name": "Diwali", "portion": "full"])
        let tooMuch = operation("override", ["personText": ravi.name, "weekStart": "2026-10-19", "days": 5])
        let snapshot = pureSnapshot()
        var rows = try planRows([holiday, tooMuch], snapshot: snapshot)
        for index in rows.indices { rows[index].selected = true }
        #expect(throws: (any Error).self) { try A.plan(for: rows, snapshot: snapshot, aliases: [:]) }
    }

    @Test("Two selected schema-2 rows that disagree on a half-day clash")
    func schema2Clash() throws {
        let snapshot = pureSnapshot()
        var rows = try planRows([timeOffOperation(), timeOffOperation(kind: "sick")], snapshot: snapshot)
        for index in rows.indices { rows[index].selected = true }
        #expect(throws: (any Error).self) { try A.plan(for: rows, snapshot: snapshot, aliases: [:]) }
    }

    @Test("Snapshot changes to time off, holidays and work days invalidate the review")
    func staleSnapshot() throws {
        let holiday = KanbanHolidayDTO(day: "20261020", name: "Diwali")
        let original = pureSnapshot(holidays: [holiday])
        try A.requireCurrent(original, current: original)
        var timeOffChanged = original
        timeOffChanged.timeOff = [.init(personId: ravi.id, startDay: "20261020", endDay: "20261020")]
        var holidayChanged = original
        holidayChanged.holidays[0].day = "20261021"
        var exceptionChanged = original
        exceptionChanged.holidays[0].workedBy = [ravi.id]
        var workDaysChanged = original
        workDaysChanged.board.workWeekDays = [2, 3, 4, 5]
        var membershipChanged = original
        membershipChanged.members[0].end = day("20261023")
        for current in [timeOffChanged, holidayChanged, exceptionChanged, workDaysChanged, membershipChanged] {
            #expect(throws: (any Error).self) { try A.requireCurrent(original, current: current) }
        }
    }

    @Test("The request bounds existing records to the window and board and never sends private notes")
    func boundedPayload() throws {
        let resourceID = UUID()
        let included = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261020", endDay: "20261020", note: "PRIVATE_PTO_NOTE")
        let outside = KanbanTimeOffDTO(personId: ravi.id, startDay: "20261201", endDay: "20261201")
        let elsewhere = KanbanTimeOffDTO(personId: mia2.id, startDay: "20261020", endDay: "20261020")
        let weekly = KanbanAvailabilityOverrideDTO(resourceId: resourceID, weekStart: "20261019", halfDays: 6, note: "PRIVATE_OVERRIDE_NOTE")
        let outsideWeek = KanbanAvailabilityOverrideDTO(resourceId: resourceID, weekStart: "20261207", halfDays: 6)
        let otherMember = KanbanAvailabilityOverrideDTO(resourceId: UUID(), weekStart: "20261019", halfDays: 6)
        let holiday = KanbanHolidayDTO(day: "20261020", name: "Diwali", workedBy: [ravi.id, mia2.id])
        let outsideHoliday = KanbanHolidayDTO(day: "20261225", name: "Outside holiday")
        let snapshot = pureSnapshot(timeOff: [included, outside, elsewhere], holidays: [holiday, outsideHoliday],
                                    overrides: [weekly, outsideWeek, otherMember])
        let data = A.payload(text: "Team PTO", imageCount: 0, context: dateContext, people: [ravi, mia2], snapshot: snapshot)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(included.id.uuidString) && text.contains(weekly.id.uuidString))
        #expect(text.contains(holiday.id.uuidString) && text.contains(ravi.name))
        #expect(!text.contains(outside.id.uuidString) && !text.contains(elsewhere.id.uuidString))
        #expect(!text.contains(outsideWeek.id.uuidString) && !text.contains(otherMember.id.uuidString))
        #expect(!text.contains(outsideHoliday.id.uuidString) && !text.contains(mia2.name))
        #expect(!text.contains("PRIVATE_PTO_NOTE") && !text.contains("PRIVATE_OVERRIDE_NOTE"))
        #expect(!text.contains("\"note\"") && !text.contains(mia2.id.uuidString))
    }

    @Test("Only ChatGPT catalog models have known image support unless explicitly marked unsupported")
    func imageCapability() {
        var model = SummaryModelOption(id: "gpt-5.5", label: "GPT-5.5", source: .catalog, supportedEfforts: nil, defaultEffort: nil)
        #expect(model.acceptsImages == nil)
        #expect(A.imageCapability(connection: .chatGPTAccount, model: model) == .supported)
        #expect(A.imageCapability(connection: .cliConfiguration, model: model) == .unknown)
        #expect(A.imageCapability(connection: .local(server: .ollama, baseURL: nil), model: model) == .unknown)
        model.source = .custom
        #expect(A.imageCapability(connection: .chatGPTAccount, model: model) == .unknown)
        model.source = .catalog
        model.acceptsImages = false
        #expect(A.imageCapability(connection: .chatGPTAccount, model: model) == .unsupported)
        #expect(A.imageCapability(connection: .local(server: .ollama, baseURL: nil), model: model) == .unsupported)
    }
}
