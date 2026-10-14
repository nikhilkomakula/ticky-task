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
        app.launch()
        return app
    }

    private func openSummary(_ app: XCUIApplication) {
        let button = app.buttons["toolbar-weekly-summary"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "toolbar Weekly Summary button should exist")
        button.click()
        XCTAssertTrue(app.buttons["summary-generate"].firstMatch.waitForExistence(timeout: 5), "sheet should open")
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
        XCTAssertEqual(count.value as? String ?? count.label, "2 selected · 1 with notes")

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
        app.buttons["summary-select-notes"].firstMatch.click()
        let count = app.staticTexts["summary-selection-count"].firstMatch
        XCTAssertEqual(count.value as? String ?? count.label, "2 selected · 2 with notes")
        app.buttons["Clear"].firstMatch.click()
        XCTAssertEqual(count.value as? String ?? count.label, "0 selected · 0 with notes")
    }

    func testCancelKeepsSelection() throws {
        let app = launchedApp()
        openSummary(app)
        task(app, "Rollout doc").click()
        app.buttons["summary-generate"].firstMatch.click()
        let cancel = app.buttons["summary-cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "generating overlay should offer Cancel")
        cancel.click()
        XCTAssertTrue(app.staticTexts["summary-error-title"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["summary-error-title"].firstMatch.label, "Generation cancelled")
        XCTAssertTrue(app.buttons["summary-generate"].firstMatch.isEnabled, "selection is kept after cancelling")
    }

    func testAuthenticationErrorIsSurfaced() throws {
        let app = launchedApp(["-uitestSummaryFailure", "auth"])
        openSummary(app)
        task(app, "Retry fix").click()
        app.buttons["summary-generate"].firstMatch.click()
        let title = app.staticTexts["summary-error-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "auth error banner should appear")
        XCTAssertEqual(title.label, "Claude authentication was rejected (401)")
        // The stub reports a gateway setup, so remediation must not just say "log in".
        let message = app.staticTexts["summary-error-message"].firstMatch
        XCTAssertTrue(message.label.contains("custom provider or credential helper (Stub Gateway)"), message.label)
        app.disclosureTriangles["Details"].firstMatch.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "req_stub123456")).firstMatch
            .waitForExistence(timeout: 2), "details should include the request id")
    }
}
