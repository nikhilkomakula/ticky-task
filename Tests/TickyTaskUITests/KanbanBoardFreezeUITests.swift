import XCTest

/// The board must stay responsive while context menus open over it during scrolling. On a
/// trackpad a two-finger tap mid-scroll opens a card's menu; that once sent the window into an
/// endless layout pass (AppKit: "needing another Update Constraints in Window pass") and the app
/// froze, then crashed.
final class KanbanBoardFreezeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ seed: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-calendarColumns", "7", "-weekStartsMonday", "YES", "-showWeekends", "YES",
                               "-kanban.defaultBoard", ""] + seed
        app.launchWithMainWindow()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 20), "the planner opens first")
        app.typeKey("2", modifierFlags: .command)
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openBoard(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let sidebar = element(app, "kanban-sidebar-\(name)")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "the \(name) board is in the sidebar")
        sidebar.click()
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the board's columns render")
        let board = element(app, "kanban-board")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        return board
    }

    /// A card that's on screen now, not one under the pinned headers.
    private func visibleCard(_ app: XCUIApplication, _ board: XCUIElement) -> XCUIElement? {
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-card-'"))
        let headers = element(app, "kanban-colhdr-To Do").frame.maxY
        let area = board.frame
        for index in 0..<min(cards.count, 60) {
            let card = cards.element(boundBy: index)
            let frame = card.frame
            if frame.minY > headers + 4, frame.maxY < area.maxY - 4, frame.minX > area.minX + 200, frame.maxX < area.maxX - 4,
               card.isHittable {
                return card
            }
        }
        return nil
    }

    /// Fails if the app crashed or stopped answering accessibility queries.
    private func assertResponsive(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after \(step)", file: file, line: line)
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the board still answers after \(step)",
                      file: file, line: line)
    }

    private func stress(_ app: XCUIApplication, _ board: XCUIElement, rounds: Int) {
        for round in 0..<rounds {
            board.scroll(byDeltaX: round.isMultiple(of: 3) ? -300 : 0, deltaY: round.isMultiple(of: 2) ? -600 : 350)
            guard let card = visibleCard(app, board) else { continue }
            card.rightClick()
            let duplicate = app.menuItems["Duplicate"].firstMatch
            XCTAssertTrue(duplicate.waitForExistence(timeout: 10), "round \(round): the card's menu opens")
            // Let the board lay out while the menu tracks, and cross another card under it.
            app.menuItems["Edit…"].firstMatch.hover()
            Thread.sleep(forTimeInterval: 1.5)
            app.typeKey(.escape, modifierFlags: [])
            assertResponsive(app, "round \(round)'s menu")
        }
        // A menu action that changes the board (and reveals the copy) while it settles.
        if let card = visibleCard(app, board) {
            card.rightClick()
            let duplicate = app.menuItems["Duplicate"].firstMatch
            XCTAssertTrue(duplicate.waitForExistence(timeout: 10))
            duplicate.click()
            Thread.sleep(forTimeInterval: 2)
            assertResponsive(app, "Duplicate")
        }
    }

    func testContextMenusWhileScrollingASmallBoard() {
        let app = launch(["-uitestKanbanSeed"])
        let board = openBoard(app, "Platform")
        stress(app, board, rounds: 10)
    }

    func testContextMenusWhileScrollingALargeBoard() {
        let app = launch(["-uitestKanbanVolume", "600"])
        let board = openBoard(app, "Volume")
        stress(app, board, rounds: 14)
    }
}
