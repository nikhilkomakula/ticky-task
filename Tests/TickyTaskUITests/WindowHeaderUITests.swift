import XCTest

/// Window header UI tests for P3: two-row header, new-item commands, and controls layout.
final class WindowHeaderUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(showPlanner: Bool = true, showKanban: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitest",
            "-calendarColumns", "5",
            "-weekStartsMonday", "YES",
            "-showWeekends", "NO",
            "-showPlannerModule", showPlanner ? "YES" : "NO",
            "-showKanbanModule", showKanban ? "YES" : "NO",
            "-defaultModule", "planner"
        ]
        app.launchWithMainWindow()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 20), "the planner opens first")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    // MARK: - Module Switcher Centering

    func testModuleSwitcherIsCenteredWhenBothModulesVisible() {
        let app = launch(showPlanner: true, showKanban: true)

        let switcher = element(app, "module-switcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "module switcher is visible")

        // Get the window and switcher frames
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        let windowMidX = window.frame.midX
        let switcherMidX = switcher.frame.midX

        // Assert switcher is centered within ±4 points
        let delta = abs(windowMidX - switcherMidX)
        XCTAssertLessThanOrEqual(delta, 4, "module switcher is centered (delta: \(delta))")
    }

    func testModuleSwitcherHiddenWhenOnlyPlannerVisible() {
        let app = launch(showPlanner: true, showKanban: false)

        let switcher = element(app, "module-switcher")
        XCTAssertFalse(switcher.exists, "module switcher is hidden when only Planner is visible")

        // Settings should still be visible
        let settings = element(app, "toolbar-settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings is visible")
    }

    func testModuleSwitcherHiddenWhenOnlyKanbanVisible() {
        let app = launch(showPlanner: false, showKanban: true)

        let switcher = element(app, "module-switcher")
        XCTAssertFalse(switcher.exists, "module switcher is hidden when only Kanban is visible")
    }

    // MARK: - Planner New Task Button

    func testNewTaskButtonExistsInPlanner() {
        let app = launch(showPlanner: true, showKanban: true)

        // Ensure Planner is active
        let switcher = element(app, "module-switcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)

        let newTaskButton = element(app, "toolbar-new-task")
        XCTAssertTrue(newTaskButton.waitForExistence(timeout: 5), "New task button exists in Planner")
    }

    func testNewTaskButtonHiddenInKanban() {
        let app = launch(showPlanner: true, showKanban: true)

        // Switch to Kanban
        app.typeKey("2", modifierFlags: .command)

        let newTaskButton = element(app, "toolbar-new-task")
        XCTAssertFalse(newTaskButton.exists, "New task button is hidden in Kanban")
    }

    // MARK: - Kanban Board Actions

    func testBoardActionsMenuExistsOnOpenBoard() {
        let app = launch(showPlanner: true, showKanban: true)

        // Switch to Kanban and open a board
        app.typeKey("2", modifierFlags: .command)
        let board = element(app, "kanban-sidebar-Platform")
        XCTAssertTrue(board.waitForExistence(timeout: 10), "seeded board exists")
        board.click()

        // Verify board actions menu exists
        let boardActions = element(app, "kanban-board-actions")
        XCTAssertTrue(boardActions.waitForExistence(timeout: 5), "Board actions menu exists on open board")
    }

    func testBoardActionsMenuHiddenInAllProjects() {
        let app = launch(showPlanner: true, showKanban: true)

        // Switch to Kanban (starts on All projects)
        app.typeKey("2", modifierFlags: .command)

        let boardActions = element(app, "kanban-board-actions")
        XCTAssertFalse(boardActions.exists, "Board actions menu is hidden in All projects")
    }

    func testBoardActionsMenuHiddenInAttention() {
        let app = launch(showPlanner: true, showKanban: true)

        // Switch to Kanban
        app.typeKey("2", modifierFlags: .command)

        // Navigate to Attention (if the sidebar is visible)
        let sidebar = app.descendants(matching: .any)["kanban-sidebar"]
        if sidebar.exists {
            let attention = app.descendants(matching: .any)["kanban-sidebar-Attention"].firstMatch
            if attention.exists {
                attention.click()

                let boardActions = element(app, "kanban-board-actions")
                XCTAssertFalse(boardActions.exists, "Board actions menu is hidden in Attention view")
            }
        }
    }

    // MARK: - Kanban New Card Button

    func testNewCardButtonExistsOnOpenBoard() {
        let app = launch(showPlanner: true, showKanban: true)

        // Switch to Kanban and open a board
        app.typeKey("2", modifierFlags: .command)
        let board = element(app, "kanban-sidebar-Platform")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.click()

        let newCardButton = element(app, "toolbar-new-card")
        XCTAssertTrue(newCardButton.waitForExistence(timeout: 5), "New card button exists on open board")
    }

    func testNewCardButtonHiddenWithoutBoard() {
        let app = launch(showPlanner: true, showKanban: true)

        // Switch to Kanban (stays on All projects)
        app.typeKey("2", modifierFlags: .command)

        let newCardButton = element(app, "toolbar-new-card")
        XCTAssertFalse(newCardButton.exists, "New card button is hidden when no board is selected")
    }

    // MARK: - Search Button Consistency

    func testSearchButtonVisibleInBothModules() {
        let app = launch(showPlanner: true, showKanban: true)

        // Check Planner
        app.typeKey("1", modifierFlags: .command)
        var searchButton = element(app, "toolbar-search")
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5), "Search button exists in Planner")

        // Check Kanban with board
        app.typeKey("2", modifierFlags: .command)
        let board = element(app, "kanban-sidebar-Platform")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.click()

        searchButton = element(app, "toolbar-search")
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5), "Search button exists in Kanban board view")
    }
}
