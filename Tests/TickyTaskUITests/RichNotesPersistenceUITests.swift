import XCTest

final class RichNotesPersistenceUITests: XCTestCase {
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

    private func openAlpha(_ app: XCUIApplication) -> XCUIElement {
        let alpha = app.staticTexts["Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 20))
        alpha.click()
        let editor = app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        return editor
    }

    private func editorValue(_ editor: XCUIElement) -> String { editor.value as? String ?? "" }

    func testCommandBBoldsSelectionAndPersists() throws {
        let app = launchedApp()
        var editor = openAlpha(app)
        editor.click()
        editor.typeText("Persistent bold text")
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey("b", modifierFlags: .command)
        XCTAssertEqual(app.buttons["notes-bold"].value as? String, "On")
        app.buttons["Done"].click()

        editor = openAlpha(app)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        XCTAssertEqual(app.buttons["notes-bold"].value as? String, "On", "bold should survive close and reopen")
    }

    func testBulletedListContinuesOnReturn() throws {
        let app = launchedApp()
        let editor = openAlpha(app)
        editor.click()
        app.buttons["notes-bullet"].click()
        editor.click()
        editor.typeText("first")
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("second")
        XCTAssertEqual(editorValue(editor), "• first\n• second")
    }

    func testReturnOnEmptyBulletEndsList() throws {
        let app = launchedApp()
        let editor = openAlpha(app)
        editor.click()
        app.buttons["notes-bullet"].click()
        editor.click()
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("plain")
        XCTAssertEqual(editorValue(editor), "plain")
    }

    func testNumberedListContinuesAndRenumbers() throws {
        let app = launchedApp()
        let editor = openAlpha(app)
        editor.click()
        app.buttons["notes-numbered"].click()
        editor.click()
        editor.typeText("first")
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("second")
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("third")
        XCTAssertEqual(editorValue(editor), "1. first\n2. second\n3. third")
    }
}
