import Foundation
import Testing
import SwiftData
@testable import TickyTask

@Suite("Kanban Availability Backup (v2)")
struct KanbanAvailabilityBackupTests {

    // MARK: - KanbanBackupDTO v2 Round-trip

    @Test("Full backup with availability data encodes and decodes")
    func backupV2RoundTrip() throws {
        let personID = UUID()
        let projectID = UUID()
        let timeOffID = UUID()
        let overrideID = UUID()

        let timeOffDTO = KanbanTimeOffDTO(
            id: timeOffID, personId: personID, startDay: "20261018", endDay: "20261019",
            portion: .full, kind: .pto, note: "Vacation", origin: .manual,
            createdAt: Date(), updatedAt: Date()
        )

        let overrideDTO = KanbanAvailabilityOverrideDTO(
            id: overrideID, resourceId: UUID(), weekStart: "20261014",
            halfDays: 8, note: "Reduced hours", createdAt: Date(), updatedAt: Date()
        )

        var backup = KanbanBackupDTO()
        backup.version = 2
        backup.timeOff = [timeOffDTO]
        backup.availabilityOverrides = [overrideDTO]
        backup.people = [KanbanPersonDTO(id: personID, name: "Alice", initials: "A", aliases: ["Al", "Alice Smith"])]
        backup.projects = [KanbanProjectDTO(id: projectID, name: "Project", startDay: "20261018", endDay: "20261225")]

        let encoder = BackupCoding.encoder()
        let decoder = BackupCoding.decoder()
        let data = try encoder.encode(backup)
        let restored = try decoder.decode(KanbanBackupDTO.self, from: data)

        #expect(restored.version == 2)
        #expect(restored.timeOff?.count == 1)
        #expect(restored.timeOff?.first?.id == timeOffID)
        #expect(restored.availabilityOverrides?.count == 1)
        #expect(restored.availabilityOverrides?.first?.id == overrideID)
        #expect(restored.people.first?.aliases == ["Al", "Alice Smith"])
        #expect(restored.projects.first?.startDay == "20261018")
        #expect(restored.projects.first?.endDay == "20261225")
    }

    @Test("Availability data is deterministically sorted")
    func availabilitySortedDeterministically() throws {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let id3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        var backup = KanbanBackupDTO()
        backup.timeOff = [
            KanbanTimeOffDTO(id: id3, personId: nil, startDay: "20261020", endDay: "20261020"),
            KanbanTimeOffDTO(id: id1, personId: nil, startDay: "20261018", endDay: "20261018"),
            KanbanTimeOffDTO(id: id2, personId: nil, startDay: "20261019", endDay: "20261019")
        ]

        let sorted = backup.deterministicallySorted()

        #expect(sorted.timeOff?.count == 3)
        #expect(sorted.timeOff?[0].id == id1)
        #expect(sorted.timeOff?[1].id == id2)
        #expect(sorted.timeOff?[2].id == id3)
    }

    // MARK: - Backward Compatibility (v1 files)

    @Test("v1 backup without availability keys decodes successfully")
    func v1BackupBackwardCompatibility() throws {
        // Simulate a v1 backup JSON without availability keys
        let jsonData = """
        {
            "version": 1,
            "people": [],
            "projects": [],
            "columns": [],
            "resources": [],
            "labels": [],
            "tasks": [],
            "subtasks": [],
            "activities": []
        }
        """.data(using: .utf8)!

        let decoder = BackupCoding.decoder()
        let backup = try decoder.decode(KanbanBackupDTO.self, from: jsonData)

        #expect(backup.version == 1)
        #expect(backup.timeOff == nil)
        #expect(backup.availabilityOverrides == nil)
        #expect(backup.people.isEmpty)
    }

    @Test("v1 backup with partial availability data")
    func v1WithPartialAvailability() throws {
        let jsonData = """
        {
            "version": 1,
            "people": [],
            "projects": [],
            "columns": [],
            "resources": [],
            "labels": [],
            "tasks": [],
            "subtasks": [],
            "activities": [],
            "timeOff": null
        }
        """.data(using: .utf8)!

        let decoder = BackupCoding.decoder()
        let backup = try decoder.decode(KanbanBackupDTO.self, from: jsonData)

        #expect(backup.version == 1)
        #expect(backup.timeOff == nil)
    }

    // MARK: - DTO Field Validation

    @Test("KanbanPersonDTO with aliases encodes correctly")
    func personDTOWithAliases() throws {
        let person = KanbanPersonDTO(
            id: UUID(), name: "Bob", initials: "B", employmentRaw: "fte",
            skills: [], createdAt: Date(), archivedAt: nil
        )
        var mutable = person
        mutable.aliases = ["Bobby", "Robert"]

        let encoder = BackupCoding.encoder()
        let decoder = BackupCoding.decoder()
        let data = try encoder.encode(mutable)
        let restored = try decoder.decode(KanbanPersonDTO.self, from: data)

        #expect(restored.aliases == ["Bobby", "Robert"])
    }

    @Test("KanbanProjectDTO with board dates encodes correctly")
    func projectDTOWithBoardDates() throws {
        let project = KanbanProjectDTO(id: UUID(), name: "Sprint", key: "SPR", startDay: "20261018", endDay: "20261025")

        let encoder = BackupCoding.encoder()
        let decoder = BackupCoding.decoder()
        let data = try encoder.encode(project)
        let restored = try decoder.decode(KanbanProjectDTO.self, from: data)

        #expect(restored.startDay == "20261018")
        #expect(restored.endDay == "20261025")
    }

    @Test("TimeOffDTO meaning captures semantics without id/timestamps")
    func timeOffDTOMeaning() throws {
        let personID = UUID()
        let dto1 = KanbanTimeOffDTO(
            id: UUID(), personId: personID, startDay: "20261018", endDay: "20261019",
            portion: .full, kind: .pto, createdAt: Date(), updatedAt: Date()
        )
        let dto2 = KanbanTimeOffDTO(
            id: UUID(), personId: personID, startDay: "20261018", endDay: "20261019",
            portion: .full, kind: .pto, createdAt: Date(timeIntervalSinceNow: -1000), updatedAt: Date()
        )

        #expect(dto1.meaning == dto2.meaning)
    }
}

@Suite("Kanban Availability Board Transfer (v2)")
struct KanbanAvailabilityBoardTransferTests {

    @Test("Board transfer version is 2")
    func boardTransferVersion() {
        #expect(KanbanBoardTransfer.version == 2)
        #expect(KanbanBoardTransfer.format == "tickytask-board")
    }

    @Test("v2 board file envelope encodes/decodes")
    func boardFileEnvelopeV2() throws {
        let envelope = KanbanBoardTransfer.Envelope(
            format: "tickytask-board", version: 2,
            kanban: KanbanBackupDTO()
        )

        let encoder = BackupCoding.encoder()
        let decoder = BackupCoding.decoder()
        let data = try encoder.encode(envelope)
        let restored = try decoder.decode(KanbanBoardTransfer.Envelope.self, from: data)

        #expect(restored.version == 2)
        #expect(restored.format == "tickytask-board")
    }

    @Test("v1 board file still decodes (backward compatibility)")
    func v1BoardFileBackwardCompatibility() throws {
        let envelope = KanbanBoardTransfer.Envelope(
            format: "tickytask-board", version: 1,
            kanban: KanbanBackupDTO(version: 1)
        )

        let encoder = BackupCoding.encoder()
        let decoder = BackupCoding.decoder()
        let data = try encoder.encode(envelope)
        let restored = try decoder.decode(KanbanBoardTransfer.Envelope.self, from: data)

        #expect(restored.version == 1)
        #expect(restored.kanban.version == 1)
        #expect(restored.kanban.timeOff == nil)
    }
}

@Suite("Kanban Availability CSV Export")
struct KanbanAvailabilityCSVTests {

    @Test("CSV header is present and complete")
    func csvHeaderComplete() {
        let csv = "Board ID,Board,Person ID,Person,Membership ID,Week Start,Week End,Possible Days,Computed Days,Override Days,Effective Days,Allocation %,Status\r\n"
        let lines = csv.split(separator: "\r\n", omittingEmptySubsequences: false)
        let header = String(lines[0])

        #expect(header.contains("Board ID"))
        #expect(header.contains("Person"))
        #expect(header.contains("Week Start"))
        #expect(header.contains("Possible Days"))
        #expect(header.contains("Allocation %"))
        #expect(header.contains("Status"))
    }

    @Test("CSV quoting escapes formulas")
    func csvQuotingFormulas() {
        let dangerous = "=SUM(1,2)"
        let quoted = KanbanAvailabilityCSV.quote(dangerous)

        #expect(quoted.hasPrefix("'="))
    }

    @Test("CSV quoting escapes commas")
    func csvQuotingCommas() {
        let withComma = "Smith, Jr."
        let quoted = KanbanAvailabilityCSV.quote(withComma)

        #expect(quoted.hasPrefix("\""))
        #expect(quoted.hasSuffix("\""))
    }

    @Test("CSV quoting escapes quotes")
    func csvQuotingQuotes() {
        let withQuote = "Alice \"Bob\" Smith"
        let quoted = KanbanAvailabilityCSV.quote(withQuote)

        #expect(quoted.contains("\"\""))
    }

    @Test("CSV line ends with CRLF")
    func csvLineEndings() {
        let csv = "A,B\r\nC,D\r\n"

        #expect(csv.contains("\r\n"))
        #expect(!csv.contains("\n\n"))
    }
}

@Suite("Kanban Availability Backup Diff")
struct KanbanAvailabilityBackupDiffTests {

    @Test("EntityDiff for availability data")
    func availabilityEntityDiff() {
        let imported = Set([UUID(), UUID()])
        let existing = Set([UUID()])

        let diff = EntityDiff(imported: imported, existing: existing)

        #expect(diff.added == 1)
        #expect(diff.updated == 0)
        #expect(diff.removed == 1)
    }

    @Test("KanbanBackupDiff totals include availability")
    func backupDiffTotals() {
        let timeOffDiff = EntityDiff(imported: Set([UUID()]), existing: Set())
        let overrideDiff = EntityDiff(imported: Set([UUID(), UUID()]), existing: Set([UUID()]))
        let emptyDiff = EntityDiff(imported: Set(), existing: Set())

        let diff = KanbanBackupDiff(
            people: emptyDiff, projects: emptyDiff, columns: emptyDiff,
            resources: emptyDiff, labels: emptyDiff, tasks: emptyDiff,
            subtasks: emptyDiff, activities: emptyDiff,
            timeOff: timeOffDiff, availabilityOverrides: overrideDiff,
            droppedDependencyEdges: 0
        )

        #expect(diff.totalAdded == 3)
        #expect(diff.totalUpdated == 1)
        #expect(diff.totalRemoved == 1)
    }
}
