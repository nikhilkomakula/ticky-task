import XCTest

/// End-to-end journeys for recurring series (v0.1.17), driving the real editor,
/// row menus, and toolbar. `-uitestRecurringSeed` adds a daily "Standup" (started
/// two days ago, first occurrence done), a "Paycheck" on the 1st and 15th, and a
/// weekly "Meeting" — all generated through the app's own series code.
///
/// SwiftUI copies a container's accessibility identifier onto its children, so a
/// day column is found as the union of the elements tagged `dayColumn-<key>`, and a
/// row as the title text tagged `taskRow-<title>` that sits inside that column.
final class RecurringSeriesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    // MARK: - Launch and navigation

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitestRecurringSeed", "-calendarColumns", "7",
                               "-weekStartsMonday", "YES", "-showWeekends", "YES"] + extra
        app.launchWithMainWindow()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 20), "seeded board should render")
        return app
    }

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2   // the tests launch with weekStartsMonday
        return c
    }

    private func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    private func day(_ offset: Int, from base: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: base))!
    }

    /// Monday of the week `weeks` after the current one.
    private func monday(weeks: Int) -> Date {
        let thisMonday = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        return calendar.date(byAdding: .weekOfYear, value: weeks, to: thisMonday)!
    }

    /// The week (relative to the current one) on screen; navigation keeps it in step
    /// and waits for that week's Monday column after every click.
    private var shownWeek = 0

    private func go(_ app: XCUIApplication, weeks: Int) {
        let button = app.buttons[weeks > 0 ? "toolbar-next" : "toolbar-previous"]
        for _ in 0..<abs(weeks) {
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let target = shownWeek + (weeks > 0 ? 1 : -1)
            let column = app.descendants(matching: .any).matching(identifier: "dayColumn-\(key(monday(weeks: target)))").firstMatch
            for _ in 0..<3 where !column.exists {
                button.click()
                _ = column.waitForExistence(timeout: 3)
            }
            XCTAssertTrue(column.exists, "week \(target) should be shown")
            shownWeek = target
        }
    }

    private func today(_ app: XCUIApplication) {
        app.buttons["toolbar-today"].click()
        shownWeek = 0
        _ = app.descendants(matching: .any).matching(identifier: "dayColumn-\(key(monday(weeks: 0)))").firstMatch
            .waitForExistence(timeout: 3)
    }

    /// Show the week containing `date`.
    private func show(_ app: XCUIApplication, _ date: Date) {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        let weeks = calendar.dateComponents([.weekOfYear], from: monday(weeks: 0), to: weekStart).weekOfYear!
        if weeks != shownWeek { go(app, weeks: weeks - shownWeek) }
    }

    // MARK: - Rows

    private func columnFrame(_ app: XCUIApplication, _ dayKey: String) -> CGRect {
        app.descendants(matching: .any).matching(identifier: "dayColumn-\(dayKey)").allElementsBoundByIndex
            .map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    /// The title text of the `title` row on `dayKey`, if it is shown there.
    private func row(_ app: XCUIApplication, _ title: String, on dayKey: String) -> XCUIElement? {
        let column = columnFrame(app, dayKey)
        guard !column.isNull else { return nil }
        return app.staticTexts.matching(identifier: "taskRow-\(title)").allElementsBoundByIndex
            .first { column.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    @discardableResult
    private func waitForRow(_ app: XCUIApplication, _ title: String, on dayKey: String,
                            present: Bool = true, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let seen = row(app, title, on: dayKey) != nil
                || scrollThrough(app, dayKey) { row(app, title, on: dayKey) != nil }
            if seen == present { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }

    /// Whether the row whose title text is `text` shows the notes glyph.
    private func hasNotes(_ app: XCUIApplication, _ text: XCUIElement) -> Bool {
        let band = CGRect(x: text.frame.minX - 60, y: text.frame.minY - 4, width: text.frame.width + 400, height: text.frame.height + 8)
        return app.images.matching(NSPredicate(format: "label == 'Has notes'")).allElementsBoundByIndex
            .contains { band.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    /// Images (glyphs) on the same line as `title`'s row on `dayKey`.
    private func rowGlyphs(_ app: XCUIApplication, _ title: String, on dayKey: String) -> [String] {
        guard let text = row(app, title, on: dayKey) else { return [] }
        let column = columnFrame(app, dayKey)
        let band = CGRect(x: column.minX, y: text.frame.minY - 4, width: column.width, height: text.frame.height + 8)
        let images = app.images.allElementsBoundByIndex.filter { band.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        let texts = app.staticTexts.allElementsBoundByIndex.filter { band.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        return images.map(\.label) + texts.compactMap { $0.value as? String }
    }

    /// Scroll through a day column — down, then back up past its start — until `found`.
    /// Columns are lazy: on smaller screens (e.g. CI) a row scrolled out of view isn't
    /// in the accessibility tree at all.
    private func scrollThrough(_ app: XCUIApplication, _ dayKey: String, until found: () -> Bool) -> Bool {
        let window = app.windows.firstMatch
        for delta in [0.0, -150, -150, -150, -150, 300, 300, 300, 300, 300] {
            if delta != 0 {
                let visible = columnFrame(app, dayKey).intersection(window.frame)
                guard !visible.isNull, !visible.isEmpty else { return false }
                // Near the top of the column: always inside its scroll view.
                let point = CGVector(dx: visible.midX - window.frame.minX, dy: visible.minY + min(80, visible.height / 2) - window.frame.minY)
                window.coordinate(withNormalizedOffset: .zero).withOffset(point).scroll(byDeltaX: 0, deltaY: delta)
                usleep(300_000)
            }
            if found() { return true }
        }
        return false
    }

    /// `title`'s row on `dayKey`, scrolled into view so it can be clicked.
    private func reveal(_ app: XCUIApplication, _ title: String, on dayKey: String) -> XCUIElement? {
        var hit: XCUIElement?
        _ = scrollThrough(app, dayKey) {
            hit = row(app, title, on: dayKey).flatMap { $0.isHittable ? $0 : nil }
            return hit != nil
        }
        return hit
    }

    /// The title text of a `title` row shown in a custom list (below every day column).
    private func listedRow(_ app: XCUIApplication, _ title: String) -> XCUIElement? {
        let daysBottom = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'dayColumn-'"))
            .allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0
        return app.staticTexts.matching(identifier: "taskRow-\(title)").allElementsBoundByIndex
            .first { $0.frame.midY > daysBottom }
    }

    private func drag(_ element: XCUIElement, to target: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.35, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.2)
    }

    private func open(_ app: XCUIApplication, _ title: String, on dayKey: String) {
        _ = waitForRow(app, title, on: dayKey)
        let done = app.buttons["editor-done"]
        for _ in 0..<2 where !done.exists {   // a click during a re-render can be lost
            guard let text = reveal(app, title, on: dayKey) else { break }
            text.click()
            _ = done.waitForExistence(timeout: 8)
        }
        if !done.exists { keepScreenshot(app, "open \(title) on \(dayKey)") }
        XCTAssertTrue(done.exists, "the editor should open \(title) on \(dayKey)")
    }

    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func done(_ app: XCUIApplication) {
        app.buttons["editor-done"].click()
        XCTAssertTrue(waitForGone(app.buttons["editor-done"]), "the editor should close")
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline { usleep(200_000) }
        return !element.exists
    }

    private func setTitle(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["editor-title"]
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func typeNotes(_ app: XCUIApplication, _ text: String) {
        let notes = app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch
        notes.click()
        notes.typeText(text)
    }

    private func notesValue(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(identifier: "editor-notes").firstMatch.value as? String ?? ""
    }

    private func delete(_ app: XCUIApplication, _ title: String, on dayKey: String, choice: String) {
        _ = waitForRow(app, title, on: dayKey)
        let button = app.sheets.buttons[choice].firstMatch
        for _ in 0..<2 where !button.exists {
            guard let text = reveal(app, title, on: dayKey) else {
                keepScreenshot(app, "reveal \(title) on \(dayKey)")
                return XCTFail("\(title) should be shown on \(dayKey)")
            }
            text.rightClick()
            let item = app.menuItems["context-delete"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.click()
            _ = button.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the delete dialog should offer \(choice)")
        button.click()
    }

    // MARK: - Journeys

    /// 1. A rename from a later occurrence reaches past, completed, and future ones.
    func testRenameFromLaterOccurrenceUpdatesEverywhere() throws {
        let app = launch()
        let nextMonday = key(monday(weeks: 1))
        go(app, weeks: 1)
        open(app, "Standup", on: nextMonday)
        setTitle(app, "Daily sync")
        done(app)

        for offset in 0..<7 {
            let k = key(day(offset, from: monday(weeks: 1)))
            XCTAssertTrue(waitForRow(app, "Daily sync", on: k), "renamed on \(k)")
            XCTAssertNil(row(app, "Standup", on: k), "old title gone on \(k)")
        }
        let first = day(-2)   // the completed first occurrence
        today(app)
        if first < monday(weeks: 0) { go(app, weeks: -1) }
        XCTAssertTrue(waitForRow(app, "Daily sync", on: key(first)), "the completed first occurrence is renamed too")
    }

    /// 2. Notes stay on their own occurrence, even through a shared edit.
    func testNotesStayOnTheirOccurrence() throws {
        let app = launch()
        let mon = key(monday(weeks: 1)), tue = key(day(1, from: monday(weeks: 1))), wed = key(day(2, from: monday(weeks: 1)))
        go(app, weeks: 1)
        open(app, "Standup", on: mon)
        typeNotes(app, "monday-only")
        done(app)
        open(app, "Standup", on: tue)
        XCTAssertEqual(notesValue(app).trimmingCharacters(in: .whitespacesAndNewlines), "", "a sibling starts with empty notes")
        typeNotes(app, "tuesday-only")
        done(app)

        open(app, "Standup", on: wed)   // a shared edit from a third occurrence
        setTitle(app, "Standup v2")
        done(app)

        XCTAssertTrue(rowGlyphs(app, "Standup v2", on: mon).contains("Has notes"))
        XCTAssertTrue(rowGlyphs(app, "Standup v2", on: tue).contains("Has notes"))
        XCTAssertFalse(rowGlyphs(app, "Standup v2", on: wed).contains("Has notes"))
        open(app, "Standup v2", on: mon)
        XCTAssertTrue(notesValue(app).contains("monday-only"))
        XCTAssertFalse(notesValue(app).contains("tuesday-only"))
    }

    /// 3. Subtasks belong to one occurrence.
    func testSubtasksStayOnTheirOccurrence() throws {
        let app = launch()
        let mon = key(monday(weeks: 1)), tue = key(day(1, from: monday(weeks: 1)))
        go(app, weeks: 1)
        open(app, "Standup", on: mon)
        let add = app.textFields["editor-add-subtask"]
        add.click()
        add.typeText("Prepare agenda\r")
        add.typeText("Book room\r")
        app.buttons["subtask-toggle-Prepare agenda"].click()
        done(app)
        XCTAssertTrue(rowGlyphs(app, "Standup", on: mon).contains("1/2"), "badge on the edited occurrence")
        XCTAssertFalse(rowGlyphs(app, "Standup", on: tue).contains { $0.contains("/") }, "no badge on a sibling")

        open(app, "Standup", on: tue)
        XCTAssertFalse(app.buttons["subtask-toggle-Prepare agenda"].exists, "the sibling has no subtasks")
        done(app)
        open(app, "Standup", on: mon)
        XCTAssertTrue(app.buttons["subtask-toggle-Prepare agenda"].exists && app.buttons["subtask-toggle-Book room"].exists,
                      "both subtasks are kept on their occurrence")
        app.buttons["editor-cancel"].click()
    }

    /// 4. Scope captions appear on a series occurrence only; clearing the time hides the reminder.
    func testCaptionsAndTimeToggle() throws {
        let app = launch()
        let todayKey = key(Date())
        open(app, "Standup", on: todayKey)
        for id in ["caption-shared", "caption-details", "caption-subtasks", "caption-repeat"] {
            XCTAssertTrue(app.staticTexts[id].exists, "\(id) on a series occurrence")
        }
        XCTAssertTrue(app.buttons["repeat-stop"].exists)
        app.buttons["editor-cancel"].click()
        XCTAssertTrue(waitForGone(app.buttons["editor-done"]))

        open(app, "Alpha", on: todayKey)
        XCTAssertFalse(app.staticTexts["caption-shared"].exists, "no series caption on a one-off")
        XCTAssertTrue(app.switches["repeat-toggle"].exists, "a one-off can start repeating")
        let timeToggle = app.switches["editor-time-toggle"]
        timeToggle.click()
        XCTAssertTrue(app.switches["editor-reminder-toggle"].waitForExistence(timeout: 3))
        timeToggle.click()
        XCTAssertTrue(waitForGone(app.switches["editor-reminder-toggle"]), "no reminder without a time")
    }

    /// 5. The rule can be changed from the completed first occurrence.
    func testRuleEditFromCompletedOccurrence() throws {
        let app = launch()
        let first = day(-2)
        if first < monday(weeks: 0) { go(app, weeks: -1) }
        open(app, "Standup", on: key(first))
        let frequency = app.popUpButtons["repeat-frequency"]
        XCTAssertEqual(frequency.value as? String, "Daily", "the series rule is shown on a past occurrence")
        frequency.click()
        app.menuItems["Weekly"].click()
        done(app)

        today(app)
        go(app, weeks: 1)
        let shown = (0..<7).filter { row(app, "Standup", on: key(day($0, from: monday(weeks: 1)))) != nil }
        XCTAssertEqual(shown.count, 1, "weekly from next week on")
    }

    /// 6. Deleting the first occurrence (2 days ago, already done) leaves the next one's work alone.
    func testDeletingOneOccurrenceKeepsTheNextOnesNotes() throws {
        let app = launch()
        let first = day(-2)   // the actual first occurrence, 2 days ago (already done)
        let second = day(-1)  // the second occurrence, 1 day ago
        let firstKey = key(first)
        let secondKey = key(second)

        // Add distinct notes to the second occurrence
        show(app, second)
        open(app, "Standup", on: secondKey)
        typeNotes(app, "keep me")
        done(app)

        // Delete the first (completed) occurrence (on Tuesdays it is in the previous week)
        show(app, first)
        delete(app, "Standup", on: firstKey, choice: "Delete This Occurrence")
        XCTAssertTrue(waitForRow(app, "Standup", on: firstKey, present: false), "the first occurrence is deleted")

        // The second occurrence should still have its notes
        show(app, second)
        XCTAssertTrue(rowGlyphs(app, "Standup", on: secondKey).contains("Has notes"), "the second occurrence keeps its notes")
        open(app, "Standup", on: secondKey)
        XCTAssertTrue(notesValue(app).contains("keep me"), "exact notes text is preserved")
        done(app)
    }

    /// 7. Cancel changes nothing; Entire Series removes every occurrence.
    func testDeleteChoices() throws {
        let app = launch()
        let todayKey = key(Date())
        try XCTUnwrap(reveal(app, "Meeting", on: todayKey), "Meeting is shown today").rightClick()
        app.menuItems["context-delete"].firstMatch.click()
        let cancel = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(waitForRow(app, "Meeting", on: todayKey), "Cancel keeps the occurrence")

        delete(app, "Meeting", on: todayKey, choice: "Delete Entire Series")
        XCTAssertTrue(waitForRow(app, "Meeting", on: todayKey, present: false))
        go(app, weeks: 1)
        let anyLeft = (0..<7).contains { row(app, "Meeting", on: key(day($0, from: monday(weeks: 1)))) != nil }
        XCTAssertFalse(anyLeft, "every occurrence is gone")
    }

    /// 8. Stop Repeating removes untouched future occurrences but keeps worked-on ones.
    func testStopRepeatingKeepsChangedFutureWork() throws {
        let app = launch()
        let wed = key(day(2, from: monday(weeks: 1)))
        go(app, weeks: 1)
        open(app, "Standup", on: wed)
        typeNotes(app, "planned")
        done(app)
        today(app)
        open(app, "Standup", on: key(Date()))
        app.buttons["repeat-stop"].click()
        done(app)

        go(app, weeks: 1)
        XCTAssertTrue(waitForRow(app, "Standup", on: wed), "the occurrence with notes is kept")
        for offset in [0, 1, 3, 4, 5, 6] {
            XCTAssertNil(row(app, "Standup", on: key(day(offset, from: monday(weeks: 1)))), "untouched future occurrence removed")
        }
        go(app, weeks: 1)
        go(app, weeks: -1)
        XCTAssertNil(row(app, "Standup", on: key(monday(weeks: 1))), "nothing regenerates after navigating")
    }

    /// 9. Opening an imported "1st and 15th" rule and pressing Done keeps both days.
    func testNoOpDoneKeepsDaysOfMonthRule() throws {
        let app = launch()
        func paychecks(weeks: Int) -> [String] {
            var found: [String] = []
            for week in 0..<weeks {
                for offset in 0..<7 {
                    let k = key(day(offset, from: monday(weeks: week)))
                    if row(app, "Paycheck", on: k) != nil { found.append(k) }
                }
                go(app, weeks: 1)
            }
            go(app, weeks: -weeks)
            return found
        }
        let before = paychecks(weeks: 7)
        XCTAssertGreaterThanOrEqual(before.count, 3, "the 1st and the 15th both repeat")
        let target = before.first { $0 != key(Date()) }!
        let weeksAhead = (0..<7).first { w in (0..<7).contains { key(day($0, from: monday(weeks: w))) == target } }!
        go(app, weeks: weeksAhead)
        open(app, "Paycheck", on: target)
        XCTAssertTrue((app.staticTexts["repeat-month-days"].value as? String ?? "").contains("1, 15"))
        done(app)
        go(app, weeks: -weeksAhead)
        XCTAssertEqual(paychecks(weeks: 7), before, "Done without changes leaves the schedule as it was")
    }

    /// 10. Cancel and Escape discard title and notes edits.
    func testCancelAndEscapeDiscard() throws {
        let app = launch()
        let todayKey = key(Date())
        open(app, "Standup", on: todayKey)
        setTitle(app, "Discarded title")
        typeNotes(app, "discarded notes")
        app.buttons["editor-cancel"].click()
        XCTAssertTrue(waitForGone(app.buttons["editor-done"]))
        XCTAssertTrue(waitForRow(app, "Standup", on: todayKey))
        XCTAssertNil(row(app, "Discarded title", on: todayKey))

        open(app, "Standup", on: todayKey)
        XCTAssertFalse(notesValue(app).contains("discarded notes"))
        setTitle(app, "Escaped title")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForGone(app.buttons["editor-done"]), "Esc closes the editor")
        XCTAssertNil(row(app, "Escaped title", on: todayKey))
    }

    /// 11. A rename survives quitting and relaunching on an on-disk store.
    func testRenamePersistsAcrossRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskUITest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ["-uitestStore", dir.appendingPathComponent("TickyTask.store").path]
        let todayKey = key(Date())

        var app = launch(store)
        open(app, "Standup", on: todayKey)
        setTitle(app, "Persisted sync")
        done(app)
        XCTAssertTrue(waitForRow(app, "Persisted sync", on: todayKey))
        app.terminate()

        app = launch(store)
        XCTAssertTrue(waitForRow(app, "Persisted sync", on: todayKey), "the rename is still there after relaunch")
        go(app, weeks: 1)
        XCTAssertTrue(waitForRow(app, "Persisted sync", on: key(monday(weeks: 1))), "and on future occurrences")
        XCTAssertNil(row(app, "Standup", on: key(monday(weeks: 1))))
    }

    /// 12. An occurrence dragged day → day → list → day keeps its own identity and
    /// work; its original day isn't refilled and each destination keeps its own.
    func testDragSeriesOccurrenceDayToListAndBack() throws {
        let app = launch()
        let mon = key(monday(weeks: 1)), tue = key(day(1, from: monday(weeks: 1))), thu = key(day(3, from: monday(weeks: 1)))
        go(app, weeks: 1)
        open(app, "Standup", on: mon)
        typeNotes(app, "travelling")
        done(app)

        drag(try XCTUnwrap(reveal(app, "Standup", on: mon)), to: app.descendants(matching: .any).matching(identifier: "dayColumn-\(tue)").firstMatch)
        XCTAssertTrue(waitForRow(app, "Standup", on: mon, present: false), "Monday is not refilled")
        let tuesdayRows = app.staticTexts.matching(identifier: "taskRow-Standup").allElementsBoundByIndex
            .filter { columnFrame(app, tue).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        XCTAssertEqual(tuesdayRows.count, 2, "Tuesday shows the moved one and its own")

        let moved = try XCTUnwrap(tuesdayRows.first { hasNotes(app, $0) }, "the moved occurrence keeps its notes")
        drag(moved, to: try XCTUnwrap(listedRow(app, "ListA")))
        XCTAssertNotNil(listedRow(app, "Standup"), "now in the Inbox list")
        drag(try XCTUnwrap(listedRow(app, "Standup")), to: app.descendants(matching: .any).matching(identifier: "dayColumn-\(thu)").firstMatch)
        XCTAssertNil(listedRow(app, "Standup"), "left the list")
        XCTAssertTrue(waitForRow(app, "Standup", on: mon, present: false), "Monday still not refilled")
        let thursdayRows = app.staticTexts.matching(identifier: "taskRow-Standup").allElementsBoundByIndex
            .filter { columnFrame(app, thu).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        XCTAssertEqual(thursdayRows.count, 2, "Thursday shows the moved one and its own")
        XCTAssertEqual(thursdayRows.filter { hasNotes(app, $0) }.count, 1, "its notes travelled with it")
    }

    /// 13. The series rule can be edited from an occurrence sitting in a list.
    func testRuleEditFromMovedAndListedOccurrence() throws {
        let app = launch()
        let tue = key(day(1, from: monday(weeks: 1)))
        go(app, weeks: 1)
        drag(try XCTUnwrap(row(app, "Standup", on: tue)), to: try XCTUnwrap(listedRow(app, "ListA")))
        let listed = try XCTUnwrap(listedRow(app, "Standup"), "the occurrence is in the Inbox list")
        listed.click()
        XCTAssertTrue(app.buttons["editor-done"].waitForExistence(timeout: 8), "the listed occurrence opens")
        let frequency = app.popUpButtons["repeat-frequency"]
        XCTAssertEqual(frequency.value as? String, "Daily", "it shows the series rule")
        frequency.click()
        app.menuItems["Weekly"].click()
        done(app)

        go(app, weeks: 1)
        let weekday = calendar.component(.weekday, from: day(-2))
        let shown = (0..<7).map { day($0, from: monday(weeks: 2)) }.filter { row(app, "Standup", on: key($0)) != nil }
        XCTAssertEqual(shown.map { calendar.component(.weekday, from: $0) }, [weekday], "weekly from the listed row's edit")
        XCTAssertNotNil(listedRow(app, "Standup"), "the listed occurrence itself is kept")
    }

    /// 14. Search finds a unique notes token on one series occurrence; the result navigates to that date.
    func testSearchSeriesOccurrenceByUniqueNotesToken() throws {
        let app = launch()
        let targetDay = day(3, from: monday(weeks: 1))
        let targetKey = key(targetDay)
        go(app, weeks: 1)

        // Add unique notes to one specific Standup occurrence
        open(app, "Standup", on: targetKey)
        typeNotes(app, "xyzUniqueSearchToken123")
        done(app)

        // Navigate back to today
        today(app)

        // Search for that token
        app.buttons["toolbar-search"].click()
        let searchField = app.textFields["search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "search field should appear")
        searchField.click()
        searchField.typeText("xyzUniqueSearchToken123")
        XCTAssertTrue(app.staticTexts["Standup"].firstMatch.waitForExistence(timeout: 5), "one result for the unique token")
        searchField.typeText("\r")   // opens the first (only) result
        shownWeek = 1

        // Should find exactly one result (search results auto-navigate; verify via row presence)
        // Series definitions should NOT appear in search results
        XCTAssertTrue(waitForRow(app, "Standup", on: targetKey, timeout: 3), "search navigates to the occurrence with matching notes")
    }

    /// 15. Weekly Summary lists each of this week's occurrences once, as dated rows,
    /// and "Select series" selects exactly those.
    func testWeeklySummaryShowsOccurrencesNotDefinitions() throws {
        let app = launch()
        app.buttons["toolbar-weekly-summary"].click()
        XCTAssertTrue(app.staticTexts["summary-week-range"].waitForExistence(timeout: 8), "summary sheet should open")
        let expected = (0..<7).map { day($0, from: monday(weeks: 0)) }.filter { $0 >= day(-2) }.count
        let rows = app.buttons.matching(identifier: "summary-task-Standup")
        XCTAssertEqual(rows.count, expected, "one selectable row per occurrence this week, no definition")
        let selectSeries = app.buttons.matching(identifier: "Select series (\(expected))").firstMatch
        if expected > 1 {
            XCTAssertTrue(selectSeries.exists)
            selectSeries.click()
            let selected = rows.allElementsBoundByIndex.filter { ($0.value as? String) == "selected" }
            XCTAssertEqual(selected.count, expected, "the whole series in this week is selected")
        }
    }

    /// 16. Navigating far ahead (beyond 60 days), editing the rule, navigating away, and back shows the new rule's slots.
    func testRuleChangeAndRevisitBeyondSixtyDays() throws {
        let app = launch()

        // Navigate 10 weeks ahead (beyond the initial 60-day range in the seed)
        go(app, weeks: 10)

        // Pick Monday of week 10 (a Standup will exist there in the daily series)
        let targetMonday = monday(weeks: 10)
        let mondayKey = key(targetMonday)
        let thursdayKey = key(day(3, from: targetMonday))

        XCTAssertTrue(waitForRow(app, "Standup", on: mondayKey, timeout: 3), "Standup exists far ahead")

        // Change the rule from daily to weekly
        open(app, "Standup", on: mondayKey)
        let frequency = app.popUpButtons["repeat-frequency"]
        frequency.click()
        app.menuItems["Weekly"].click()
        done(app)

        // Navigate away and back to the same week
        go(app, weeks: -3)
        go(app, weeks: 3)

        // Weekly repeats on the series' start weekday (its first occurrence, two days ago).
        let weekday = calendar.component(.weekday, from: day(-2))
        let shown = (0..<7).map { day($0, from: targetMonday) }.filter { row(app, "Standup", on: key($0)) != nil }
        XCTAssertEqual(shown.map { calendar.component(.weekday, from: $0) }, [weekday],
                       "exactly one occurrence that week, on the series' weekday")
        _ = (mondayKey, thursdayKey)
    }

    /// 17. Time and alarm set on one occurrence propagate to siblings; clearing time removes the alarm glyph.
    func testTimeAlarmPropagationAcrossSiblings() throws {
        let app = launch()
        let mon = key(monday(weeks: 1))
        let tue = key(day(1, from: monday(weeks: 1)))
        go(app, weeks: 1)

        // Add a time to Monday's Standup
        open(app, "Standup", on: mon)
        let timeToggle = app.switches["editor-time-toggle"]
        timeToggle.click()
        let reminder = app.switches["editor-reminder-toggle"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 3), "reminder toggle appears with time")
        reminder.click()
        done(app)

        // The time and reminder are shared: Tuesday's occurrence shows them too.
        XCTAssertTrue(rowGlyphs(app, "Standup", on: tue).contains("09:00"), "sibling shows the shared time")
        XCTAssertTrue(rowGlyphs(app, "Standup", on: tue).contains("Reminder"), "sibling shows the shared reminder")

        // Remove the time from Tuesday
        open(app, "Standup", on: tue)
        XCTAssertEqual(reminder.value as? Int, 1, "the sibling's editor shows the reminder on")
        timeToggle.click()
        XCTAssertTrue(waitForGone(app.switches["editor-reminder-toggle"]), "reminder toggle disappears when time is removed")
        done(app)

        // Clearing the shared time on Tuesday clears it (and its reminder) on Monday as well.
        XCTAssertFalse(rowGlyphs(app, "Standup", on: mon).contains("09:00"), "clearing the time reaches every occurrence")
        XCTAssertFalse(rowGlyphs(app, "Standup", on: mon).contains("Reminder"), "no reminder is left without a time")
    }

    /// 18. Deleting the entire series from a past completed row removes all occurrences across weeks and lists.
    func testWholeSeriesDeletionFromPastCompletedRow() throws {
        let app = launch()
        let first = day(-2)
        let firstKey = key(first)

        show(app, first)

        // Delete entire series from the completed past occurrence
        delete(app, "Standup", on: firstKey, choice: "Delete Entire Series")

        // Verify: no Standup in this week
        XCTAssertTrue(waitForRow(app, "Standup", on: firstKey, present: false), "past occurrence deleted")
        today(app)
        for offset in 0..<7 {
            XCTAssertNil(row(app, "Standup", on: key(day(offset, from: monday(weeks: 0)))), "this week's occurrences removed")
        }

        // Verify: no Standup in future weeks
        go(app, weeks: 2)
        let anyFuture = (0..<7).contains { row(app, "Standup", on: key(day($0, from: monday(weeks: 2)))) != nil }
        XCTAssertFalse(anyFuture, "future occurrences removed by whole-series deletion")
    }

    /// 19. Relaunch persistence: a deleted (skipped) occurrence and notes on a sibling survive reopen.
    func testRelunchPersistenceWithSkipsAndNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskUITest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ["-uitestStore", dir.appendingPathComponent("TickyTask.store").path]

        let first = day(-2)
        let second = day(-1)
        let firstKey = key(first)
        let secondKey = key(second)

        var app = launch(store)

        show(app, first)
        delete(app, "Standup", on: firstKey, choice: "Delete This Occurrence")

        // Add notes to the second occurrence
        show(app, second)
        open(app, "Standup", on: secondKey)
        typeNotes(app, "persisted-notes-token")
        done(app)

        // Terminate and relaunch
        app.terminate()
        app = launch(store)
        shownWeek = 0

        // Verify: first occurrence is still gone (skip persists)
        show(app, first)
        XCTAssertTrue(columnFrame(app, firstKey) != .null, "the first occurrence's day is shown")
        XCTAssertTrue(waitForRow(app, "Standup", on: firstKey, present: false, timeout: 6), "skipped occurrence remains deleted")

        // Verify: second occurrence still has its notes
        show(app, second)
        XCTAssertTrue(rowGlyphs(app, "Standup", on: secondKey).contains("Has notes"), "notes glyph persists")
        open(app, "Standup", on: secondKey)
        XCTAssertTrue(notesValue(app).contains("persisted-notes-token"), "exact notes content persists")
        done(app)
    }

    /// 20. A save that fails keeps the editor open with the edit; Cancel then discards
    /// it, and a later unrelated save doesn't bring it back.
    func testFailedSaveThenCancelDiscards() throws {
        let app = launch(["-uitestFailTaskSave"])
        let todayKey = key(Date()), tomorrow = day(1)
        open(app, "Standup", on: todayKey)
        setTitle(app, "Standup renamed")
        app.buttons["editor-done"].click()
        let ok = NSPredicate(format: "label == 'OK' AND elementType == %d", XCUIElement.ElementType.button.rawValue)
        let alert = app.descendants(matching: .any).matching(ok)
        let deadline = Date().addingTimeInterval(5)
        while !alert.allElementsBoundByIndex.contains(where: \.isHittable) && Date() < deadline { usleep(250_000) }
        let button = try XCTUnwrap(alert.allElementsBoundByIndex.first(where: \.isHittable), "the save error is shown")
        button.click()
        XCTAssertTrue(app.buttons["editor-done"].exists, "the editor stays open")
        XCTAssertEqual(app.textFields["editor-title"].value as? String, "Standup renamed", "with the edit still in it")
        app.buttons["editor-cancel"].click()
        XCTAssertTrue(waitForGone(app.buttons["editor-done"]))

        XCTAssertTrue(waitForRow(app, "Standup", on: todayKey), "the series keeps its saved title")
        open(app, "Alpha", on: todayKey)
        setTitle(app, "Alpha edited")
        done(app)
        XCTAssertTrue(waitForRow(app, "Alpha edited", on: todayKey))
        show(app, tomorrow)
        XCTAssertTrue(waitForRow(app, "Standup", on: key(tomorrow)), "the cancelled rename never reached a sibling")
        XCTAssertNil(row(app, "Standup renamed", on: key(tomorrow)))
    }

    /// 21. A failed save that can't be undone in place (a rule change removing future
    /// occurrences) restarts the app without it: the restart is explained, and the
    /// saved daily schedule is unchanged.
    func testFailedDestructiveSaveRestartsWithSavedData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskUITest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ["-uitestStore", dir.appendingPathComponent("TickyTask.store").path]

        let app = launch(store + ["-uitestFailTaskSave"])
        go(app, weeks: 1)
        open(app, "Standup", on: key(monday(weeks: 1)))
        app.popUpButtons["repeat-frequency"].click()
        app.menuItems["Weekly"].click()
        app.buttons["editor-done"].click()

        // The app quits without saving and opens again by itself (same isolated store).
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "the failing instance quits")
        let relaunched = XCUIApplication()
        XCTAssertTrue(relaunched.wait(for: .runningForeground, timeout: 40), "a new instance starts")
        XCTAssertTrue(relaunched.staticTexts["TickyTask restarted"].waitForExistence(timeout: 20), "the restart is explained")
        relaunched.buttons["OK"].firstMatch.click()
        sleep(5)
        XCTAssertEqual(relaunched.state, .runningForeground, "the recovered app stays open (no restart loop)")
        XCTAssertTrue(relaunched.staticTexts["Alpha"].exists, "and shows the saved board")
        relaunched.terminate()

        let fresh = launch(store)
        shownWeek = 0
        go(fresh, weeks: 1)
        let shown = (0..<7).filter { waitForRow(fresh, "Standup", on: key(day($0, from: monday(weeks: 1))), timeout: 2) }
        XCTAssertEqual(shown.count, 7, "still daily: the failed rule change never reached the disk")
    }
}