import Foundation

/// Staged label changes for a board: adds, edits, reorder and deletes, all atomic.
struct KanbanLabelChanges: Equatable, Sendable {
    struct Add: Equatable, Sendable {
        var id: UUID
        var name: String
        var colorHex: String
        var symbolName: String?
    }

    struct Edit: Equatable, Sendable {
        var id: UUID
        var name: String?
        var colorHex: String?
        var symbolName: String?
        /// Removes the label's symbol (`symbolName` nil alone means "unchanged").
        var clearsSymbol = false
    }

    var adds: [Add] = []
    var edits: [Edit] = []
    var orderIDs: [UUID] = []
    var deleteIDs: [UUID] = []

    init() {}
}
