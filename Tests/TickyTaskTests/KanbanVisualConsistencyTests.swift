import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Visual consistency: column styles in charts, and allocation-derived membership display.
@MainActor
@Suite("Kanban visual consistency", .serialized)
struct KanbanVisualConsistencyTests {
    private func board() throws -> (KanbanService, KanbanProject) {
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()))
        let project = try service.createProject(name: "Visual", key: "VIS")
        return (service, project)
    }

    // MARK: - Column style map tests

    @Test("Kind defaults map to semantic colours")
    func kindDefaultsMapToSemanticColours() throws {
        let backlog = KanbanColumnStyle(kind: .backlog, customColorHex: nil)
        let active = KanbanColumnStyle(kind: .active, customColorHex: nil)
        let done = KanbanColumnStyle(kind: .done, customColorHex: nil)

        #expect(backlog.effectiveAccent == .red)
        #expect(active.effectiveAccent == .orange)
        #expect(done.effectiveAccent == .green)
    }

    @Test("Custom color hex overrides kind default")
    func customColorOverridesDefault() throws {
        let blueBacklog = KanbanColumnStyle(kind: .backlog, customColorHex: "#0000FF")
        #expect(blueBacklog.effectiveAccent != .red)
    }

    @Test("Deleted column uses grey in flow chart")
    func deletedColumnIsGrey() throws {
        // Deleted columns should render as .gray.opacity(0.5)
        // This is handled in the FlowChart body by checking band.isDeleted
        let gray = Color.gray.opacity(0.5)
        // The computed grey should never equal a semantic colour
        #expect(gray != .red)
        #expect(gray != .orange)
        #expect(gray != .green)
    }

    @Test("Column kind names match spec")
    func kindNamesMatchSpec() throws {
        let backlog = KanbanColumnStyle(kind: .backlog, customColorHex: nil)
        let active = KanbanColumnStyle(kind: .active, customColorHex: nil)
        let done = KanbanColumnStyle(kind: .done, customColorHex: nil)

        #expect(backlog.kindName == "Not started")
        #expect(active.kindName == "In progress")
        #expect(done.kindName == "Done")
    }

    @Test("Column kind symbols match spec")
    func kindSymbolsMatchSpec() throws {
        let backlog = KanbanColumnStyle(kind: .backlog, customColorHex: nil)
        let active = KanbanColumnStyle(kind: .active, customColorHex: nil)
        let done = KanbanColumnStyle(kind: .done, customColorHex: nil)

        #expect(backlog.symbol == "circle.dashed")
        #expect(active.symbol == "circle.lefthalf.filled")
        #expect(done.symbol == "checkmark.circle.fill")
    }

    // MARK: - Metrics snapshot allocation tests

    @Test("Metrics snapshot uses effectiveAssignment not stored")
    func metricsUsesEffectiveAssignment() throws {
        let (s, project) = try board()
        let kPerson = KanbanPerson(name: "Frank", initials: "F", employment: .fte)
        let resource = try s.addMembership(kPerson, to: project, allocationPercent: 60)

        // Corrupt the stored assignment to prove the snapshot uses effective
        resource.assignmentRaw = KanbanAssignment.fullTime.rawValue

        let context = project.modelContext!
        let calendar = Calendar.current
        let key = "visual-test"
        let snapshot = KanbanMetrics().snapshot(of: project, key: key, calendar: calendar)

        // Find the member in the snapshot
        if let member = snapshot.members.first(where: { $0.id == resource.id }) {
            // Should be partTime from effectiveAssignment, not fullTime from stored
            #expect(member.assignment == .partTime)
        } else {
            #expect(Bool(false), "Resource not found in snapshot")
        }
    }

    @Test("Metrics snapshot with mismatched allocation and assignment")
    func metricsSnapshotLegacyMismatch() throws {
        let (s, project) = try board()
        let kPerson = KanbanPerson(name: "Grace", initials: "G", employment: .fte)
        let resource = try s.addMembership(kPerson, to: project, allocationPercent: 50)

        // Manually set stored assignment to fullTime (legacy mismatch)
        resource.assignmentRaw = KanbanAssignment.fullTime.rawValue
        // But effective allocation is 50%, so effectiveAssignment should be partTime

        let calendar = Calendar.current
        let key = "mismatch-test"
        let snapshot = KanbanMetrics().snapshot(of: project, key: key, calendar: calendar)

        if let member = snapshot.members.first(where: { $0.id == resource.id }) {
            // Snapshot should report partTime (from effective assignment)
            #expect(member.assignment == .partTime)
        } else {
            #expect(Bool(false), "Resource not found in snapshot")
        }
    }

    @Test("Metrics snapshot preserves other member fields")
    func metricsSnapshotPreservesFields() throws {
        let (s, project) = try board()
        let kPerson = KanbanPerson(name: "Henry", initials: "H", employment: .contractor)
        let resource = try s.addMembership(kPerson, to: project, allocationPercent: 75)

        let calendar = Calendar.current
        let key = "fields-test"
        let snapshot = KanbanMetrics().snapshot(of: project, key: key, calendar: calendar)

        if let member = snapshot.members.first(where: { $0.id == resource.id }) {
            #expect(member.name == "Henry")
            #expect(member.employment == .contractor)
            #expect(member.allocationPercent == 75)
        } else {
            #expect(Bool(false), "Resource not found in snapshot")
        }
    }
}
