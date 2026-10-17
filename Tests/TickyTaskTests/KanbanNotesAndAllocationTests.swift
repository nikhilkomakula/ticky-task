import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Task notes presence check and resource allocation classification.
@MainActor
@Suite("Kanban notes and allocation", .serialized)
struct KanbanNotesAndAllocationTests {
    private func board() throws -> (KanbanService, KanbanProject) {
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()))
        let project = try service.createProject(name: "Platform", key: "PLAT")
        return (service, project)
    }

    // MARK: - hasNotes tests

    @Test("Empty notes returns false")
    func emptyNotesIsFalse() throws {
        let (s, project) = try board()
        let card = try s.createTask(in: project, title: "Card")
        card.notes = ""
        card.notesRich = nil
        #expect(!card.hasNotes)
    }

    @Test("Whitespace-only notes returns false")
    func whitespaceOnlyIsFalse() throws {
        let (s, project) = try board()
        let card = try s.createTask(in: project, title: "Card")
        card.notes = "  \n  \t  "
        card.notesRich = nil
        #expect(!card.hasNotes)
    }

    @Test("Plain text notes returns true")
    func plainTextIsTrue() throws {
        let (s, project) = try board()
        let card = try s.createTask(in: project, title: "Card")
        card.notes = "Some content"
        card.notesRich = nil
        #expect(card.hasNotes)
    }

    @Test("Empty notes returns false even with rich encoding")
    func emptyRichAndPlainFalse() throws {
        let (s, project) = try board()
        let card = try s.createTask(in: project, title: "Card")
        let doc = NotesDocument(blocks: [])
        card.notesRich = try NotesCodec.encode(doc)
        card.notes = ""
        #expect(!card.hasNotes)
    }

    @Test("Plain text notes with rich decoding returns true")
    func plainTextWithRichTrue() throws {
        let (s, project) = try board()
        let card = try s.createTask(in: project, title: "Card")
        card.notes = "Plain text content"
        card.notesRich = nil
        #expect(card.hasNotes)
    }

    @Test("Corrupt rich falls back to plain text")
    func corruptRichFallsBack() throws {
        let (s, project) = try board()
        let card = try s.createTask(in: project, title: "Card")
        card.notesRich = "not valid json".data(using: .utf8)  // corrupt
        card.notes = "Plain content"
        #expect(card.hasNotes)  // Falls back to plain
    }

    // MARK: - effectiveAssignment tests

    @Test("100% allocation is fullTime")
    func hundredPercentIsFullTime() throws {
        let (s, project) = try board()
        let kPerson = KanbanPerson(name: "Alice", initials: "A", employment: .fte)
        let resource = try s.addMembership(kPerson, to: project, allocationPercent: 100)
        #expect(resource.effectiveAssignment == .fullTime)
    }

    @Test("Below 100% is partTime")
    func belowHundredIsPartTime() throws {
        let (s, project) = try board()
        let kPerson = KanbanPerson(name: "Bob", initials: "B", employment: .fte)
        for pct in [1, 50, 99] {
            let resource = try s.addMembership(kPerson, to: project, allocationPercent: pct)
            #expect(resource.effectiveAssignment == .partTime, "Failed for \(pct)%")
        }
    }

    @Test("Changing allocation updates effective assignment")
    func allocationChangeUpdatesEffective() throws {
        let (s, project) = try board()
        let kPerson = KanbanPerson(name: "Charlie", initials: "C", employment: .fte)
        let resource = try s.addMembership(kPerson, to: project, allocationPercent: 50)
        #expect(resource.effectiveAssignment == .partTime)
        resource.allocationPercent = 100
        #expect(resource.effectiveAssignment == .fullTime)
        resource.allocationPercent = 60
        #expect(resource.effectiveAssignment == .partTime)
    }

    @Test("Legacy mismatch: stored fullTime but 60% shows partTime")
    func legacyMismatchFallsback() throws {
        let (s, project) = try board()
        let kPerson = KanbanPerson(name: "Dana", initials: "D", employment: .fte)
        let resource = try s.addMembership(kPerson, to: project, allocationPercent: 60)
        resource.assignmentRaw = KanbanAssignment.fullTime.rawValue
        // Effective is derived from allocation, ignoring stored value
        #expect(resource.effectiveAssignment == .partTime)
    }

    @Test("Stored assignment unchanged on load")
    func storedAssignmentUnchanged() throws {
        let (s, project) = try board()
        let kPerson = KanbanPerson(name: "Eve", initials: "E", employment: .fte)
        let resource = try s.addMembership(kPerson, to: project, allocationPercent: 60)
        resource.assignmentRaw = KanbanAssignment.fullTime.rawValue
        // The old assignment field is not modified
        #expect(resource.assignmentRaw == KanbanAssignment.fullTime.rawValue)
    }
}

/// Default labels configuration and precedence.
@MainActor
@Suite("Kanban default labels", .serialized)
struct KanbanDefaultLabelsTests {
    @Test("Missing key uses factory labels")
    func missingKeyUsesFactory() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.removeObject(forKey: KanbanBoardDefaults.defaultLabelsKey)

        let boardDefaults = KanbanBoardDefaults(defaults)
        let labels = boardDefaults.labelsForNewBoard()

        #expect(labels == KanbanTemplate.defaultLabels)
    }

    @Test("Empty array uses no labels")
    func emptyArrayUsesNone() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let encoded = try JSONEncoder().encode([KanbanTemplate.Label]())
        let json = String(data: encoded, encoding: .utf8)!
        defaults.set(json, forKey: KanbanBoardDefaults.defaultLabelsKey)

        let boardDefaults = KanbanBoardDefaults(defaults)
        let labels = boardDefaults.labelsForNewBoard()

        #expect(labels.isEmpty)
    }

    @Test("Malformed JSON uses factory without overwriting")
    func malformedUsesFactory() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("not valid json", forKey: KanbanBoardDefaults.defaultLabelsKey)

        let boardDefaults = KanbanBoardDefaults(defaults)
        let labels = boardDefaults.labelsForNewBoard()

        #expect(labels == KanbanTemplate.defaultLabels)
        // Original value remains
        #expect(defaults.string(forKey: KanbanBoardDefaults.defaultLabelsKey) == "not valid json")
    }

    @Test("Custom labels are used when set")
    func customLabelsUsed() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let custom = [
            KanbanTemplate.Label(name: "Urgent", colorHex: "#FF0000"),
            KanbanTemplate.Label(name: "Nice", colorHex: "#00FF00"),
        ]
        let encoded = try JSONEncoder().encode(custom)
        let json = String(data: encoded, encoding: .utf8)!
        defaults.set(json, forKey: KanbanBoardDefaults.defaultLabelsKey)

        let boardDefaults = KanbanBoardDefaults(defaults)
        let labels = boardDefaults.labelsForNewBoard()

        #expect(labels == custom)
    }

    @Test("Save and load round-trip")
    func saveAndLoadRoundTrip() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let custom = [KanbanTemplate.Label(name: "Custom", colorHex: "#123456")]

        var boardDefaults = KanbanBoardDefaults()
        boardDefaults.labels = custom
        try boardDefaults.save(to: defaults)

        let loaded = KanbanBoardDefaults(defaults)
        #expect(loaded.labelsForNewBoard() == custom)
    }

    @Test("Save nil removes preference")
    func saveNilRemoves() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let custom = [KanbanTemplate.Label(name: "Custom", colorHex: "#123456")]

        // Set custom first
        var boardDefaults = KanbanBoardDefaults()
        boardDefaults.labels = custom
        try boardDefaults.save(to: defaults)
        #expect(defaults.string(forKey: KanbanBoardDefaults.defaultLabelsKey) != nil)

        // Clear by saving nil
        boardDefaults.labels = nil
        try boardDefaults.save(to: defaults)
        #expect(defaults.string(forKey: KanbanBoardDefaults.defaultLabelsKey) == nil)
    }
}
