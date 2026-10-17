import XCTest

/// The Kanban module end to end (design 01 §3, §5): switching modules, the board grid
/// with its headers, row collapse, the cross-board and roll-off badges, All projects ›
/// People, Attention revealing a card, adding a column, and row headers staying in
/// view while the board scrolls sideways. `-uitestKanbanSeed` adds boards "Platform"
/// (Ravi Kumar; Mia Chen, a contractor ending in 10 days) and "Data" (Mia at 60%).
final class KanbanBoardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitestKanbanSeed", "-calendarColumns", "7", "-weekStartsMonday", "YES",
                               "-showWeekends", "YES"] + extra
        app.launchWithMainWindow()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 20), "the planner opens first")
        app.typeKey("2", modifierFlags: .command)
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openPlatform(_ app: XCUIApplication) {
        let board = element(app, "kanban-sidebar-Platform")
        XCTAssertTrue(board.waitForExistence(timeout: 10), "the seeded board is in the sidebar")
        board.click()
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the board's columns render")
    }

    func testSwitchModulesAndSeeTheBoard() {
        let app = launch()
        openPlatform(app)
        for id in ["kanban-colhdr-In Progress", "kanban-colhdr-Done", "kanban-rowhdr-Unassigned", "kanban-rowhdr-Ravi Kumar",
                   "kanban-rowhdr-Mia Chen", "kanban-card-Build API", "kanban-card-Triage inbox", "kanban-gauge-Ravi Kumar"] {
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 5), "\(id) should exist")
        }
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), "⌘1 returns to the planner")
        XCTAssertFalse(element(app, "kanban-colhdr-To Do").exists)
    }

    func testCollapseAndExpandARow() {
        let app = launch()
        openPlatform(app)
        XCTAssertTrue(element(app, "kanban-card-Build API").waitForExistence(timeout: 5))
        element(app, "kanban-row-toggle-Ravi Kumar").click()
        XCTAssertTrue(element(app, "kanban-collapsed-Ravi Kumar").waitForExistence(timeout: 5), "a collapsed row shows its counts")
        XCTAssertFalse(element(app, "kanban-card-Build API").exists, "and hides its cards")
        element(app, "kanban-row-toggle-Ravi Kumar").click()
        XCTAssertTrue(element(app, "kanban-card-Build API").waitForExistence(timeout: 5), "expanding shows the cards again")
    }

    func testBadgesAndPeopleRollup() {
        let app = launch()
        openPlatform(app)
        XCTAssertTrue(element(app, "kanban-rolloff-Mia Chen").waitForExistence(timeout: 5), "Mia rolls off within 30 days")
        XCTAssertTrue(element(app, "kanban-crossboard-Mia Chen").exists, "Mia is 110% allocated across boards")
        XCTAssertFalse(element(app, "kanban-crossboard-Ravi Kumar").exists)
        element(app, "kanban-sidebar-all").click()
        XCTAssertTrue(element(app, "kanban-project-card-Data").waitForExistence(timeout: 5))
        app.radioButtons["People"].firstMatch.click()
        XCTAssertTrue(element(app, "kanban-overallocated-Mia Chen").waitForExistence(timeout: 5), "People flags the over-allocation")
    }

    func testAttentionRevealsTheCard() {
        let app = launch()
        element(app, "kanban-sidebar-attention").click()
        let item = element(app, "kanban-attention-Build API")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "an overdue, blocked card needs attention")
        item.click()
        XCTAssertTrue(element(app, "kanban-card-Build API").waitForExistence(timeout: 5), "the board opens on the card")
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").exists)
    }

    func testAddAColumn() {
        let app = launch()
        openPlatform(app)
        element(app, "kanban-add-column").click()
        let field = element(app, "kanban-prompt-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("QA")
        element(app, "kanban-prompt-ok").click()
        XCTAssertTrue(element(app, "kanban-colhdr-QA").waitForExistence(timeout: 5), "the new column appears")
    }

    func testRowHeadersStayInViewWhenScrollingSideways() {
        let app = launch(["-uitestKanbanWide"])
        openPlatform(app)
        let board = element(app, "kanban-board")
        let header = element(app, "kanban-rowhdr-Ravi Kumar")
        let firstCard = element(app, "kanban-card-Triage inbox")
        XCTAssertTrue(header.waitForExistence(timeout: 5) && firstCard.exists)
        let headerX = header.frame.minX, cardX = firstCard.frame.minX
        func scrolled() -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while firstCard.frame.minX >= cardX - 100, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            return firstCard.frame.minX < cardX - 100
        }
        // The sign of a horizontal scroll delta differs between setups; try both ways.
        board.scroll(byDeltaX: -900, deltaY: 0)
        if !scrolled() { board.scroll(byDeltaX: 900, deltaY: 0) }
        _ = scrolled()
        XCTAssertLessThan(firstCard.frame.minX, cardX - 100, "the board scrolled sideways")
        XCTAssertEqual(header.frame.minX, headerX, accuracy: 4, "the row header stayed put")
        XCTAssertTrue(element(app, "kanban-colhdr-Stage 1").exists)
    }
}
