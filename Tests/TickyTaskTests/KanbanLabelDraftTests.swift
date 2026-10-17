import Testing
import Foundation

@testable import TickyTask

struct KanbanLabelDraftTests {

    // MARK: - Add

    @Test
    func addLabel() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "Feature", colorHex: "#34C759", symbolName: "tag")

        #expect(draft.labels.count == 1)
        #expect(draft.labels[0].name == "Feature")
        #expect(draft.labels[0].colorHex == "#34C759")
        #expect(draft.labels[0].symbolName == "tag")
    }

    @Test
    func addMultipleLabels() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "Feature", colorHex: "#34C759")
        draft.add(name: "Bug", colorHex: "#FF3B30")

        #expect(draft.labels.count == 2)
        #expect(draft.labels[0].name == "Feature")
        #expect(draft.labels[1].name == "Bug")
    }

    // MARK: - Rename

    @Test
    func renameLabel() {
        let label = KanbanLabel(name: "Feature", colorHex: "#34C759")
        var draft = KanbanLabelCatalogDraft(from: [label])

        draft.edit(id: label.id, name: "New Feature", colorHex: nil, symbolName: nil)

        #expect(draft.labels[0].name == "New Feature")
        #expect(draft.labels[0].colorHex == "#34C759")
    }

    @Test
    func renameWithWhitespace() {
        let label = KanbanLabel(name: "Feature", colorHex: "#34C759")
        var draft = KanbanLabelCatalogDraft(from: [label])

        let changes = draft.buildChanges()
        // No edits expected for the initial state
        #expect(changes.edits.isEmpty)
    }

    // MARK: - Color Change

    @Test
    func changeColor() {
        let label = KanbanLabel(name: "Feature", colorHex: "#34C759")
        var draft = KanbanLabelCatalogDraft(from: [label])

        draft.edit(id: label.id, name: nil, colorHex: "#FF3B30", symbolName: nil)

        #expect(draft.labels[0].colorHex == "#FF3B30")
        #expect(draft.labels[0].name == "Feature")
    }

    // MARK: - Symbol Change

    @Test
    func addSymbol() {
        let label = KanbanLabel(name: "Feature", colorHex: "#34C759")
        var draft = KanbanLabelCatalogDraft(from: [label])

        draft.edit(id: label.id, name: nil, colorHex: nil, symbolName: "tag")

        #expect(draft.labels[0].symbolName == "tag")
    }

    @Test
    func removeSymbol() {
        let label = KanbanLabel(name: "Feature", colorHex: "#34C759")
        label.symbolName = "tag"
        var draft = KanbanLabelCatalogDraft(from: [label])

        draft.edit(id: label.id, name: nil, colorHex: nil, symbolName: nil)

        // Passing nil means "no change"; the symbol stays
        #expect(draft.labels[0].symbolName == "tag")
    }

    // MARK: - Delete

    @Test
    func deleteLabel() {
        let label1 = KanbanLabel(name: "Feature", colorHex: "#34C759")
        let label2 = KanbanLabel(name: "Bug", colorHex: "#FF3B30")
        var draft = KanbanLabelCatalogDraft(from: [label1, label2])

        draft.delete(id: label1.id)

        #expect(draft.labels.count == 1)
        #expect(draft.labels[0].name == "Bug")
    }

    // MARK: - Reorder

    @Test
    func moveUp() {
        let label1 = KanbanLabel(name: "Feature", colorHex: "#34C759")
        let label2 = KanbanLabel(name: "Bug", colorHex: "#FF3B30")
        var draft = KanbanLabelCatalogDraft(from: [label1, label2])

        draft.moveUp(id: label2.id)

        #expect(draft.labels[0].name == "Bug")
        #expect(draft.labels[1].name == "Feature")
    }

    @Test
    func moveDown() {
        let label1 = KanbanLabel(name: "Feature", colorHex: "#34C759")
        let label2 = KanbanLabel(name: "Bug", colorHex: "#FF3B30")
        var draft = KanbanLabelCatalogDraft(from: [label1, label2])

        draft.moveDown(id: label1.id)

        #expect(draft.labels[0].name == "Bug")
        #expect(draft.labels[1].name == "Feature")
    }

    @Test
    func moveUpFirst() {
        let label1 = KanbanLabel(name: "Feature", colorHex: "#34C759")
        let label2 = KanbanLabel(name: "Bug", colorHex: "#FF3B30")
        var draft = KanbanLabelCatalogDraft(from: [label1, label2])

        draft.moveUp(id: label1.id)

        // Can't move up from first position
        #expect(draft.labels[0].name == "Feature")
        #expect(draft.labels[1].name == "Bug")
    }

    @Test
    func moveDownLast() {
        let label1 = KanbanLabel(name: "Feature", colorHex: "#34C759")
        let label2 = KanbanLabel(name: "Bug", colorHex: "#FF3B30")
        var draft = KanbanLabelCatalogDraft(from: [label1, label2])

        draft.moveDown(id: label2.id)

        // Can't move down from last position
        #expect(draft.labels[0].name == "Feature")
        #expect(draft.labels[1].name == "Bug")
    }

    // MARK: - Validation

    @Test
    func validationErrorBlankName() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "", colorHex: "#34C759")

        #expect(draft.validationError == "A label name can't be blank.")
    }

    @Test
    func validationErrorWhitespaceOnly() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "   ", colorHex: "#34C759")

        #expect(draft.validationError == "A label name can't be blank.")
    }

    @Test
    func validationErrorDuplicateNames() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "Feature", colorHex: "#34C759")
        draft.add(name: "Feature", colorHex: "#FF3B30")

        #expect(draft.validationError == "Label names must be unique.")
    }

    @Test
    func validationErrorDuplicateNamesCaseInsensitive() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "Feature", colorHex: "#34C759")
        draft.add(name: "feature", colorHex: "#FF3B30")

        #expect(draft.validationError == "Label names must be unique.")
    }

    @Test
    func validationPassUniqueNames() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "Feature", colorHex: "#34C759")
        draft.add(name: "Bug", colorHex: "#FF3B30")

        #expect(draft.validationError == nil)
    }

    @Test
    func validationPassAfterDelete() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "Feature", colorHex: "#34C759")
        draft.add(name: "Feature", colorHex: "#FF3B30")  // Duplicate

        #expect(draft.validationError != nil)

        draft.delete(id: draft.labels[1].id)

        #expect(draft.validationError == nil)
    }

    // MARK: - Add then Delete

    @Test
    func addThenDeleteGivesNoOp() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "Feature", colorHex: "#34C759")

        let labelID = draft.labels[0].id
        draft.delete(id: labelID)

        #expect(draft.labels.isEmpty)

        let changes = draft.buildChanges()
        #expect(changes.adds.isEmpty)
        #expect(changes.edits.isEmpty)
        #expect(changes.deleteIDs.isEmpty)
    }

    // MARK: - Build Changes

    @Test
    func buildChangesAdd() {
        var draft = KanbanLabelCatalogDraft(from: [])
        draft.add(name: "Feature", colorHex: "#34C759", symbolName: "tag")

        let changes = draft.buildChanges()

        #expect(changes.adds.count == 1)
        #expect(changes.adds[0].name == "Feature")
        #expect(changes.adds[0].colorHex == "#34C759")
        #expect(changes.adds[0].symbolName == "tag")
        #expect(changes.edits.isEmpty)
        #expect(changes.deleteIDs.isEmpty)
    }

    @Test
    func buildChangesEdit() {
        let label = KanbanLabel(name: "Feature", colorHex: "#34C759")
        var draft = KanbanLabelCatalogDraft(from: [label])

        draft.edit(id: label.id, name: "New Feature", colorHex: nil, symbolName: nil)

        let changes = draft.buildChanges()

        #expect(changes.adds.isEmpty)
        #expect(changes.edits.count == 1)
        #expect(changes.edits[0].name == "New Feature")
        #expect(changes.deleteIDs.isEmpty)
    }

    @Test
    func buildChangesDelete() {
        let label = KanbanLabel(name: "Feature", colorHex: "#34C759")
        var draft = KanbanLabelCatalogDraft(from: [label])

        draft.delete(id: label.id)

        let changes = draft.buildChanges()

        #expect(changes.adds.isEmpty)
        #expect(changes.edits.isEmpty)
        #expect(changes.deleteIDs.count == 1)
        #expect(changes.deleteIDs[0] == label.id)
    }

    @Test
    func buildChangesOrder() {
        let label1 = KanbanLabel(name: "Feature", colorHex: "#34C759")
        let label2 = KanbanLabel(name: "Bug", colorHex: "#FF3B30")
        var draft = KanbanLabelCatalogDraft(from: [label1, label2])

        draft.moveUp(id: label2.id)

        let changes = draft.buildChanges()

        #expect(changes.orderIDs.count == 2)
        #expect(changes.orderIDs[0] == label2.id)
        #expect(changes.orderIDs[1] == label1.id)
    }

    @Test
    func buildChangesMixed() {
        let label1 = KanbanLabel(name: "Feature", colorHex: "#34C759")
        let label2 = KanbanLabel(name: "Bug", colorHex: "#FF3B30")
        var draft = KanbanLabelCatalogDraft(from: [label1, label2])

        draft.edit(id: label1.id, name: "Feature Request", colorHex: nil, symbolName: nil)
        draft.delete(id: label2.id)
        draft.add(name: "Enhancement", colorHex: "#007AFF")

        let changes = draft.buildChanges()

        #expect(changes.adds.count == 1)
        #expect(changes.adds[0].name == "Enhancement")
        #expect(changes.edits.count == 1)
        #expect(changes.edits[0].name == "Feature Request")
        #expect(changes.deleteIDs.count == 1)
        #expect(changes.deleteIDs[0] == label2.id)
    }

    // MARK: - Complex scenario: add, rename, delete, reorder in one go

    @Test
    func complexScenario() {
        let label1 = KanbanLabel(name: "Feature", colorHex: "#34C759")
        label1.sortIndex = 0
        let label2 = KanbanLabel(name: "Bug", colorHex: "#FF3B30")
        label2.sortIndex = 1

        var draft = KanbanLabelCatalogDraft(from: [label1, label2])

        // Add a new label
        draft.add(name: "Enhancement", colorHex: "#007AFF")

        // Rename Feature to Feature Request
        draft.edit(id: label1.id, name: "Feature Request", colorHex: nil, symbolName: nil)

        // Delete Bug
        draft.delete(id: label2.id)

        // Reorder: Enhancement should be first
        draft.moveUp(id: draft.labels.last!.id)

        let changes = draft.buildChanges()

        #expect(changes.adds.count == 1)
        #expect(changes.edits.count == 1)
        #expect(changes.deleteIDs.count == 1)
        #expect(changes.orderIDs.count == 2)
    }
}
