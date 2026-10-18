import Testing
import Foundation
import SwiftData
@testable import TickyTask

/// Allocation decides full- or part-time everywhere a membership is shown (UI polish §9),
/// without rewriting the stored value.
@MainActor
@Suite("Kanban allocation-derived assignment", .serialized)
struct KanbanVisualConsistencyTests {
    @Test("A legacy 60 % membership stored as full-time reads part-time in the metrics, and its stored value is untouched")
    func legacyMismatch() throws {
        let service = KanbanService(ModelContext(ModelContainerProvider.makeInMemoryContainer()))
        let project = try service.createProject(name: "Visual", key: "VIS")
        let grace = try service.addMembership(try service.createPerson(name: "Grace", initials: "G"), to: project, allocationPercent: 60)
        grace.assignmentRaw = KanbanAssignment.fullTime.rawValue   // as an older version could leave it
        let full = try service.addMembership(try service.createPerson(name: "Henry", initials: "H"), to: project, allocationPercent: 100)
        full.assignmentRaw = KanbanAssignment.partTime.rawValue
        let snapshot = MetricsSnapshot(project: project, now: Date(), calendar: Calendar(identifier: .gregorian))
        #expect(snapshot.members.first { $0.id == grace.id }?.assignment == .partTime)
        #expect(snapshot.members.first { $0.id == full.id }?.assignment == .fullTime)
        #expect(grace.assignmentRaw == KanbanAssignment.fullTime.rawValue, "reading never rewrites the stored value")
    }
}
