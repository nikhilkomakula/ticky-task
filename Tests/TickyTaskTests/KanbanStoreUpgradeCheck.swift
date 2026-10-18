import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// A one-off check before a release, run only when `UPGRADE_STORE_COPY` names a store file:
/// opens that copy (never the live store) with this version's schema, so automatic lightweight
/// migration runs on real data, and writes the row counts beside it for comparison.
@MainActor
@Suite("Store upgrade check (opt-in)")
struct KanbanStoreUpgradeCheck {
    @Test("A copied store opens with the new schema and keeps every row")
    func upgradeCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["UPGRADE_STORE_COPY"] else { return }
        let url = URL(fileURLWithPath: path)
        let live = try ModelContainerProvider.defaultStoreURL().standardizedFileURL
        guard url.standardizedFileURL != live, !url.path.hasPrefix(live.deletingLastPathComponent().path),
              !url.path.contains("/Library/Application Support/TickyTask") else {
            Issue.record("Refusing to open the live store")
            return
        }
        let context = ModelContext(try ModelContainerProvider.makeContainer(at: url))
        let counts = [
            "ZTASKITEM": try context.fetchCount(FetchDescriptor<TaskItem>()),
            "ZCUSTOMLIST": try context.fetchCount(FetchDescriptor<CustomList>()),
            "ZKANBANPROJECT": try context.fetchCount(FetchDescriptor<KanbanProject>()),
            "ZKANBANCOLUMN": try context.fetchCount(FetchDescriptor<KanbanColumn>()),
            "ZKANBANTASK": try context.fetchCount(FetchDescriptor<KanbanTask>()),
            "ZKANBANPERSON": try context.fetchCount(FetchDescriptor<KanbanPerson>()),
            "ZKANBANRESOURCE": try context.fetchCount(FetchDescriptor<KanbanResource>()),
            "ZKANBANACTIVITY": try context.fetchCount(FetchDescriptor<KanbanActivity>()),
            "ZKANBANTIMEOFF": try context.fetchCount(FetchDescriptor<KanbanTimeOff>()),
        ]
        // The new fields read as unset.
        let boards = try context.fetch(FetchDescriptor<KanbanProject>())
        #expect(boards.allSatisfy { $0.startDay == nil && $0.endDay == nil })
        let text = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("upgrade-counts.txt"))
    }
}
