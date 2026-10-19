import XCTest

/// The board must never stop answering while it scrolls. Its person rows were once built
/// lazily; on a board shaped like `-uitestKanbanVaried`, moving the vertical scroll bar through
/// Accessibility in jumps re-laid the window forever at 100% CPU, and with a context menu open
/// AppKit gave up and the app crashed (I-D31). `-uitestKanbanScrollJumps` makes those jumps in the
/// app, since the UI-test runner can't set a scroll bar's value. On a Mac they froze the old board
/// every time; CI runners didn't, so these guard responsiveness rather than reproduce the loop.
final class KanbanBoardFreezeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // A hung app can stall XCTest's own queries; the run's test timeouts end the test instead.
        executionTimeAllowance = 240
    }

    private func launch(jumps: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitestKanbanVaried", "-uitestKanbanScrollJumps", "\(jumps)",
                               "-calendarColumns", "7", "-weekStartsMonday", "YES", "-showWeekends", "YES",
                               "-kanban.defaultBoard", "", "-defaultModule", "kanban"]
        app.launchWithMainWindow()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Fails if the app crashed, or took over 10 s to answer (an elapsed-time check; a hung main
    /// thread never answers, and the execution allowance bounds the query itself).
    private func assertResponsive(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        let answered = element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10)
        XCTAssertTrue(answered && Date().timeIntervalSince(start) < 10, "the board answers after \(step)", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after \(step)", file: file, line: line)
    }

    func testJumpingTheScrollBarDoesNotFreezeTheBoard() {
        let app = launch(jumps: 8)
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 20), "the Varied board opens")
        // Eight sweeps of 13 jumps take about 2 s after a 2 s start; then the board rests at the bottom.
        for check in 0..<4 {
            Thread.sleep(forTimeInterval: 2)
            assertResponsive(app, "\(2 * (check + 1)) s of scroll bar jumps")
        }
        // The jumps end at the bottom: the first row has gone up under the pinned column headers.
        let firstRow = element(app, "kanban-cell-To Do-Unassigned")
        let headers = element(app, "kanban-colhdr-To Do").frame
        XCTAssertTrue(!firstRow.exists || firstRow.frame.maxY <= headers.maxY, "the jumps scrolled the board to its end")
    }

    /// The crash: a card's context menu over a board that has just jumped (once the jumps end, so a
    /// card doesn't move between finding it and clicking it).
    func testContextMenusAfterScrollBarJumpsKeepTheBoardResponsive() {
        let app = launch(jumps: 12)
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 20), "the Varied board opens")
        Thread.sleep(forTimeInterval: 6)
        assertResponsive(app, "the jumps")
        let board = element(app, "kanban-board")
        var menusOpened = 0
        for round in 0..<5 {
            board.scroll(byDeltaX: 0, deltaY: round.isMultiple(of: 2) ? 400 : -250)
            let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-card-'"))
            let headers = element(app, "kanban-colhdr-To Do").frame.maxY
            let visible = (0..<min(cards.count, 40)).map { cards.element(boundBy: $0) }.first {
                $0.frame.minY > headers + 4 && $0.frame.maxY < board.frame.maxY - 4 && $0.isHittable
            }
            if let card = visible {
                card.rightClick()
                if app.menuItems["Duplicate"].firstMatch.waitForExistence(timeout: 5) { menusOpened += 1 }
                Thread.sleep(forTimeInterval: 1)
                app.typeKey(.escape, modifierFlags: [])
            }
            assertResponsive(app, "round \(round)")
        }
        XCTAssertGreaterThanOrEqual(menusOpened, 3, "most rounds opened a menu")
    }
}
