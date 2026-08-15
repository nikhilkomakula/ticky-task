import XCTest

/// End-to-end verification that a REAL drag reorders tasks. Launches the app with
/// `-uitest` (isolated in-memory store seeded with Alpha/Bravo/Charlie in the first
/// week column) and performs an actual click-drag, then asserts the visible order
/// by comparing on-screen row positions. This is the harness that catches the
/// gesture/layout failures unit tests and static review cannot.
final class DragReorderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        // Launch the EXACT built app by path when provided (TEST_RUNNER_UITEST_APP_PATH),
        // bypassing LaunchServices bundle-id resolution — otherwise XCUITest's
        // "Launch com.tickytask.mac" can resolve to a stale registered copy.
        let app: XCUIApplication
        if let path = ProcessInfo.processInfo.environment["UITEST_APP_PATH"], !path.isEmpty {
            app = XCUIApplication(url: URL(fileURLWithPath: path))
        } else {
            app = XCUIApplication()
        }
        // Force 7 columns so TODAY (where -uitest seeds) is always visible, a Monday
        // week start, and weekends shown — otherwise a weekend "today" would be
        // filtered out of the week view and the seeded rows wouldn't appear.
        app.launchArguments = ["-uitest", "-calendarColumns", "7", "-weekStartsMonday", "YES", "-showWeekends", "YES"]
        app.launch()
        return app
    }

    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "taskRow-\(title)").firstMatch
    }

    /// Drag a task onto a DIFFERENT day column and confirm it moves there (the key
    /// cross-container use case).
    func testDragTaskToAnotherDayMovesIt() throws {
        let app = launchedApp()
        let alpha = row(app, "Alpha")
        XCTAssertTrue(alpha.waitForExistence(timeout: 20), "Alpha should exist before dragging")
        let mondayColumn = app.descendants(matching: .any).matching(identifier: "dayColumn-20260810").firstMatch
        XCTAssertTrue(mondayColumn.waitForExistence(timeout: 5), "Monday column should be visible")

        let alphaStartX = alpha.frame.midX
        // Drag Alpha from today's column onto Monday's (empty) column body.
        let start = alpha.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dest = mondayColumn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2.0))
        start.press(forDuration: 0.35, thenDragTo: dest)
        Thread.sleep(forTimeInterval: 1.2)

        let alphaEndX = row(app, "Alpha").frame.midX
        XCTAssertLessThan(alphaEndX, alphaStartX - 150, "Alpha moved left into a different day column")
    }

    /// Sanity: the seeded rows show up in the expected initial order.
    func testSeededRowsAppearInOrder() throws {
        let app = launchedApp()
        XCTAssertTrue(row(app, "Alpha").waitForExistence(timeout: 20), "seeded rows should appear")
        XCTAssertTrue(row(app, "Bravo").waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, "Charlie").waitForExistence(timeout: 5))

        XCTAssertLessThan(row(app, "Alpha").frame.minY, row(app, "Bravo").frame.minY, "Alpha above Bravo")
        XCTAssertLessThan(row(app, "Bravo").frame.minY, row(app, "Charlie").frame.minY, "Bravo above Charlie")
    }

    /// Drag Alpha down past Charlie's midpoint → it should end up last (Bravo, Charlie, Alpha).
    func testDragAlphaBelowCharlieReorders() throws {
        let app = launchedApp()
        let alpha = row(app, "Alpha")
        let charlie = row(app, "Charlie")
        XCTAssertTrue(alpha.waitForExistence(timeout: 20), "Alpha should exist before dragging")
        XCTAssertTrue(charlie.waitForExistence(timeout: 5))

        let alphaStartY = alpha.frame.minY
        let charlieStartY = charlie.frame.minY
        XCTAssertLessThan(alphaStartY, charlieStartY, "precondition: Alpha starts above Charlie")

        // Real click-drag from Alpha's center to just below Charlie's midpoint.
        let start = alpha.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = charlie.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.35, thenDragTo: end)

        // Let the commit + spring settle, then re-read positions.
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(row(app, "Alpha").waitForExistence(timeout: 5), "Alpha still present after drag")

        let alphaY = row(app, "Alpha").frame.minY
        let bravoY = row(app, "Bravo").frame.minY
        let charlieY = row(app, "Charlie").frame.minY

        XCTAssertLessThan(bravoY, charlieY, "after drag: Bravo above Charlie")
        XCTAssertLessThan(charlieY, alphaY, "after drag: Alpha moved below Charlie (reorder happened)")
    }

    /// A plain click (no movement) must still open the editor — i.e. the
    /// high-priority drag gesture does NOT swallow taps.
    func testTapRowOpensEditor() throws {
        let app = launchedApp()
        // Click the title text (not the row's leading checkbox) to exercise tap-to-edit.
        let title = app.staticTexts["Alpha"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "Alpha title should exist")
        XCTAssertFalse(app.buttons["Done"].exists, "editor should not be open initially")
        title.click()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "clicking a task opens the editor (tap not swallowed by the drag gesture)")
    }

    /// Fine same-container reorder DOWN: drag Alpha just past Bravo's midpoint →
    /// [Bravo, Alpha, Charlie]. Exercises a small adjacent swap, not a big move.
    func testFineReorderDownSwapsAdjacent() throws {
        let app = launchedApp()
        let alpha = row(app, "Alpha")
        let bravo = row(app, "Bravo")
        XCTAssertTrue(alpha.waitForExistence(timeout: 20))
        XCTAssertTrue(bravo.waitForExistence(timeout: 5))

        let start = alpha.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = bravo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.35, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(row(app, "Alpha").waitForExistence(timeout: 5))

        let a = row(app, "Alpha").frame.minY
        let b = row(app, "Bravo").frame.minY
        let c = row(app, "Charlie").frame.minY
        XCTAssertLessThan(b, a, "Bravo now above Alpha")
        XCTAssertLessThan(a, c, "Alpha still above Charlie → order Bravo, Alpha, Charlie")
    }

    /// Fine same-container reorder UP: drag Charlie above Alpha → [Charlie, Alpha, Bravo].
    func testFineReorderUp() throws {
        let app = launchedApp()
        let alpha = row(app, "Alpha")
        let charlie = row(app, "Charlie")
        XCTAssertTrue(alpha.waitForExistence(timeout: 20))
        XCTAssertTrue(charlie.waitForExistence(timeout: 5))

        let start = charlie.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = alpha.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        start.press(forDuration: 0.35, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(row(app, "Charlie").waitForExistence(timeout: 5))

        let a = row(app, "Alpha").frame.minY
        let b = row(app, "Bravo").frame.minY
        let c = row(app, "Charlie").frame.minY
        XCTAssertLessThan(c, a, "Charlie moved above Alpha")
        XCTAssertLessThan(a, b, "→ order Charlie, Alpha, Bravo")
    }

    /// Reorder WITHIN a custom list: drag ListA below ListB → [ListB, ListA, ListC].
    func testReorderWithinCustomList() throws {
        let app = launchedApp()
        let a = row(app, "ListA")
        let b = row(app, "ListB")
        XCTAssertTrue(a.waitForExistence(timeout: 20), "ListA should exist in the custom list")
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertLessThan(a.frame.minY, b.frame.minY, "precondition: ListA above ListB")

        let start = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.35, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(row(app, "ListA").waitForExistence(timeout: 5))

        let ya = row(app, "ListA").frame.minY
        let yb = row(app, "ListB").frame.minY
        let yc = row(app, "ListC").frame.minY
        XCTAssertLessThan(yb, ya, "ListB now above ListA")
        XCTAssertLessThan(ya, yc, "→ order ListB, ListA, ListC (reorder within the list worked)")
    }

    /// The editor's Title field must grow to reveal wrapped lines — a long title
    /// should not be clipped to a single line (the reported bug).
    func testEditorTitleGrowsWhenWrapping() throws {
        let app = launchedApp()
        let alpha = app.staticTexts["Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 20))
        alpha.click()
        let field = app.descendants(matching: .any).matching(identifier: "editor-title").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "editor Title field should exist")
        field.click()
        let oneLineHeight = field.frame.height
        field.typeKey("a", modifierFlags: .command) // select the seeded "Alpha"
        field.typeText("Pradeep / Bhuvanesh / Anirban / TechTalk Recording session agenda notes for the weekly team sync")
        Thread.sleep(forTimeInterval: 0.6) // let the field reflow
        XCTAssertGreaterThan(field.frame.height, oneLineHeight + 12,
                             "Title field should grow to reveal the wrapped line, not clip it")
    }
}
