import Testing
import SwiftData
@testable import TickyTask

@MainActor
struct KanbanVolumeSeedTests {
    @Test func hotCellsHaveFixedColumnsAndPeople() throws {
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let project = try KanbanVolumeSeed.seed(into: context, cardCount: 240)

        for (column, person) in [("To Do", "Alice Johnson"), ("In Progress", "Bob Chen"), ("Done", "Carol Davis")] {
            let cards = project.tasks.filter { $0.column?.name == column && $0.resource?.displayName == person }
            #expect(cards.count >= 20, "each documented hot cell receives a third of the concentrated quarter")
        }
    }
}
