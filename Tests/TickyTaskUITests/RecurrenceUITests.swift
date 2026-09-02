import XCTest

/// End-to-end check of the recurring-task flow, driving the real SwiftUI editor
/// under automation — the repo's rule is that editor behavior (Pickers, Steppers,
/// a `.confirmationDialog`) must be UI-tested, since a crash there slips past
/// compile, unit, and code review. The `-uitest` seed provides "Alpha" today.
final class RecurrenceUITests: XCTestCase {
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

    func testMakeTaskRecurringThenDeleteSeries() throws {
        let app = launchedApp()

        // Open the seeded task in the editor.
        let alpha = app.staticTexts["Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 20), "seeded task should render")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Alpha").count, 1, "one instance before it repeats")
        alpha.click()
        XCTAssertTrue(app.buttons["editor-done"].waitForExistence(timeout: 5), "the editor should open")

        // Turn on daily repeat and save — exercises the Repeat section's controls.
        // A SwiftUI Form `Toggle` is exposed as a Switch on macOS.
        let repeatToggle = app.switches["repeat-toggle"]
        XCTAssertTrue(repeatToggle.waitForExistence(timeout: 5), "the Repeat toggle should appear for a day task")
        repeatToggle.click()
        app.buttons["editor-done"].click()

        // Daily occurrences now fill the visible week (today's template + later days).
        XCTAssertTrue(waitForCount(app, identifier: "Alpha", atLeast: 2, timeout: 5),
                      "materialized occurrences should render across the week")

        // Delete the whole series via the row's context menu + confirmation dialog.
        // Target our own "Delete" (identified) so the query never matches the
        // disabled system Edit ▸ Delete; the dialog is a sheet whose buttons are
        // Touch-Bar-mirrored, so scope to the sheet.
        app.staticTexts["Alpha"].firstMatch.rightClick()
        let deleteItem = app.menuItems["context-delete"].firstMatch
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5), "Delete should appear in the context menu")
        deleteItem.click()

        let deleteSeries = app.sheets.buttons["Delete the Whole Series"].firstMatch
        XCTAssertTrue(deleteSeries.waitForExistence(timeout: 5), "recurring delete should confirm occurrence vs series")
        deleteSeries.click()

        XCTAssertTrue(waitForCount(app, identifier: "Alpha", atLeast: 0, exactlyZero: true, timeout: 5),
                      "deleting the series should remove every occurrence")
    }

    /// Poll until the number of elements with `identifier` meets the expectation.
    private func waitForCount(_ app: XCUIApplication, identifier: String,
                              atLeast: Int, exactlyZero: Bool = false, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = app.staticTexts.matching(identifier: identifier).count
            if exactlyZero ? count == 0 : count >= atLeast { return true }
            usleep(200_000)
        }
        return false
    }
}
