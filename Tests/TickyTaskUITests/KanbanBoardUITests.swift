import XCTest

/// The Kanban module end to end (design 01 §3, §5): switching modules, the board grid
/// with its headers, row collapse, the cross-board and roll-off badges, All projects ›
/// People, Attention revealing a card, adding a column, and row headers staying in
/// view while the board scrolls sideways. `-uitestKanbanSeed` adds boards "Platform"
/// (Ravi Kumar; Mia Chen, a contractor ending in 10 days) and "Data" (Mia at 60%).
final class KanbanBoardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitestKanbanSeed", "-calendarColumns", "7", "-weekStartsMonday", "YES",
                               "-showWeekends", "YES"] + extra
        app.launchWithMainWindow()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 20), "the planner opens first")
        app.typeKey("2", modifierFlags: .command)
        return app
    }

    /// The board's view picker is segmented on a wide window and a menu on a narrow one.
    private func selectView(_ app: XCUIApplication, _ name: String) {
        let segment = app.radioButtons[name].firstMatch
        if segment.waitForExistence(timeout: 2) { segment.click(); return }
        let picker = app.descendants(matching: .any)["kanban-view-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the view picker exists")
        picker.click()
        let item = app.menuItems[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) is in the view menu")
        item.click()
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openPlatform(_ app: XCUIApplication) {
        let board = element(app, "kanban-sidebar-Platform")
        XCTAssertTrue(board.waitForExistence(timeout: 10), "the seeded board is in the sidebar")
        board.click()
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the board's columns render")
    }

    func testSwitchModulesAndSeeTheBoard() {
        let app = launch()
        openPlatform(app)
        for id in ["kanban-colhdr-In Progress", "kanban-colhdr-Done", "kanban-rowhdr-Unassigned", "kanban-rowhdr-Ravi Kumar",
                   "kanban-rowhdr-Mia Chen", "kanban-card-Build API", "kanban-card-Triage inbox", "kanban-gauge-Ravi Kumar"] {
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 5), "\(id) should exist")
        }
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), "⌘1 returns to the planner")
        XCTAssertFalse(element(app, "kanban-colhdr-To Do").exists)
    }

    func testCollapseAndExpandARow() {
        let app = launch()
        openPlatform(app)
        XCTAssertTrue(element(app, "kanban-card-Build API").waitForExistence(timeout: 5))
        element(app, "kanban-row-toggle-Ravi Kumar").click()
        XCTAssertTrue(element(app, "kanban-collapsed-Ravi Kumar").waitForExistence(timeout: 5), "a collapsed row shows its counts")
        XCTAssertFalse(element(app, "kanban-card-Build API").exists, "and hides its cards")
        element(app, "kanban-row-toggle-Ravi Kumar").click()
        XCTAssertTrue(element(app, "kanban-card-Build API").waitForExistence(timeout: 5), "expanding shows the cards again")
    }

    func testBadgesAndPeopleRollup() {
        let app = launch()
        openPlatform(app)
        XCTAssertTrue(element(app, "kanban-rolloff-Mia Chen").waitForExistence(timeout: 5), "Mia rolls off within 30 days")
        XCTAssertTrue(element(app, "kanban-crossboard-Mia Chen").exists, "Mia is 110% allocated across boards")
        XCTAssertFalse(element(app, "kanban-crossboard-Ravi Kumar").exists)
        element(app, "kanban-sidebar-all").click()
        XCTAssertTrue(element(app, "kanban-project-card-Data").waitForExistence(timeout: 5))
        app.radioButtons["Resources"].firstMatch.click()
        XCTAssertTrue(element(app, "kanban-overallocated-Mia Chen").waitForExistence(timeout: 5), "People flags the over-allocation")
    }

    func testAttentionRevealsTheCard() {
        let app = launch()
        element(app, "kanban-sidebar-attention").click()
        let item = element(app, "kanban-attention-Build API")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "an overdue, blocked card needs attention")
        item.click()
        XCTAssertTrue(element(app, "kanban-card-Build API").waitForExistence(timeout: 5), "the board opens on the card")
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").exists)
    }

    func testAddAColumn() {
        let app = launch()
        openPlatform(app)
        element(app, "kanban-add-column").click()
        let field = element(app, "kanban-prompt-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("QA")
        element(app, "kanban-prompt-ok").click()
        XCTAssertTrue(element(app, "kanban-colhdr-QA").waitForExistence(timeout: 5), "the new column appears")
    }

    func testRowHeadersStayInViewWhenScrollingSideways() {
        let app = launch(["-uitestKanbanWide"])
        openPlatform(app)
        let board = element(app, "kanban-board")
        let header = element(app, "kanban-rowhdr-Ravi Kumar")
        let firstCard = element(app, "kanban-card-Triage inbox")
        XCTAssertTrue(header.waitForExistence(timeout: 5) && firstCard.exists)
        let headerX = header.frame.minX, cardX = firstCard.frame.minX
        func scrolled() -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while firstCard.frame.minX >= cardX - 100, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            return firstCard.frame.minX < cardX - 100
        }
        // The sign of a horizontal scroll delta differs between setups; try both ways.
        board.scroll(byDeltaX: -900, deltaY: 0)
        if !scrolled() { board.scroll(byDeltaX: 900, deltaY: 0) }
        _ = scrolled()
        XCTAssertLessThan(firstCard.frame.minX, cardX - 100, "the board scrolled sideways")
        XCTAssertEqual(header.frame.minX, headerX, accuracy: 4, "the row header stayed put")
        XCTAssertTrue(element(app, "kanban-colhdr-Stage 1").exists)
    }

    // MARK: - Increment 4: editor and quick add

    private func openEditor(_ app: XCUIApplication, _ title: String) {
        let card = element(app, "kanban-card-\(title)")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        // Click near the leading edge, away from the trailing metadata.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.3)).click()
        XCTAssertTrue(element(app, "kanban-editor-title").waitForExistence(timeout: 5), "the editor opens")
    }

    /// Opens one of the editor's optional sections, scrolled into view first.
    private func expandSection(_ app: XCUIApplication, _ id: String) {
        let header = element(app, "kanban-editor-\(id)-disclosure")
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the \(id) section exists")
        scrollIntoEditorView(app, header)
        header.click()
    }

    /// On a short screen (CI's is 768 pt) the editor's lower rows sit below its scroll area,
    /// under the Archive/Delete bar; scroll the form until `target` is inside it.
    private func scrollIntoEditorView(_ app: XCUIApplication, _ target: XCUIElement) {
        let form = app.sheets.scrollViews.firstMatch
        guard form.exists else { return }
        var delta: CGFloat = -120
        for _ in 0..<10 where target.frame.maxY > form.frame.maxY - 4 {
            let before = target.frame.minY
            form.scroll(byDeltaX: 0, deltaY: delta)
            if target.frame.minY > before { delta = -delta }   // that scrolled the wrong way
        }
        XCTAssertTrue(target.frame.maxY <= form.frame.maxY && target.isHittable, "\(target.identifier) is in view")
    }

    func testEditACardsTitleAndAddAStep() {
        let app = launch()
        openPlatform(app)
        openEditor(app, "Triage inbox")
        let title = element(app, "kanban-editor-title")
        title.click()
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Triage support inbox")
        expandSection(app, "subtasks")   // optional sections start collapsed
        let step = element(app, "kanban-editor-add-subtask")
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        scrollIntoEditorView(app, step)
        step.click()
        step.typeText("Read new mail\r")
        element(app, "kanban-editor-done").click()
        XCTAssertTrue(element(app, "kanban-card-Triage support inbox").waitForExistence(timeout: 5), "the card is renamed")
        XCTAssertFalse(element(app, "kanban-editor-title").exists, "the editor closed")
        openEditor(app, "Triage support inbox")
        XCTAssertTrue(element(app, "kanban-step-toggle-Read new mail").waitForExistence(timeout: 5), "the step was saved")
    }

    func testAnInvalidJiraLinkIsRefused() {
        let app = launch()
        openPlatform(app)
        openEditor(app, "Write docs")
        expandSection(app, "links")
        let jira = element(app, "kanban-editor-jira")
        XCTAssertTrue(jira.waitForExistence(timeout: 5))
        scrollIntoEditorView(app, jira)
        jira.click()
        jira.typeText("PLAT-9")
        XCTAssertTrue(element(app, "kanban-editor-jira-error").waitForExistence(timeout: 5), "the field explains the problem")
        element(app, "kanban-editor-done").click()
        XCTAssertTrue(app.sheets.buttons["OK"].firstMatch.waitForExistence(timeout: 5) || app.buttons["OK"].firstMatch.exists,
                      "Done is refused with a message")
    }

    func testNewCardWithCommandN() {
        let app = launch()
        openPlatform(app)
        app.typeKey("n", modifierFlags: .command)
        let titleField = element(app, "kanban-editor-title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeText("Plan sprint")
        element(app, "kanban-editor-done").click()
        XCTAssertTrue(element(app, "kanban-card-Plan sprint").waitForExistence(timeout: 5), "the card lands in the backlog")
    }

    func testQuickAddInACell() {
        let app = launch()
        openPlatform(app)
        let cell = element(app, "kanban-cell-In Progress-Mia Chen")
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.hover()
        element(app, "kanban-add-card-In Progress-Mia Chen").click()
        let titleField = element(app, "kanban-editor-title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeText("Review PR")
        element(app, "kanban-editor-done").click()
        let card = element(app, "kanban-card-Review PR")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(cell.frame.contains(CGPoint(x: card.frame.midX, y: card.frame.midY)), "the card is in that cell")
    }

    // MARK: - Increment 5: drag and drop, keyboard

    /// `startY` 0.3 for cards, as the clicks do: a card's accessibility frame is its whole cell,
    /// so the middle of a one-line card's frame is below the card itself.
    private func drag(_ app: XCUIApplication, _ from: XCUIElement, to target: XCUIElement, at offset: CGVector = CGVector(dx: 0.5, dy: 0.5),
                      startY: CGFloat = 0.3) {
        let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: startY))
        start.press(forDuration: 0.35, thenDragTo: target.coordinate(withNormalizedOffset: offset))
    }

    /// Waits for the board to settle into `condition` (layout after a drop is asynchronous).
    private func eventually(timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return condition()
    }

    private func isInside(_ inner: XCUIElement, _ outer: XCUIElement) -> Bool {
        outer.frame.contains(CGPoint(x: inner.frame.midX, y: inner.frame.midY))
    }

    func testDragACardToAnotherCell() {
        let app = launch()
        openPlatform(app)
        let card = element(app, "kanban-card-Triage inbox")
        let cell = element(app, "kanban-cell-In Progress-Ravi Kumar")
        XCTAssertTrue(card.waitForExistence(timeout: 5) && cell.exists)
        drag(app, card, to: cell, at: CGVector(dx: 0.5, dy: 0.9))
        XCTAssertTrue(eventually { isInside(element(app, "kanban-card-Triage inbox"), element(app, "kanban-cell-In Progress-Ravi Kumar")) },
                      "the card moved to Ravi's In Progress cell")
    }

    func testDragACardOntoARowHeaderReassignsIt() {
        let app = launch()
        openPlatform(app)
        let card = element(app, "kanban-card-Build API")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        drag(app, card, to: element(app, "kanban-rowhdr-Mia Chen"))
        XCTAssertTrue(eventually { isInside(element(app, "kanban-card-Build API"), element(app, "kanban-cell-In Progress-Mia Chen")) },
                      "same column, Mia's row")
    }

    func testDragAColumnHeaderReordersColumns() {
        let app = launch()
        openPlatform(app)
        let done = element(app, "kanban-colhdr-Done"), todo = element(app, "kanban-colhdr-To Do")
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(done.frame.minX, todo.frame.minX)
        drag(app, done, to: todo, at: CGVector(dx: 0.1, dy: 0.5), startY: 0.5)
        XCTAssertTrue(eventually { element(app, "kanban-colhdr-Done").frame.minX < element(app, "kanban-colhdr-To Do").frame.minX }, "Done is first now")
    }

    /// Dragging a column's edge widens it, the width survives a relaunch, and a double-click
    /// puts it back.
    func testResizeAColumnAndItIsRemembered() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TickyTaskUITest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ["-uitestStore", dir.appendingPathComponent("TickyTask.store").path]

        var app = launch(store)
        openPlatform(app)
        let original = element(app, "kanban-colhdr-To Do").frame.width
        let handle = element(app, "kanban-resize-To Do column")
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "the column has a resize handle")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 80, dy: 0)))
        XCTAssertTrue(eventually { element(app, "kanban-colhdr-To Do").frame.width > original + 60 }, "the column widened")
        let widened = element(app, "kanban-colhdr-To Do").frame.width
        app.terminate()

        app = launch(store)
        openPlatform(app)
        XCTAssertTrue(eventually { abs(element(app, "kanban-colhdr-To Do").frame.width - widened) < 2 }, "the width is remembered")
        element(app, "kanban-resize-To Do column").doubleClick()
        XCTAssertTrue(eventually { abs(element(app, "kanban-colhdr-To Do").frame.width - original) < 2 }, "double-click resets it")
    }

    /// Add person offers someone from another board (Ravi, on Platform) as an existing person.
    func testAddSomeoneFromAnotherBoard() {
        let app = launch()
        let board = element(app, "kanban-sidebar-Data")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.click()
        let add = element(app, "kanban-add-person")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        let existing = app.radioButtons["Existing resource"].firstMatch
        XCTAssertTrue(existing.waitForExistence(timeout: 5), "there is someone to pick, so the choice shows")
        existing.click()
        XCTAssertTrue(element(app, "kanban-person-picker").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "kanban-person-name").exists, "no new-person fields for an existing person")
        element(app, "kanban-person-add").click()
        XCTAssertTrue(element(app, "kanban-rowhdr-Ravi Kumar").waitForExistence(timeout: 5), "Ravi joins the Data board")
    }

    /// A Done cell shows its five newest cards and tucks the rest behind "3 older"; Archive done
    /// cards… archives them all at once.
    func testDoneCellsShortenAndArchive() {
        let app = launch(["-uitestKanbanDone"])
        openPlatform(app)
        let older = element(app, "kanban-done-older-Done-Ravi Kumar")
        XCTAssertTrue(older.waitForExistence(timeout: 5), "the cell offers its older cards")
        XCTAssertTrue(element(app, "kanban-card-Finished 4").exists && !element(app, "kanban-card-Finished 5").exists, "five newest shown")
        XCTAssertTrue(element(app, "kanban-colhdr-Done").label.contains("5 shown"), "the header says how many show")
        older.click()
        XCTAssertTrue(element(app, "kanban-card-Finished 7").waitForExistence(timeout: 5), "opening the cell shows them all")
        element(app, "kanban-done-fewer-Done-Ravi Kumar").click()
        XCTAssertTrue(eventually { !element(app, "kanban-card-Finished 7").exists }, "Show fewer tucks them away again")

        element(app, "kanban-board-actions").click()
        let item = app.menuItems["Archive done cards…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let all = app.radioButtons["All done cards"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.click()
        app.sheets.buttons["kanban-archive-done-confirm"].firstMatch.click()
        XCTAssertTrue(eventually { !element(app, "kanban-card-Ship v1").exists && !element(app, "kanban-card-Finished 1").exists },
                      "every done card is archived")
        XCTAssertFalse(element(app, "kanban-done-older-Done-Ravi Kumar").exists)
    }

    /// A column's ⋯ › Appearance… picks an icon and a colour (each shown as selected), and Reset
    /// goes back to Automatic.
    func testColumnAppearance() {
        let app = launch()
        openPlatform(app)
        let menu = element(app, "kanban-column-menu-In Progress")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the header has a visible menu button")
        menu.click()
        let item = app.menuItems["Appearance…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let bolt = element(app, "kanban-appearance-icon-bolt")
        XCTAssertTrue(bolt.waitForExistence(timeout: 5), "the Appearance popover opens")
        bolt.click()
        XCTAssertTrue(eventually { element(app, "kanban-appearance-icon-bolt").isSelected }, "the chosen icon shows as selected")
        element(app, "kanban-appearance-colour-Violet").click()
        XCTAssertTrue(eventually { element(app, "kanban-appearance-colour-Violet").isSelected })
        element(app, "kanban-appearance-reset").click()
        XCTAssertTrue(eventually { !element(app, "kanban-appearance-icon-bolt").isSelected && !element(app, "kanban-appearance-colour-Violet").isSelected },
                      "Reset goes back to Automatic")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(eventually { !element(app, "kanban-appearance-icon-bolt").exists }, "Esc closes it")
    }

    func testKeyboardMovesAFocusedCard() {
        let app = launch()
        openPlatform(app)
        let card = element(app, "kanban-card-Write docs")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.3)).click()   // opens the editor, and focuses the card
        if element(app, "kanban-editor-cancel").waitForExistence(timeout: 3) { element(app, "kanban-editor-cancel").click() }
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(eventually { isInside(element(app, "kanban-card-Write docs"), element(app, "kanban-cell-Done-Mia Chen")) },
                      "⌘→ moves it to the next column")
    }

    // MARK: - Increment 6: filters, List view, bulk, undo, Change Log, search

    func testFilterByTextShowsAChipAndClears() {
        let app = launch()
        openPlatform(app)
        element(app, "kanban-filter").click()
        let field = element(app, "kanban-filter-text")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("API\r")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "kanban-clear-filters").waitForExistence(timeout: 5), "an active filter shows the chips")
        XCTAssertTrue(eventually { !element(app, "kanban-card-Triage inbox").exists }, "non-matching cards are hidden")
        XCTAssertTrue(element(app, "kanban-card-Build API").exists)
        element(app, "kanban-clear-filters").click()
        XCTAssertTrue(element(app, "kanban-card-Triage inbox").waitForExistence(timeout: 5), "Clear shows everything again")
    }

    func testListViewBulkAssignAndUndo() {
        let app = launch()
        openPlatform(app)
        selectView(app, "List")
        let row = element(app, "kanban-list-row-Triage inbox")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the List view shows the cards")
        row.rightClick()
        app.menuItems["Assign to"].firstMatch.hover()
        let mia = app.menuItems["Mia Chen"].firstMatch
        XCTAssertTrue(mia.waitForExistence(timeout: 5))
        mia.click()
        let table = element(app, "kanban-list")
        XCTAssertTrue(eventually { table.staticTexts["Mia Chen"].exists }, "assigned to Mia")
        app.typeKey("z", modifierFlags: .command)   // in the List view
        selectView(app, "Board")
        XCTAssertTrue(eventually { isInside(element(app, "kanban-card-Triage inbox"), element(app, "kanban-cell-To Do-Unassigned")) },
                      "⌘Z in the List view undoes it")
    }

    func testChangeLogRevertsACreatedCard() {
        let app = launch()
        openPlatform(app)
        app.typeKey("n", modifierFlags: .command)
        let titleField = element(app, "kanban-editor-title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeText("Temporary")
        element(app, "kanban-editor-done").click()
        XCTAssertTrue(element(app, "kanban-card-Temporary").waitForExistence(timeout: 5))
        element(app, "kanban-change-log").click()
        let revert = element(app, "kanban-changelog-revert-Added Temporary")
        XCTAssertTrue(revert.waitForExistence(timeout: 5), "the Change Log lists the new card with Revert")
        revert.click()
        element(app, "kanban-changelog-done").click()
        XCTAssertTrue(eventually { !element(app, "kanban-card-Temporary").exists }, "reverting the creation removes the card")
    }

    func testSearchFindsACardOnItsBoard() {
        let app = launch()
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Load warehouse")
        let result = element(app, "search-kanban-Load warehouse")
        XCTAssertTrue(result.waitForExistence(timeout: 5), "Kanban results are listed")
        result.click()
        XCTAssertTrue(element(app, "kanban-card-Load warehouse").waitForExistence(timeout: 5), "the Data board opens on the card")
        XCTAssertTrue(element(app, "kanban-breadcrumb").label.contains("Data") || (element(app, "kanban-breadcrumb").value as? String ?? "").contains("Data"))
    }

    // MARK: - Increment 7: dashboard, timeline

    func testDashboardShowsChartsAndOpensAFilteredBoard() {
        let app = launch()
        openPlatform(app)
        selectView(app, "Dashboard")
        XCTAssertTrue(element(app, "kanban-dash-load").waitForExistence(timeout: 5), "the dashboard opens")
        // The charts are in a lazy grid: one below the fold isn't in the tree until scrolled to.
        let dashboard = element(app, "kanban-dashboard")
        func reveal(_ id: String) -> Bool {
            // The sign of a scroll delta differs between setups; try one way, then the other.
            for delta in [0.0] + Array(repeating: -300.0, count: 12) + Array(repeating: 300.0, count: 24) {
                if delta != 0 { dashboard.scroll(byDeltaX: 0, deltaY: delta) }
                if element(app, id).waitForExistence(timeout: 0.5) { return true }
            }
            return false
        }
        for id in ["kanban-dash-load", "kanban-dash-heatmap", "kanban-dash-columns", "kanban-dash-due", "kanban-dash-cfd", "kanban-dash-hygiene"] {
            XCTAssertTrue(reveal(id), "\(id) should be on the dashboard")
        }
        XCTAssertTrue(reveal("kanban-dash-open-due"))
        element(app, "kanban-dash-open-due").click()
        XCTAssertTrue(element(app, "kanban-chip-Overdue").waitForExistence(timeout: 5), "the board opens filtered to overdue")
        XCTAssertTrue(element(app, "kanban-card-Build API").exists, "the overdue card is shown")
        XCTAssertFalse(element(app, "kanban-card-Triage inbox").exists)
    }

    func testTimelineShowsDatedCards() {
        let app = launch()
        openPlatform(app)
        selectView(app, "Timeline")
        XCTAssertTrue(element(app, "kanban-timeline").waitForExistence(timeout: 5))
        // A SwiftUI Text's string is its accessibility value on macOS, not its label.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'without dates'")).firstMatch.waitForExistence(timeout: 5),
                      "undated cards are counted")
    }

    func testCardDeleteButtonShowsAndDeletes() {
        let app = launch()
        openPlatform(app)
        let card = element(app, "kanban-card-Write docs")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the card exists before delete")
        // Hover to reveal the delete button
        card.hover()
        // Every card keeps its (hidden) buttons, so take the shown one on this card.
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-card-delete-'"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 5), "delete buttons exist")
        let deleteButton = eventually {
            candidates.allElementsBoundByIndex.contains { isInside($0, card) && $0.isHittable }
        } ? candidates.allElementsBoundByIndex.first { isInside($0, card) && $0.isHittable } : nil
        XCTAssertNotNil(deleteButton, "the delete button appears on hover")
        deleteButton?.click()
        // Confirm in the dialog
        let deleteConfirm = app.sheets.buttons["Delete Card"].firstMatch
        XCTAssertTrue(deleteConfirm.waitForExistence(timeout: 5), "the delete confirmation dialog appears")
        deleteConfirm.click()
        XCTAssertFalse(element(app, "kanban-card-Write docs").exists, "the card is deleted")
    }
}
