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
            if (row(app, title, on: dayKey) != nil) == present { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
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

    private func open(_ app: XCUIApplication, _ title: String, on dayKey: String) {
        XCTAssertTrue(waitForRow(app, title, on: dayKey), "\(title) should be shown on \(dayKey)")
        row(app, title, on: dayKey)!.click()
        XCTAssertTrue(app.buttons["editor-done"].waitForExistence(timeout: 5), "the editor should open")
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
        XCTAssertTrue(waitForRow(app, title, on: dayKey))
        let button = app.sheets.buttons[choice].firstMatch
        for _ in 0..<2 where !button.exists {
            row(app, title, on: dayKey)!.rightClick()
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
        done(app)
        XCTAssertTrue(rowGlyphs(app, "Standup", on: mon).contains("0/1"), "badge on the edited occurrence")
        XCTAssertFalse(rowGlyphs(app, "Standup", on: tue).contains("0/1"), "no badge on a sibling")
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

    /// 6. Deleting the first occurrence leaves the next one's work alone.
    func testDeletingOneOccurrenceKeepsTheNextOnesNotes() throws {
        let app = launch()
        let mon = key(monday(weeks: 1)), tue = key(day(1, from: monday(weeks: 1)))
        go(app, weeks: 1)
        open(app, "Standup", on: tue)
        typeNotes(app, "keep me")
        done(app)
        delete(app, "Standup", on: mon, choice: "Delete This Occurrence")
        XCTAssertTrue(waitForRow(app, "Standup", on: mon, present: false), "only that occurrence is gone")
        XCTAssertTrue(rowGlyphs(app, "Standup", on: tue).contains("Has notes"), "the next occurrence keeps its notes")
    }

    /// 7. Cancel changes nothing; Entire Series removes every occurrence.
    func testDeleteChoices() throws {
        let app = launch()
        let todayKey = key(Date())
        row(app, "Meeting", on: todayKey)!.rightClick()
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
}
