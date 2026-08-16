import XCTest

final class RichNotesPersistenceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testChecklistTextAndCheckedStatePersist() throws {
        let app: XCUIApplication
        if let path = ProcessInfo.processInfo.environment["UITEST_APP_PATH"], !path.isEmpty {
            app = XCUIApplication(url: URL(fileURLWithPath: path))
        } else {
            app = XCUIApplication()
        }
        app.launchArguments = ["-uitest", "-calendarColumns", "7", "-weekStartsMonday", "YES", "-showWeekends", "YES"]
        app.launch()

        let alpha = app.staticTexts["Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 20))
        alpha.click()

        let editor = app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("Persistent checklist item")
        app.buttons["notes-checklist"].click()

        // notes-checkbox-0: the accessible toggle button for the first checkbox block.
        // (macOS 26 TextEditor link-tap in edit mode does not fire openURL;
        // the explicit toggle button is the reliable surface.)
        let checkbox = app.buttons["notes-checkbox-0"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5), "first checkbox toggle button should appear")
        checkbox.click()
        app.buttons["Done"].click()

        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        alpha.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let value = (editor.value as? String) ?? ""
        XCTAssertTrue(value.contains("Persistent checklist item"), "note text should persist")
        XCTAssertTrue(value.contains("☑"), "checked checkbox should persist")
    }
}
