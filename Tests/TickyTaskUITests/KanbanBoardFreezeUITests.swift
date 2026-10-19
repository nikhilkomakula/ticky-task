import XCTest

/// The board must never stop answering while it scrolls. Its person rows were once built
/// lazily; on a board shaped like `-uitestKanbanVaried`, setting the vertical scroller through
/// Accessibility in jumps (VoiceOver, utilities that drive the scroll bar) re-laid the window
/// forever at 100% CPU, and with a context menu open AppKit gave up and the app crashed.
final class KanbanBoardFreezeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitestKanbanVaried", "-calendarColumns", "7", "-weekStartsMonday", "YES",
                               "-showWeekends", "YES", "-kanban.defaultBoard", ""]
        app.launchWithMainWindow()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 20), "the planner opens first")
        app.typeKey("2", modifierFlags: .command)
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openBoard(_ app: XCUIApplication) -> XCUIElement {
        let sidebar = element(app, "kanban-sidebar-Varied")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "the Varied board is in the sidebar")
        sidebar.click()
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the board's columns render")
        let board = element(app, "kanban-board")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        return board
    }

    /// Fails if the app crashed, or took over 10 s to answer (a hung main thread never does).
    private func assertResponsive(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        let answered = element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10)
        XCTAssertTrue(answered && Date().timeIntervalSince(start) < 10, "the board answers after \(step)", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after \(step)", file: file, line: line)
    }

    func testJumpingTheScrollerDoesNotFreezeTheBoard() throws {
        let app = launch()
        let board = openBoard(app)
        // The vertical one is the tall, narrow scroll bar.
        let bars = (0..<board.scrollBars.count).map { board.scrollBars.element(boundBy: $0) }
        let scroller = try XCTUnwrap(bars.first { $0.frame.height > $0.frame.width }, "the board scrolls vertically")
        let firstRow = element(app, "kanban-cell-To Do-Unassigned")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let top = firstRow.frame.minY
        scroller.adjust(toNormalizedSliderPosition: 1)
        assertResponsive(app, "jumping to the end")
        XCTAssertFalse(firstRow.exists && firstRow.frame.minY == top, "the jump scrolled the board")
        // Top to bottom and back in 13 jumps, as dragging the scroller's thumb lands.
        for round in 0..<6 {
            for step in 0...12 {
                let fraction = CGFloat(step) / 12
                scroller.adjust(toNormalizedSliderPosition: round.isMultiple(of: 2) ? fraction : 1 - fraction)
            }
            assertResponsive(app, "scroller sweep \(round)")
        }
    }

    /// A card's context menu over a board that has just jumped.
    func testContextMenusAfterScrollerJumpsKeepTheBoardResponsive() throws {
        let app = launch()
        let board = openBoard(app)
        let bars = (0..<board.scrollBars.count).map { board.scrollBars.element(boundBy: $0) }
        let scroller = try XCTUnwrap(bars.first { $0.frame.height > $0.frame.width }, "the board scrolls vertically")
        var menusOpened = 0
        for round in 0..<6 {
            scroller.adjust(toNormalizedSliderPosition: [0.2, 0.9, 0.5, 0, 0.7, 0.35][round])
            let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-card-'"))
            let headers = element(app, "kanban-colhdr-To Do").frame.maxY
            let visible = (0..<min(cards.count, 40)).map { cards.element(boundBy: $0) }.first {
                $0.frame.minY > headers + 4 && $0.frame.maxY < board.frame.maxY - 4 && $0.isHittable
            }
            guard let card = visible else { continue }
            card.rightClick()
            XCTAssertTrue(app.menuItems["Duplicate"].firstMatch.waitForExistence(timeout: 10), "round \(round): the card's menu opens")
            menusOpened += 1
            Thread.sleep(forTimeInterval: 1.5)
            app.typeKey(.escape, modifierFlags: [])
            assertResponsive(app, "round \(round)'s menu")
        }
        XCTAssertGreaterThanOrEqual(menusOpened, 4, "most rounds opened a menu")
    }
}
