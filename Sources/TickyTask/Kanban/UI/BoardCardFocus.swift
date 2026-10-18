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
        // Focus can also arrive before scrolling finishes; only the reveal completes that request.
        if focus == nil { return request }
        if let request, request.requiresReveal, focus == .card(request.cardID) { return request }
        return nil
    }

    static func pendingRequest(_ pending: BoardCardFocusRequest?, afterCompleting request: BoardCardFocusRequest) -> BoardCardFocusRequest? {
        pending == request ? nil : pending
    }
}
