import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// The release gate for v0.4.0: a store written by v0.3.0 itself (Fixtures/KanbanStores/v0.3.0,
/// synthetic data, made by the tagged build into an explicit path) opens with this schema by
/// lightweight migration, keeps its board dates, time off, overrides and remembered names, has
/// no holidays, and then saves and reopens holidays. Only disposable copies are opened.
@MainActor
@Suite("Kanban v0.3.0 store migration gate", .serialized)
struct KanbanV030MigrationGateTests {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/KanbanStores/v0.3.0", isDirectory: true)

    private struct Manifest: Decodable {
        var platform: UUID
        var data: UUID
        var ravi: UUID
        var mia: UUID
        var raviOnPlatform: UUID
        var raviOff: UUID
        var miaAfternoon: UUID
    }

    @Test("A v0.3.0 store migrates with its availability intact, then keeps holidays across a reopen")
    func migrates() throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.folder.appendingPathComponent("manifest.json")))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskV030-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("TickyTask.store")
        try FileManager.default.copyItem(at: Self.folder.appendingPathComponent("TickyTask.store"), to: url)
        do {
            let context = ModelContext(try ModelContainerProvider.makeContainer(at: url))
            let boards = try context.fetch(FetchDescriptor<KanbanProject>())
            let platform = try #require(boards.first { $0.id == manifest.platform })
            #expect(Set(boards.map(\.id)) == [manifest.platform, manifest.data])
            #expect(platform.startDay == "20261005" && platform.endDay == "20261127")
            #expect(try context.fetchCount(FetchDescriptor<KanbanTask>()) == 2)
            #expect(try context.fetchCount(FetchDescriptor<KanbanActivity>()) == 10)
            #expect(try context.fetchCount(FetchDescriptor<KanbanHoliday>()) == 0, "the new table starts empty")
            let ravi = try #require(try context.fetch(FetchDescriptor<KanbanPerson>()).first { $0.id == manifest.ravi })
            #expect(ravi.aliases == ["Ravi K"] && ravi.timeOff.map(\.id) == [manifest.raviOff])
            let mia = try #require(try context.fetch(FetchDescriptor<KanbanPerson>()).first { $0.id == manifest.mia })
            let afternoon = try #require(mia.timeOff.first)
            #expect(afternoon.id == manifest.miaAfternoon && afternoon.portion == .pm && afternoon.kind == .training)
            let membership = try #require(platform.resources.first { $0.id == manifest.raviOnPlatform })
            #expect(membership.availabilityOverrides.first?.halfDays == 6 && membership.availabilityOverrides.first?.note == "Conference")

            // v0.3.0's change log still undoes, and holidays apply on the migrated store.
            let s = KanbanService(context, history: KanbanHistory())
            try s.addHoliday(KanbanHolidayDTO(day: "20261021", name: "Diwali", workedBy: [manifest.mia]), on: platform)
            let cell = KanbanAvailability.cell(week: KanbanDay(key: "20261019")!, board: .init(platform), member: .init(membership), holidays: try s.holidays())
            #expect(cell.possibleHalfDays == 8 && cell.absentHalfDays == 2, "Wednesday is a holiday; Tuesday is still off")
        }
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: url))
        let holiday = try #require(try context.fetch(FetchDescriptor<KanbanHoliday>()).first)
        #expect(holiday.name == "Diwali" && holiday.workedBy == [manifest.mia])
        #expect(try context.fetchCount(FetchDescriptor<KanbanTimeOff>()) == 2)
    }
}
