import XCTest

/// Increment 8 integrations (design 01 §7): Settings › Kanban › Load demo board, the Kanban
/// Summary sheet and Schedule to day. Every launch uses `-uitest` (an in-memory store).
final class KanbanIntegrationsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Both modules shown and the planner first, whatever this Mac's settings say.
        app.launchArguments = ["-uitest", "-uitestKanbanSeed", "-calendarColumns", "7", "-weekStartsMonday", "YES",
                               "-showWeekends", "YES", "-showPlannerModule", "YES", "-showKanbanModule", "YES",
                               "-defaultModule", "planner"]
        app.launchWithMainWindow()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 20), "the planner opens first")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openPlatform(_ app: XCUIApplication) {
        app.typeKey("2", modifierFlags: .command)
        let board = element(app, "kanban-sidebar-Platform")
        XCTAssertTrue(board.waitForExistence(timeout: 10), "the seeded board is in the sidebar")
        board.click()
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the board's columns render")
    }

    func testLoadDemoBoardFromSettings() {
        let app = launch()
        let settings = app.buttons["toolbar-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        // A Settings scene's tabs are toolbar buttons.
        let tab = app.toolbars.buttons["Kanban"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Settings has a Kanban tab")
        tab.click()
        let load = element(app, "settings-load-demo-board")
        XCTAssertTrue(load.waitForExistence(timeout: 5))
        load.click()
        app.typeKey("w", modifierFlags: .command)   // close Settings
        app.typeKey("2", modifierFlags: .command)
        let demo = element(app, "kanban-sidebar-Demo board")
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "the demo board is in the sidebar")
        demo.click()
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the demo board opens")
    }

    func testSummarySheetListsTheBoardsCards() {
        let app = launch()
        openPlatform(app)
        let summary = element(app, "kanban-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.click()
        XCTAssertTrue(element(app, "kanban-summary-generate").waitForExistence(timeout: 10), "the Summary sheet opens")
        for title in ["Triage inbox", "Build API", "Write docs"] {
            XCTAssertTrue(element(app, "kanban-summary-task-\(title)").waitForExistence(timeout: 5), "\(title) is offered")
        }
        XCTAssertFalse(element(app, "kanban-summary-task-Load warehouse").exists, "only this board's cards")
        element(app, "kanban-summary-done").click()
        XCTAssertFalse(element(app, "kanban-summary-generate").waitForExistence(timeout: 2), "the sheet closes")
    }

    func testScheduleToDayPutsTheCardOnTodayInThePlanner() {
        let app = launch()
        openPlatform(app)
        let card = element(app, "kanban-card-Triage inbox")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.3)).click()
        XCTAssertTrue(element(app, "kanban-editor-title").waitForExistence(timeout: 5), "the editor opens")
        element(app, "kanban-editor-schedule").click()
        // No due date, so the popover starts on today.
        let confirm = element(app, "kanban-editor-schedule-confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the day picker opens")
        confirm.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'On the planner for'")).firstMatch
            .waitForExistence(timeout: 5), "the editor confirms the day")
        element(app, "kanban-editor-done").click()
        XCTAssertFalse(element(app, "kanban-editor-title").waitForExistence(timeout: 2), "the editor closed")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Triage inbox"].waitForExistence(timeout: 10), "the planner shows the scheduled task")
    }
}
