import Foundation

struct BoardCardFocusRequest: Equatable {
    let cardID: UUID
    var requiresReveal = false
    let token = UUID()
}

enum BoardCardFocus {
    static func keyboardTarget(focus: KanbanBoardFocus?, pendingRequest: BoardCardFocusRequest?) -> KanbanBoardFocus? {
        pendingRequest.map { .card($0.cardID) } ?? focus
    }

    static func pendingRequest(_ request: BoardCardFocusRequest?, afterFocusChangesTo focus: KanbanBoardFocus?) -> BoardCardFocusRequest? {
        // Moving a card between lazy cells may temporarily remove its focused view.
        // A request lasts through that gap, until focus arrives or the reveal completes.
        focus == nil ? request : nil
    }

    static func pendingRequest(_ pending: BoardCardFocusRequest?, afterCompleting request: BoardCardFocusRequest) -> BoardCardFocusRequest? {
        pending == request ? nil : pending
    }
}
