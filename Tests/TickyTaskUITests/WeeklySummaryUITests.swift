import XCTest
import AppKit

/// End-to-end checks of the Weekly Summary sheet against the `-uitest` stub
/// generator/catalog (never a real AI provider). The `-uitestSummarySeed` seed
/// adds today: "Retry fix" and "Rollout doc" (both with notes) and
/// "No-notes task".
final class WeeklySummaryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchedApp(_ extra: [String] = []) -> XCUIApplication {
        let app: XCUIApplication
        if let path = ProcessInfo.processInfo.environment["UITEST_APP_PATH"], !path.isEmpty {
            app = XCUIApplication(url: URL(fileURLWithPath: path))
        } else {
            app = XCUIApplication()
        }
        app.launchArguments = ["-uitest", "-uitestSummarySeed", "-calendarColumns", "7",
                               "-weekStartsMonday", "YES", "-showWeekends", "YES"] + extra
        app.launchWithMainWindow()
        return app
    }

    private func openSummary(_ app: XCUIApplication) {
        let button = app.buttons["toolbar-weekly-summary"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "toolbar Weekly Summary button should exist")
        button.click()
        let generate = app.buttons["summary-generate"].firstMatch
        if !generate.waitForExistence(timeout: 4) { button.click() }   // a click during window layout can miss
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "sheet should open")
    }

    /// A static text's string (macOS exposes it as the value, not the label).
    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    /// Waits until a static text shows `expected` (the UI updates asynchronously).
    private func waitForText(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while text(of: element) != expected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(text(of: element), expected)
    }

    private func task(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "summary-task-\(title)").firstMatch
    }

    func testSelectGenerateEditAndCopy() throws {
        let app = launchedApp()
        openSummary(app)

        let generate = app.buttons["summary-generate"].firstMatch
        XCTAssertFalse(generate.isEnabled, "Generate needs a selected task with notes")

        // A task without notes alone is not enough.
        let noNotes = task(app, "No-notes task")
        XCTAssertTrue(noNotes.waitForExistence(timeout: 5))
        noNotes.click()
        XCTAssertFalse(generate.isEnabled, "selection without notes must not enable Generate")

        // Selecting a task that has notes enables Generate.
        task(app, "Retry fix").click()
        XCTAssertTrue(generate.isEnabled)
        let count = app.staticTexts["summary-selection-count"].firstMatch
        XCTAssertEqual(text(of: count), "2 selected · 1 with notes")

        generate.click()
        let text = app.textViews["summary-text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), "result editor should appear")
        let value = text.value as? String ?? ""
        XCTAssertTrue(value.contains("Retry fix"), "stub summary should include the selected task")
        XCTAssertTrue(value.contains("No-notes task"))
        XCTAssertFalse(value.contains("Rollout doc"), "unselected tasks must not be sent")

        // Edit, then copy via the icon: the clipboard gets the EDITED text.
        text.click()
        text.typeKey(.end, modifierFlags: .command)
        text.typeText("\nEdited line.")
        NSPasteboard.general.clearContents()
        app.buttons["summary-copy"].firstMatch.click()
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("Retry fix") && copied.contains("Edited line."), "copy icon should copy the edited summary")
        XCTAssertTrue(app.buttons["Copied"].firstMatch.waitForExistence(timeout: 2), "copy icon should confirm")
    }

    func testSelectAllWithNotesAndClear() throws {
        let app = launchedApp()
        openSummary(app)
        XCTAssertTrue(task(app, "Retry fix").waitForExistence(timeout: 5), "seeded tasks should be listed")
        let selectNotes = app.buttons["summary-select-notes"].firstMatch
        XCTAssertTrue(selectNotes.isEnabled, "seeded notes enable Select all with notes")
        selectNotes.click()
        let count = app.staticTexts["summary-selection-count"].firstMatch
        waitForText(count, "2 selected · 2 with notes")
        app.buttons["Clear"].firstMatch.click()
        waitForText(count, "0 selected · 0 with notes")
    }

    func testCancelKeepsSelection() throws {
        let app = launchedApp(["-uitestSummaryDelay", "30"])
        openSummary(app)
        task(app, "Rollout doc").click()
        XCTAssertTrue(app.buttons["summary-generate"].firstMatch.isEnabled, "selecting a task with notes enables Generate")
        app.buttons["summary-generate"].firstMatch.click()
        let cancel = app.buttons["summary-cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "generating overlay should offer Cancel")
        cancel.click()
        XCTAssertTrue(app.staticTexts["summary-error-title"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(text(of: app.staticTexts["summary-error-title"].firstMatch), "Generation cancelled")
        XCTAssertTrue(app.buttons["summary-generate"].firstMatch.isEnabled, "selection is kept after cancelling")
    }

    func testAuthenticationErrorIsSurfaced() throws {
        let app = launchedApp(["-uitestSummaryFailure", "auth"])
        openSummary(app)
        task(app, "Retry fix").click()
        XCTAssertTrue(app.buttons["summary-generate"].firstMatch.isEnabled, "selecting a task with notes enables Generate")
        app.buttons["summary-generate"].firstMatch.click()
        let title = app.staticTexts["summary-error-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "auth error banner should appear")
        XCTAssertEqual(text(of: title), "Codex authentication was rejected (401)")
        // The stub reports a gateway setup, so remediation must not just say "log in".
        let message = app.staticTexts["summary-error-message"].firstMatch
        XCTAssertTrue(text(of: message).contains("custom provider or credential helper from your Codex configuration (Stub Gateway)"), text(of: message))
        // A link-styled button isn't exposed as a plain Button on macOS.
        let toggle = app.descendants(matching: .any).matching(identifier: "summary-error-details-toggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "details toggle should exist")
        toggle.click()
        let details = app.staticTexts["summary-error-details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 3), "details should expand")
        XCTAssertTrue(text(of: details).contains("Request ID: req_stub123456"), text(of: details))
        XCTAssertTrue(text(of: details).contains("HTTP status: 401"), text(of: details))
    }

    func testCustomInstructionsAddEditClearPersist() throws {
        let app = launchedApp()
        openSummary(app)
        app.buttons["summary-instructions-button"].firstMatch.click()
        let editor = app.textViews["summary-instructions"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "instructions editor should open")
        // It starts with the default instructions.
        let defaults = editor.value as? String ?? ""
        XCTAssertTrue(defaults.hasPrefix("Audience: my team and manager"), "default instructions are pre-filled: \(defaults)")
        app.buttons["summary-instructions-clear"].firstMatch.click()
        XCTAssertEqual(editor.value as? String ?? "", "")
        editor.click()
        editor.typeText("Write for my manager. Max 150 words.")
        app.buttons["summary-instructions-done"].firstMatch.click()

        // Reopen: the instructions persisted; edit them.
        app.buttons["summary-instructions-button"].firstMatch.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Write for my manager. Max 150 words.")
        editor.click()
        editor.typeKey(.end, modifierFlags: .command)
        editor.typeText(" Lead with risks.")
        XCTAssertEqual(editor.value as? String, "Write for my manager. Max 150 words. Lead with risks.")

        // Clear removes them; Restore defaults brings the defaults back.
        app.buttons["summary-instructions-clear"].firstMatch.click()
        XCTAssertEqual(editor.value as? String ?? "", "")
        app.buttons["summary-instructions-restore"].firstMatch.click()
        XCTAssertEqual(editor.value as? String, defaults)
        app.buttons["summary-instructions-done"].firstMatch.click()
    }

    func testConnectionPopoverShowsLocalModelInputs() throws {
        let app = launchedApp()
        openSummary(app)
        let connection = app.buttons["summary-connection"].firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertTrue(connection.label.contains("ChatGPT account"), "default connection is the ChatGPT account: \(connection.label)")
        connection.click()
        let kind = app.popUpButtons["summary-connection-kind"].firstMatch
        XCTAssertTrue(kind.waitForExistence(timeout: 5), "connection picker should appear")
        kind.click()
        app.menuItems["Local model"].firstMatch.click()
        XCTAssertTrue(app.popUpButtons["summary-local-server"].firstMatch.waitForExistence(timeout: 3), "server picker")
        XCTAssertTrue(app.textFields["summary-local-url"].firstMatch.exists, "base URL field")
        XCTAssertTrue(app.secureTextFields["summary-local-key"].firstMatch.exists, "API key field")
        // Switch back so later tests start from the default.
        kind.click()
        app.menuItems["ChatGPT account"].firstMatch.click()
    }

    func testToolbarRightSideOrderEndsWithTodayNavigation() throws {
        let app = launchedApp()
        let summary = app.buttons["toolbar-weekly-summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        let search = app.buttons["toolbar-search"].firstMatch
        let settings = app.buttons["toolbar-settings"].firstMatch
        let today = app.buttons["toolbar-today"].firstMatch
        XCTAssertTrue(settings.exists && search.exists && today.exists, "toolbar buttons should exist")
        XCTAssertGreaterThan(summary.frame.minX, search.frame.minX, "Weekly Summary follows Search")
        XCTAssertGreaterThan(settings.frame.minX, summary.frame.minX, "Settings follows Weekly Summary")
        XCTAssertGreaterThan(today.frame.minX, settings.frame.minX, "‹ Today › is at the far right")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(window.maxX - today.frame.maxX, 80, "‹ Today › hugs the right edge")
    }
}
