import Testing
import Foundation
@testable import TickyTask

@Suite("Board card focus requests")
struct BoardCardFocusTests {
    @Test("Keyboard shortcuts use actual focus without a pending request")
    func actualFocus() {
        let card = KanbanBoardFocus.card(UUID())
        let column = KanbanBoardFocus.column(UUID())
        let row = KanbanBoardFocus.row(UUID())

        #expect(BoardCardFocus.keyboardTarget(focus: card, pendingRequest: nil) == card)
        #expect(BoardCardFocus.keyboardTarget(focus: column, pendingRequest: nil) == column)
        #expect(BoardCardFocus.keyboardTarget(focus: row, pendingRequest: nil) == row)
        #expect(BoardCardFocus.keyboardTarget(focus: nil, pendingRequest: nil) == nil)
    }

    @Test("A pending navigation uses its destination before focus arrives")
    func pendingNavigation() {
        let request = BoardCardFocusRequest(cardID: UUID())
        let source = KanbanBoardFocus.card(UUID())

        #expect(BoardCardFocus.keyboardTarget(focus: source, pendingRequest: request) == .card(request.cardID))
    }

    @Test("An offscreen reveal retains its target through a nil focus handoff")
    func pendingReveal() {
        let request = BoardCardFocusRequest(cardID: UUID(), requiresReveal: true)
        let pending = BoardCardFocus.pendingRequest(request, afterFocusChangesTo: nil)

        #expect(pending == request)
        #expect(BoardCardFocus.keyboardTarget(focus: nil, pendingRequest: pending) == .card(request.cardID))
    }

    @Test("Reaching the requested card completes the request")
    func focusArrives() {
        let request = BoardCardFocusRequest(cardID: UUID())
        let pending = BoardCardFocus.pendingRequest(request, afterFocusChangesTo: .card(request.cardID))

        #expect(pending == nil)
        #expect(BoardCardFocus.keyboardTarget(focus: nil, pendingRequest: pending) == nil,
                "a later toolbar focus must not keep the completed card as a shortcut target")
    }

    @Test("Reaching the requested card retains an active reveal until scrolling completes")
    func focusArrivesDuringReveal() {
        let request = BoardCardFocusRequest(cardID: UUID(), requiresReveal: true)
        let pending = BoardCardFocus.pendingRequest(request, afterFocusChangesTo: .card(request.cardID))

        #expect(pending == request, "focus can arrive before the offscreen card has scrolled into view")
        #expect(BoardCardFocus.pendingRequest(pending, afterCompleting: request) == nil)
    }

    @Test("Finishing a reveal clears its request even when focus does not change")
    func revealCompletes() {
        let request = BoardCardFocusRequest(cardID: UUID(), requiresReveal: true)
        let pending = BoardCardFocus.pendingRequest(request, afterCompleting: request)

        #expect(pending == nil)
        #expect(BoardCardFocus.keyboardTarget(focus: .card(request.cardID), pendingRequest: pending) == .card(request.cardID))
        #expect(BoardCardFocus.keyboardTarget(focus: nil, pendingRequest: pending) == nil)
    }

    @Test("Focusing another board element cancels a pending request")
    func focusChangesElsewhere() {
        let request = BoardCardFocusRequest(cardID: UUID(), requiresReveal: true)
        let otherCard = KanbanBoardFocus.card(UUID())
        let column = KanbanBoardFocus.column(UUID())
        let row = KanbanBoardFocus.row(UUID())

        #expect(BoardCardFocus.pendingRequest(request, afterFocusChangesTo: otherCard) == nil)
        #expect(BoardCardFocus.pendingRequest(request, afterFocusChangesTo: column) == nil)
        #expect(BoardCardFocus.pendingRequest(request, afterFocusChangesTo: row) == nil)
    }

    @Test("An older reveal cannot clear a newer request for the same card")
    func staleCompletion() {
        let cardID = UUID()
        let first = BoardCardFocusRequest(cardID: cardID, requiresReveal: true)
        let second = BoardCardFocusRequest(cardID: cardID, requiresReveal: true)

        #expect(first != second)
        #expect(BoardCardFocus.pendingRequest(second, afterCompleting: first) == second)
        #expect(BoardCardFocus.pendingRequest(nil, afterCompleting: first) == nil)
    }
}
