import XCTest

/// End-to-end check that a custom list is deletable from the *visible* ⋯ menu
/// (not just the hidden right-click), and that deletion is confirmed first and
/// cascades to the list's tasks. The `-uitest` seed provides one custom list,
/// "Inbox", holding ListA / ListB / ListC.
final class DeleteListUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchedApp() -> XCUIApplication {
        let app: XCUIApplication
        if let path = ProcessInfo.processInfo.environment["UITEST_APP_PATH"], !path.isEmpty {
            app = XCUIApplication(url: URL(fileURLWithPath: path))
        } else {
            app = XCUIApplication()
        }
        app.launchArguments = ["-uitest", "-calendarColumns", "7", "-weekStartsMonday", "YES", "-showWeekends", "YES"]
        app.launch()
        return app
    }

    func testDeleteCustomListFromMenuWithConfirmation() throws {
        let app = launchedApp()

        // The seeded "Inbox" list renders (proven by one of its tasks).
        let listTask = app.staticTexts["ListA"]
        XCTAssertTrue(listTask.waitForExistence(timeout: 20), "seeded custom-list task should render")

        // The delete affordance is visible (no right-click needed). A SwiftUI Menu
        // is exposed as a MenuButton on macOS (verified via the a11y hierarchy).
        let menu = app.menuButtons["list-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the ⋯ list menu should be visible")
        menu.click()

        let deleteItem = app.menuItems["Delete List"].firstMatch
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5), "Delete List should appear in the menu")
        deleteItem.click()

        // Deletion is confirmed first, and the dialog names the cascade (3 tasks).
        // The confirmation renders as a sheet; scope to it so we click the on-screen
        // button rather than its Touch Bar mirror (parented to the window).
        let confirm = app.sheets.buttons["Delete List and 3 Tasks"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation dialog should name the cascading delete")
        confirm.click()

        // The list and its tasks are gone; no custom lists remain.
        XCTAssertFalse(listTask.waitForExistence(timeout: 3), "the deleted list's tasks should disappear")
        XCTAssertFalse(app.menuButtons["list-menu"].firstMatch.waitForExistence(timeout: 2), "no custom lists remain")
    }
}
