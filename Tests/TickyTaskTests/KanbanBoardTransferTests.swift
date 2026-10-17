import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Board export and import between two stores (design 01 §7), on in-memory containers.
@MainActor
@Suite("Kanban board transfer", .serialized)
struct KanbanBoardTransferTests {
    typealias T = KanbanBoardTransfer

    /// A board on one "Mac": Ravi and Mia (Mia later archived), labelled cards in each column,
    /// a dependency, a step assigned to Ravi.
    private func source() throws -> (ModelContext, KanbanProject) {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context)
        let project = try s.createProject(name: "Platform", key: "PLAT", template: .software)
        let ravi = try s.addMembership(try s.createPerson(name: "Ravi", initials: "RV"), to: project)
        let mia = try s.addMembership(try s.createPerson(name: "Mia", initials: "MI", employment: .contractor), to: project, allocationPercent: 50)
        let columns = project.orderedColumns
        let api = try s.createTask(in: project, title: "Build API", column: columns[2], row: .resource(ravi.id))
        let docs = try s.createTask(in: project, title: "Write docs", column: columns[1], row: .resource(mia.id))
        let shipped = try s.createTask(in: project, title: "Shipped", column: columns.last!, row: .resource(ravi.id))
        try s.setLabels(api, [project.labels.sorted { $0.sortIndex < $1.sortIndex }[0]])
        try s.setDependencies(docs, [api])
        let step = try s.addSubtask(to: api, title: "Endpoints")
        _ = step
        try s.archiveMembership(mia)
        _ = shipped
        return (context, project)
    }

    private func fresh() -> ModelContext { ModelContext(ModelContainerProvider.makeInMemoryContainer()) }

    @Test("Export then import into an empty store reproduces the board")
    func roundTrip() throws {
        let (from, project) = try source()
        let data = try T.export([project], context: from)
        let to = fresh()
        let plan = try T.plan(data, context: to)
        #expect(plan.boards.map(\.name) == ["Platform"] && plan.people.count == 2, "the archived member's person travels too")
        #expect(plan.people.allSatisfy { $0.match == .none && $0.linkTo == nil })
        try T.apply(plan, fileName: "platform.tickytask-board", context: to)
        let board = try #require(try to.fetch(FetchDescriptor<KanbanProject>()).first)
        #expect(board.id != project.id, "imported rows get fresh ids")
        #expect(board.orderedColumns.map(\.name) == project.orderedColumns.map(\.name))
        #expect(Set(board.tasks.map(\.title)) == ["Build API", "Write docs", "Shipped"])
        let api = try #require(board.tasks.first { $0.title == "Build API" })
        #expect(api.column?.name == "In Progress" && api.resource?.displayName == "Ravi" && api.labels.count == 1 && api.subtasks.count == 1)
        #expect(board.tasks.first { $0.title == "Write docs" }?.dependsOn.map(\.title) == ["Build API"])
        #expect(board.tasks.first { $0.title == "Write docs" }?.resource == nil, "Mia's membership is archived, so her card is Unassigned")
        #expect(board.tasks.first { $0.title == "Shipped" }?.completedAt != nil)
        #expect(board.resources.count == 2 && board.resources.filter { $0.archivedAt != nil }.count == 1)
        let entries = board.activities
        #expect(entries.map(\.summary) == ["Imported from platform.tickytask-board"] && entries.first?.seq == 1 && board.nextActivitySeq == 2)
        #expect(!KanbanService.offersRevert(try #require(entries.first)), "the import note isn't revertible")
    }

    @Test("A taken key is renamed; people match by id, then by name")
    func keysAndPeople() throws {
        let (from, project) = try source()
        let data = try T.export([project], context: from)
        // The same store already has this board and these people: ids match.
        let same = try T.plan(data, context: from)
        #expect(same.boards.first?.key == "PLAT2" && same.boards.first?.keyWasTaken == true)
        #expect(same.people.allSatisfy { $0.match == .sameID })
        // Another store with a different "Ravi": a name match, linked by default.
        let to = fresh()
        let other = KanbanService(to)
        let ravi = try other.createPerson(name: " ravi ", initials: "R")
        let plan = try T.plan(data, context: to)
        #expect(plan.people.first { $0.name == "Ravi" }?.linkTo == ravi.id)
        try T.apply(plan, fileName: "f", context: to)
        #expect(try to.fetch(FetchDescriptor<KanbanPerson>()).count == 2, "Ravi linked, Mia created")
    }

    @Test("Merging into an existing board matches columns and reuses memberships")
    func mergeInto() throws {
        let (from, project) = try source()
        let data = try T.export([project], context: from)
        var plan = try T.plan(data, context: from)
        plan.boards[0].mergeInto = project.id
        let before = project.tasks.count
        try T.apply(plan, fileName: "again", context: from)
        #expect(project.tasks.count == before * 2)
        #expect(project.orderedColumns.count == 5, "every column matched by name and kind")
        #expect(project.resources.filter { $0.archivedAt == nil }.count == 1, "Ravi's existing membership is reused")
        let copies = project.tasks.filter { $0.title == "Build API" }
        #expect(copies.count == 2 && Set(copies.map(\.sortIndex)).count == 2, "appended in the cell, not on top of the original")
        #expect(project.activities.contains { $0.summary == "Imported from again" })
    }

    @Test("Bad files are refused before anything is written")
    func refusals() throws {
        let (from, project) = try source()
        let data = try T.export([project], context: from)
        let to = fresh()
        #expect(throws: T.TransferError.notABoardFile) { try T.plan(Data("{}".utf8), context: to) }
        var envelope = try BackupCoding.decoder().decode(T.Envelope.self, from: data)
        envelope.version = 99
        #expect(throws: T.TransferError.newerVersion) { try T.plan(try BackupCoding.encoder().encode(envelope), context: to) }
        envelope.version = 1
        envelope.kanban.people.removeAll { $0.name == "Mia" }
        #expect(throws: T.TransferError.missingPerson("Platform")) { try T.plan(try BackupCoding.encoder().encode(envelope), context: to) }
        var plan = try T.plan(data, context: to)
        plan.boards[0].mergeInto = UUID()
        #expect(throws: T.TransferError.noSuchBoard) { try T.apply(plan, fileName: "x", context: to) }
        #expect(try to.fetchCount(FetchDescriptor<KanbanProject>()) == 0 && to.fetchCount(FetchDescriptor<KanbanPerson>()) == 0)
    }

    @Test("CSV quotes fields and neutralises formulas")
    func csv() throws {
        let (_, project) = try source()
        let text = T.csv(project)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines.first == "Title,Column,Assignee,Priority,Critical,Due,Start,Estimate (h),Labels,Jira,Blocked,Subtasks")
        #expect(lines.count == 5 && lines.last == "", "three cards and a trailing line end")
        #expect(T.quote("a,b") == "\"a,b\"" && T.quote("say \"hi\"") == "\"say \"\"hi\"\"\"" && T.quote("=SUM(A1)") == "'=SUM(A1)")
    }

    @Test("Someone archived here keeps no active membership: it arrives archived, its cards Unassigned")
    func archivedPersonImportsArchived() throws {
        let (from, project) = try source()
        let data = try T.export([project], context: from)
        let ravi = try #require(project.resources.first { $0.displayName == "Ravi" }?.person)
        _ = try KanbanService(from).archivePerson(ravi)
        let plan = try T.plan(data, context: from)
        #expect(plan.people.first { $0.name == "Ravi" }?.linkTo == ravi.id, "still the same person, by id")
        let boards = try T.apply(plan, fileName: "old", context: from)
        let imported = try #require(boards.first)
        let memberships = imported.resources.filter { $0.person?.id == ravi.id }
        #expect(!memberships.isEmpty && memberships.allSatisfy { $0.archivedAt != nil })
        let api = try #require(imported.tasks.first { $0.title == "Build API" })
        #expect(api.resource == nil, "a live card isn't left on an archived membership")
    }

    @Test("The preview carries the validator's repairs and the memberships a merge reuses")
    func previewRepairsAndReuse() throws {
        let (from, project) = try source()
        let data = try T.export([project], context: from)
        var envelope = try BackupCoding.decoder().decode(T.Envelope.self, from: data)
        let docs = try #require(envelope.kanban.tasks.first { $0.title == "Write docs" })
        let api = try #require(envelope.kanban.tasks.firstIndex { $0.title == "Build API" })
        envelope.kanban.tasks[api].dependsOnIds.append(docs.id)   // closes a loop with docs → api
        let plan = try T.plan(try BackupCoding.encoder().encode(envelope), context: from)
        #expect(plan.report.droppedDependencyEdges == 1)
        let board = try #require(plan.boards.first)
        #expect(plan.reusedMemberships(board, into: project) == ["Ravi"], "Mia's membership in the file is archived")
        #expect(plan.reusedMemberships(board, into: try KanbanService(from).createProject(name: "Empty", key: "EMP")).isEmpty)
        #expect(plan.reusedMemberships(board, into: nil).isEmpty, "a new board: everyone gets their own row")
        // Mia linked to Ravi here: two people in the file, one person on the board.
        var linked = plan
        let mia = try #require(linked.people.firstIndex { $0.name == "Mia" })
        linked.people[mia].linkTo = linked.people.first { $0.name == "Ravi" }?.linkTo
        var miaActive = linked.kanban
        for i in miaActive.resources.indices where miaActive.resources[i].personId == linked.people[mia].id { miaActive.resources[i].archivedAt = nil }
        linked.kanban = miaActive
        #expect(linked.reusedMemberships(board, into: nil) == ["Mia"], "the second one linked to Ravi joins his membership")
    }

    @Test("Formulas behind leading whitespace or control characters are neutralised too")
    func csvControlPrefixes() {
        for field in ["\t=1+1", "\r=1+1", " =1+1", "\u{0B}@SUM(A1)", "\t"] {
            #expect(T.quote(field).hasPrefix("'") || T.quote(field).hasPrefix("\"'"), "\(field.debugDescription)")
        }
        #expect(T.quote("Plain title") == "Plain title" && T.quote("x = 1") == "x = 1")
    }
}
