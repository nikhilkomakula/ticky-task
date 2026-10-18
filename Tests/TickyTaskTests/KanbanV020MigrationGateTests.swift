import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// The release gate for v0.3.0: a store written by v0.2.0 itself (Fixtures/KanbanStores/v0.2.0,
/// synthetic data, made by the tagged build into an explicit path) opens with this schema by
/// lightweight migration, keeps every Kanban row and relationship, reads the new fields as
/// unset, and then saves and reopens availability. Only disposable copies are opened.
@MainActor
@Suite("Kanban v0.2.0 store migration gate", .serialized)
struct KanbanV020MigrationGateTests {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/KanbanStores/v0.2.0", isDirectory: true)

    private struct Manifest: Decodable {
        var api: UUID
        var boards: [UUID]
        var mia: UUID
        var ravi: UUID
        var raviOnPlatform: UUID
    }

    private func copy() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskV020-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("TickyTask.store")
        try FileManager.default.copyItem(at: Self.folder.appendingPathComponent("TickyTask.store"), to: store)
        return (store, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("A v0.2.0 store migrates with every Kanban row and link, then keeps availability across a reopen")
    func migrates() throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.folder.appendingPathComponent("manifest.json")))
        let (url, cleanup) = try copy()
        defer { cleanup() }
        do {
            let context = ModelContext(try ModelContainerProvider.makeContainer(at: url))
            #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 3)
            #expect(try context.fetchCount(FetchDescriptor<CustomList>()) == 1)
            let boards = try context.fetch(FetchDescriptor<KanbanProject>())
            #expect(Set(boards.map(\.id)) == Set(manifest.boards))
            #expect(boards.allSatisfy { $0.startDay == nil && $0.endDay == nil }, "new fields read as unset")
            #expect(try context.fetchCount(FetchDescriptor<KanbanResource>()) == 3)
            #expect(try context.fetchCount(FetchDescriptor<KanbanActivity>()) == 13)
            #expect(try context.fetchCount(FetchDescriptor<KanbanTimeOff>()) == 0)
            let api = try #require(try context.fetch(FetchDescriptor<KanbanTask>()).first { $0.id == manifest.api })
            #expect(api.priority == 2 && api.isCritical && api.estimateHours == 6 && api.complexity == 3 && api.isBlocked)
            #expect(api.labels.count == 2 && api.subtasks.count == 1 && api.resource?.id == manifest.raviOnPlatform)
            #expect(api.column?.symbolName == "sparkles")
            let docs = try #require(try context.fetch(FetchDescriptor<KanbanTask>()).first { $0.title == "Write docs" })
            #expect(docs.dependsOn.map(\.id) == [manifest.api])
            let mia = try #require(try context.fetch(FetchDescriptor<KanbanPerson>()).first { $0.id == manifest.mia })
            #expect(mia.memberships.count == 2 && mia.aliases == nil && mia.timeOff.isEmpty)

            // Availability on the migrated store, through the service.
            let s = KanbanService(context, history: KanbanHistory())
            let platform = try #require(api.project)
            try s.editBoardDetails(platform, name: platform.name, startDay: "20261005", endDay: "20261127")
            try s.addTimeOff(KanbanTimeOffDTO(personId: manifest.ravi, startDay: "20261020", endDay: "20261021"), on: platform)
            let membership = try #require(platform.resources.first { $0.id == manifest.raviOnPlatform })
            try s.setOverride(membership, week: KanbanDay(key: "20261012")!, halfDays: 6)
        }
        // Reopened from disk: everything stayed.
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: url))
        let platform = try #require(try context.fetch(FetchDescriptor<KanbanProject>()).first { $0.startDay != nil })
        #expect(platform.startDay == "20261005" && platform.endDay == "20261127")
        let ravi = try #require(try context.fetch(FetchDescriptor<KanbanPerson>()).first { $0.id == manifest.ravi })
        #expect(ravi.timeOff.count == 1 && ravi.memberships.first { $0.id == manifest.raviOnPlatform }?.availabilityOverrides.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<KanbanTask>()) == 3)
    }
}
