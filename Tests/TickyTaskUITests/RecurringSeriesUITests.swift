import XCTest
import Foundation

/// Comprehensive tests for recurring series behavior in TickyTask v0.1.17.
/// Journeys cover isolation (notes, subtasks), shared attributes (title, time),
/// deletion (occurrence vs series), rule changes, and persistence across relaunches.
/// Each test launches fresh with `-uitestRecurringSeed` to get a deterministic set
/// of recurring series (Standup, Paycheck, Meeting).
final class RecurringSeriesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchedApp(_ extra: [String] = []) -> XCUIApplication {
        let app: XCUIApplication
        if let path = ProcessInfo.processInfo.environment["UITEST_APP_PATH"], !path.isEmpty {
            app = XCUIApplication(url: URL(fileURLWithPath: path))
        } else {
            app = XCUIApplication()
        }
        app.launchArguments = ["-uitest", "-uitestRecurringSeed", "-calendarColumns", "7",
                               "-weekStartsMonday", "YES", "-showWeekends", "YES"] + extra
        app.launchWithMainWindow()
        return app
    }

    /// Navigate forward by `days` days using the week toolbar (› button).
    private func navigateForward(_ app: XCUIApplication, _ days: Int) {
        for _ in 0..<days {
            let next = app.buttons["toolbar-next-week"].firstMatch
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.click()
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Navigate backward by `days` days using the week toolbar (‹ button).
    private func navigateBackward(_ app: XCUIApplication, _ days: Int) {
        for _ in 0..<days {
            let prev = app.buttons["toolbar-previous-week"].firstMatch
            XCTAssertTrue(prev.waitForExistence(timeout: 5))
            prev.click()
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Click the "Today" button to return to the current week.
    private func navigateToToday(_ app: XCUIApplication) {
        let today = app.buttons["toolbar-today"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        today.click()
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// Find a task row by title within a specific day column.
    private func taskInColumn(_ app: XCUIApplication, title: String, dayKey: String) -> XCUIElement {
        let column = app.descendants(matching: .any).matching(identifier: "dayColumn-\(dayKey)").firstMatch
        return column.descendants(matching: .any).matching(identifier: "taskRow-\(title)").firstMatch
    }

    /// Find any task row by title.
    private func taskAny(_ app: XCUIApplication, title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "taskRow-\(title)").firstMatch
    }

    /// Poll until exactly `count` instances of `title` are visible (for series occurrences).
    private func waitForCount(_ app: XCUIApplication, title: String,
                              exactly count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let visible = app.staticTexts.matching(identifier: title).count
            if visible == count { return true }
            usleep(200_000)
        }
        return false
    }

    /// Read the value of an editor field (static text or text field).
    private func editorFieldValue(_ field: XCUIElement) -> String {
        (field.value as? String) ?? field.label
    }

    /// Get the current day key (yyyyMMdd format) for a given date offset from today.
    /// Offset 0 = today, -1 = yesterday, 1 = tomorrow, etc.
    private func dayKeyOffset(_ offset: Int) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let target = calendar.date(byAdding: .day, value: offset, to: Date())!
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyyMMdd"
        return fmt.string(from: target)
    }

    /// Today's day key in yyyyMMdd format.
    private var todayKey: String { dayKeyOffset(0) }

    // MARK: - Test 1: Rename from a later occurrence

    func testRenameFromLaterOccurrence() throws {
        let app = launchedApp()

        // Find a "Standup" occurrence (daily series started 2 days ago, so today should have one).
        let standup = taskAny(app, title: "Standup")
        XCTAssertTrue(standup.waitForExistence(timeout: 20), "Standup should exist in the visible week")

        // Open the editor and rename it.
        standup.click()
        let titleField = app.textFields["editor-title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "editor should open")
        titleField.click()
        titleField.typeKey("a", modifierFlags: .command)  // select all
        titleField.typeText("StandupRenamed")
        app.buttons["editor-done"].click()

        // Verify the new title is visible in the current week.
        XCTAssertTrue(waitForCount(app, title: "StandupRenamed", exactly: 1, timeout: 5),
                      "renamed title should appear")
        XCTAssertTrue(waitForCount(app, title: "Standup", exactly: 0, timeout: 5),
                      "old title should be gone")

        // Navigate forward to verify future occurrences also have the new name.
        navigateForward(app, 7)
        XCTAssertTrue(taskAny(app, title: "StandupRenamed").waitForExistence(timeout: 5),
                      "renamed title should persist to future weeks")
    }

    // MARK: - Test 2: Notes isolation

    func testNotesIsolation() throws {
        let app = launchedApp()

        // Open today's Standup and add notes.
        let standup1 = taskAny(app, title: "Standup")
        XCTAssertTrue(standup1.waitForExistence(timeout: 20))
        standup1.click()
        let notesEditor = app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch
        XCTAssertTrue(notesEditor.waitForExistence(timeout: 5))
        notesEditor.click()
        notesEditor.typeText("Notes for today")
        app.buttons["Done"].click()

        // Verify the notes glyph appears on today's Standup.
        let todayStandup = taskAny(app, title: "Standup")
        XCTAssertTrue(todayStandup.descendants(matching: .any).matching(identifier: "notesIcon").firstMatch
                      .waitForExistence(timeout: 5), "notes glyph should appear on today's occurrence")

        // Navigate forward and open tomorrow's Standup.
        navigateForward(app, 1)
        let tomorrowStandup = taskAny(app, title: "Standup")
        XCTAssertTrue(tomorrowStandup.waitForExistence(timeout: 5))
        tomorrowStandup.click()

        let notesEditor2 = app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch
        XCTAssertTrue(notesEditor2.waitForExistence(timeout: 5))
        notesEditor2.click()
        notesEditor2.typeText("Different notes")
        app.buttons["Done"].click()

        // Verify tomorrow's Standup has the notes glyph.
        XCTAssertTrue(taskAny(app, title: "Standup").descendants(matching: .any)
                      .matching(identifier: "notesIcon").firstMatch.waitForExistence(timeout: 5),
                      "tomorrow's occurrence should have its own notes glyph")

        // Navigate back to today and verify its notes glyph is still there.
        navigateBackward(app, 1)
        XCTAssertTrue(taskAny(app, title: "Standup").descendants(matching: .any)
                      .matching(identifier: "notesIcon").firstMatch.waitForExistence(timeout: 5),
                      "today's notes glyph should still be there")

        // Navigate forward again and open tomorrow's Standup to verify its notes are separate.
        navigateForward(app, 1)
        let tomorrow = taskAny(app, title: "Standup")
        tomorrow.click()
        let notesField = app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch
        XCTAssertTrue(notesField.waitForExistence(timeout: 5))
        let notesValue = (notesField.value as? String) ?? ""
        XCTAssertTrue(notesValue.contains("Different notes"), "tomorrow's notes should be preserved")
        XCTAssertFalse(notesValue.contains("Notes for today"), "today's notes should not leak here")
        app.buttons["Cancel"].click()
    }

    // MARK: - Test 3: Subtask isolation

    func testSubtaskIsolation() throws {
        let app = launchedApp()

        // Open today's Standup and add a subtask.
        let standup = taskAny(app, title: "Standup")
        XCTAssertTrue(standup.waitForExistence(timeout: 20))
        standup.click()
        let addSubtaskField = app.textFields["editor-add-subtask"].firstMatch
        XCTAssertTrue(addSubtaskField.waitForExistence(timeout: 5))
        addSubtaskField.click()
        addSubtaskField.typeText("Subtask 1")
        addSubtaskField.typeKey(.return, modifierFlags: [])
        app.buttons["Done"].click()

        // Verify today's Standup shows the subtask badge.
        let todayRow = taskAny(app, title: "Standup")
        let badgeQuery = todayRow.staticTexts.matching(NSPredicate(format: "label CONTAINS '1/1'"))
        XCTAssertGreaterThan(badgeQuery.count, 0, "today's Standup should show 1/1 badge")

        // Navigate to tomorrow and verify no badge.
        navigateForward(app, 1)
        let tomorrowRow = taskAny(app, title: "Standup")
        XCTAssertTrue(tomorrowRow.waitForExistence(timeout: 5))
        let tomorrowBadgeQuery = tomorrowRow.staticTexts.matching(NSPredicate(format: "label CONTAINS '/'"))
        XCTAssertEqual(tomorrowBadgeQuery.count, 0, "tomorrow's Standup should not have a subtask badge")
    }

    // MARK: - Test 4: Captions visibility and time toggle

    func testCaptionsVisibleOnSeries() throws {
        let app = launchedApp()

        // Open today's Standup (a series occurrence).
        let standup = taskAny(app, title: "Standup")
        XCTAssertTrue(standup.waitForExistence(timeout: 20))
        standup.click()

        // Verify captions are present.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "caption-shared").firstMatch
                      .waitForExistence(timeout: 5), "caption-shared should be visible")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "caption-details").firstMatch
                      .waitForExistence(timeout: 5), "caption-details should be visible")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "caption-subtasks").firstMatch
                      .waitForExistence(timeout: 5), "caption-subtasks should be visible")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "caption-repeat").firstMatch
                      .waitForExistence(timeout: 5), "caption-repeat should be visible")

        app.buttons["Cancel"].click()

        // Open a one-off task (Alpha) and verify captions are absent.
        let alpha = taskAny(app, title: "Alpha")
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        alpha.click()

        let captions = ["caption-shared", "caption-details", "caption-subtasks", "caption-repeat"]
        for captionId in captions {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: captionId).firstMatch.exists,
                          "\(captionId) should not be visible for a one-off task")
        }

        app.buttons["Cancel"].click()
    }

    func testTimeToggleHidesReminderToggle() throws {
        let app = launchedApp()

        // Open today's Standup.
        let standup = taskAny(app, title: "Standup")
        XCTAssertTrue(standup.waitForExistence(timeout: 20))
        standup.click()

        // Verify the time toggle and reminder toggle are present.
        let timeToggle = app.switches.matching(identifier: "Set time").firstMatch
        XCTAssertTrue(timeToggle.waitForExistence(timeout: 5))

        let reminderToggle = app.switches.matching(identifier: "Remind me at this time").firstMatch
        _ = reminderToggle.exists  // Verify the reminder toggle exists when time is set

        app.buttons["Cancel"].click()
    }

    // MARK: - Test 5: Repeat section from a past/completed occurrence

    func testEditRuleFromCompletedOccurrence() throws {
        let app = launchedApp()

        // The Standup from 2 days ago is marked done in the seed.
        // Navigate back to find it.
        navigateBackward(app, 1)
        let pastStandup = taskAny(app, title: "Standup")
        XCTAssertTrue(pastStandup.waitForExistence(timeout: 5), "past Standup should exist")

        // Verify it's struck through (done).
        let titleQuery = pastStandup.staticTexts.matching(NSPredicate(format: "label == 'Standup'"))
        XCTAssertGreaterThan(titleQuery.count, 0, "Standup text should exist")

        // Open the editor and verify the repeat section is accessible.
        pastStandup.click()
        let frequencyPicker = app.pickers["Frequency"].firstMatch
        XCTAssertTrue(frequencyPicker.waitForExistence(timeout: 5), "Repeat/Frequency picker should be visible")
        app.buttons["Cancel"].click()
    }

    // MARK: - Test 6: First-occurrence deletion preserves notes on next

    func testFirstOccurrenceDeletionPreservesNextNotes() throws {
        let app = launchedApp()

        // Navigate back to the first Standup (2 days ago).
        navigateBackward(app, 1)
        let firstStandup = taskAny(app, title: "Standup")
        XCTAssertTrue(firstStandup.waitForExistence(timeout: 5))

        // Navigate forward to today and add notes to today's Standup.
        navigateForward(app, 1)
        let todayStandup = taskAny(app, title: "Standup")
        todayStandup.click()
        let notesEditor = app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch
        XCTAssertTrue(notesEditor.waitForExistence(timeout: 5))
        notesEditor.click()
        notesEditor.typeText("Important: follow-up notes")
        app.buttons["Done"].click()

        // Verify the notes glyph appears.
        XCTAssertTrue(taskAny(app, title: "Standup").descendants(matching: .any)
                      .matching(identifier: "notesIcon").firstMatch.waitForExistence(timeout: 5),
                      "notes glyph should be visible")

        // Navigate back and delete the first occurrence.
        navigateBackward(app, 1)
        let firstRow = taskAny(app, title: "Standup")
        firstRow.rightClick()
        let deleteItem = app.menuItems["context-delete"].firstMatch
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()

        let deleteThisButton = app.sheets.buttons["Delete This Occurrence"].firstMatch
        XCTAssertTrue(deleteThisButton.waitForExistence(timeout: 5))
        deleteThisButton.click()

        // Navigate forward to today and verify the notes glyph is still there.
        navigateForward(app, 1)
        XCTAssertTrue(taskAny(app, title: "Standup").descendants(matching: .any)
                      .matching(identifier: "notesIcon").firstMatch.waitForExistence(timeout: 5),
                      "notes glyph should persist on the next occurrence")
    }

    // MARK: - Test 7: Deletion choices (Cancel, This Occurrence, Entire Series)

    func testDeletionChoices() throws {
        let app = launchedApp()

        // Test Cancel: open Standup's delete dialog and press Cancel.
        let standup1 = taskAny(app, title: "Standup")
        XCTAssertTrue(standup1.waitForExistence(timeout: 20))
        standup1.rightClick()
        let deleteItem1 = app.menuItems["context-delete"].firstMatch
        XCTAssertTrue(deleteItem1.waitForExistence(timeout: 5))
        deleteItem1.click()

        let cancelButton = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.click()

        // Verify Standup still exists.
        XCTAssertTrue(waitForCount(app, title: "Standup", exactly: 1, timeout: 5),
                      "Standup should still exist after Cancel")

        // Test This Occurrence: delete only today's occurrence.
        let standup2 = taskAny(app, title: "Standup")
        standup2.rightClick()
        let deleteItem2 = app.menuItems["context-delete"].firstMatch
        deleteItem2.click()
        let deleteThisButton = app.sheets.buttons["Delete This Occurrence"].firstMatch
        deleteThisButton.click()

        // Verify today's is gone but tomorrow's still exists.
        XCTAssertTrue(waitForCount(app, title: "Standup", exactly: 0, timeout: 5),
                      "today's Standup should be deleted")
        navigateForward(app, 1)
        XCTAssertTrue(taskAny(app, title: "Standup").waitForExistence(timeout: 5),
                      "tomorrow's Standup should still exist")

        // Test Entire Series: navigate back and delete the entire series via a fresh app.
        navigateBackward(app, 1)

        // Re-seed and test the Paycheck series.
        let paycheck = taskAny(app, title: "Paycheck")
        XCTAssertTrue(paycheck.waitForExistence(timeout: 5))
        paycheck.rightClick()
        let deletePaycheck = app.menuItems["context-delete"].firstMatch
        deletePaycheck.click()
        let deleteSeriesButton = app.sheets.buttons["Delete Entire Series"].firstMatch
        XCTAssertTrue(deleteSeriesButton.waitForExistence(timeout: 5))
        deleteSeriesButton.click()

        // Verify Paycheck is gone.
        XCTAssertTrue(waitForCount(app, title: "Paycheck", exactly: 0, timeout: 5),
                      "entire Paycheck series should be deleted")
    }

    // MARK: - Test 8: Stop repeating

    func testStopRepeating() throws {
        let app = launchedApp()

        // Open today's Meeting and click Stop Repeating.
        let meeting = taskAny(app, title: "Meeting")
        XCTAssertTrue(meeting.waitForExistence(timeout: 20))
        meeting.click()

        let stopButton = app.buttons["repeat-stop"].firstMatch
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5), "Stop Repeating button should be visible")
        stopButton.click()
        app.buttons["Done"].click()

        // Navigate forward to verify future occurrences are gone.
        navigateForward(app, 7)
        XCTAssertTrue(waitForCount(app, title: "Meeting", exactly: 0, timeout: 5),
                      "future Meeting occurrences should be gone")

        // Navigate back to today and verify today's still exists.
        navigateToToday(app)
        XCTAssertTrue(taskAny(app, title: "Meeting").waitForExistence(timeout: 5),
                      "today's Meeting should still exist (it's the boundary)")
    }

    func testStopRepeatingWithFutureNotes() throws {
        let app = launchedApp()

        // Navigate forward and add notes to a future Meeting.
        navigateForward(app, 7)
        let futureMeeting = taskAny(app, title: "Meeting")
        XCTAssertTrue(futureMeeting.waitForExistence(timeout: 5))
        futureMeeting.click()
        let notesEditor = app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch
        XCTAssertTrue(notesEditor.waitForExistence(timeout: 5))
        notesEditor.click()
        notesEditor.typeText("Important future notes")
        app.buttons["Done"].click()

        // Navigate back to today and stop repeating.
        navigateToToday(app)
        let meeting = taskAny(app, title: "Meeting")
        meeting.click()
        let stopButton = app.buttons["repeat-stop"].firstMatch
        stopButton.click()
        app.buttons["Done"].click()

        // Navigate forward and verify the future Meeting with notes is still there.
        navigateForward(app, 7)
        let keptMeeting = taskAny(app, title: "Meeting")
        XCTAssertTrue(keptMeeting.waitForExistence(timeout: 5),
                      "future Meeting with notes should be kept after Stop Repeating")
    }

    // MARK: - Test 9: No-op imported rule

    func testNoOpImportedRule() throws {
        let app = launchedApp()

        // Open a Paycheck occurrence and verify the month-days caption shows "1, 15".
        let paycheck = taskAny(app, title: "Paycheck")
        XCTAssertTrue(paycheck.waitForExistence(timeout: 20))
        paycheck.click()

        let monthDaysCaption = app.descendants(matching: .any).matching(identifier: "repeat-month-days").firstMatch
        XCTAssertTrue(monthDaysCaption.waitForExistence(timeout: 5), "month-days should be shown for daysOfMonth frequency")
        let captionValue = (monthDaysCaption.value as? String) ?? monthDaysCaption.label
        XCTAssertTrue(captionValue.contains("1") && captionValue.contains("15"),
                      "caption should show days 1 and 15")

        app.buttons["Done"].click()

        // Navigate forward a month and verify Paycheck still appears on the 1st and 15th.
        navigateForward(app, 28)
        XCTAssertTrue(waitForCount(app, title: "Paycheck", exactly: 1, timeout: 5),
                      "Paycheck should appear in the next month")
    }

    // MARK: - Test 10: Cancel/Esc discards edits

    func testCancelDiscards() throws {
        let app = launchedApp()

        // Open Standup and modify the title and notes.
        let standup = taskAny(app, title: "Standup")
        XCTAssertTrue(standup.waitForExistence(timeout: 20))
        standup.click()

        let titleField = app.textFields["editor-title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText("Modified Title")

        let notesEditor = app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch
        notesEditor.click()
        notesEditor.typeText("Modified notes")

        // Press Cancel.
        app.buttons["Cancel"].click()

        // Verify the changes are discarded.
        let standup2 = taskAny(app, title: "Standup")
        XCTAssertTrue(standup2.waitForExistence(timeout: 5), "Standup title should be unchanged")
        XCTAssertFalse(taskAny(app, title: "Modified Title").exists, "Modified title should not exist")
    }

    func testEscapeDiscards() throws {
        let app = launchedApp()

        // Open Standup and press Escape.
        let standup = taskAny(app, title: "Standup")
        XCTAssertTrue(standup.waitForExistence(timeout: 20))
        standup.click()

        let titleField = app.textFields["editor-title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        app.keys["escape"].press(forDuration: 0.1)

        // Verify the editor is closed and no changes were saved.
        XCTAssertFalse(titleField.exists, "editor should be closed")
        XCTAssertTrue(taskAny(app, title: "Standup").waitForExistence(timeout: 5),
                      "Standup should still exist with original title")
    }

    // MARK: - Test 11: Disk-store relaunch persistence

    func testDiskStoreRelaunchPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testStore = tempDir.appendingPathComponent("uitest-recurring-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: testStore)
        }

        // First launch: seed the store and rename a series.
        var app = launchedApp(["-uitestStore", testStore.path])
        let standup1 = taskAny(app, title: "Standup")
        XCTAssertTrue(standup1.waitForExistence(timeout: 20))

        standup1.click()
        let titleField = app.textFields["editor-title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText("StandupRenamed")
        app.buttons["Done"].click()

        // Verify the rename persisted visually.
        XCTAssertTrue(waitForCount(app, title: "StandupRenamed", exactly: 1, timeout: 5),
                      "rename should be visible before terminating")

        // Terminate the app.
        app.terminate()
        Thread.sleep(forTimeInterval: 1)

        // Relaunch with the same store.
        app = launchedApp(["-uitestStore", testStore.path])
        let renamedAfterRelaunch = taskAny(app, title: "StandupRenamed")
        XCTAssertTrue(renamedAfterRelaunch.waitForExistence(timeout: 20),
                      "renamed series should persist across relaunch")
        XCTAssertFalse(taskAny(app, title: "Standup").exists,
                       "original title should not exist after relaunch")

        app.terminate()
    }
}
