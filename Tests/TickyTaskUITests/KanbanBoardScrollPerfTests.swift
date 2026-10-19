import XCTest

/// Kanban board scrolling performance benchmarks: measures frame rates and timing
/// while scrolling horizontally and vertically with 2,000 cards, 30 people, and
/// realistic data (priorities, estimates, subtasks, blocked state). These tests
/// run on CI only and time real scrolling gesture responsiveness.
final class KanbanBoardScrollPerfTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Launch with 2,000 cards: `-uitestKanbanVolume 2000` seeds the Volume board.
        app.launchArguments = ["-uitest", "-uitestKanbanVolume", "2000", "-calendarColumns", "7",
                               "-weekStartsMonday", "YES", "-showWeekends", "YES",
                               "-kanban.defaultBoard", ""]
        app.launchWithMainWindow()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 20), "the planner opens first")
        app.typeKey("2", modifierFlags: .command)
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openVolumeBoard(_ app: XCUIApplication) {
        let board = element(app, "kanban-sidebar-Volume")
        XCTAssertTrue(board.waitForExistence(timeout: 10), "the seeded Volume board is in the sidebar")
        board.click()
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the board's columns render")
    }

    /// The board ready to scroll, warmed up once so the first realization isn't measured.
    /// Scrolling uses the scroll wheel: a press-and-drag on the board would pick up a card.
    private func board(_ app: XCUIApplication) -> XCUIElement {
        openVolumeBoard(app)
        let board = element(app, "kanban-board")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.scroll(byDeltaX: 0, deltaY: -1200)
        board.scroll(byDeltaX: 0, deltaY: 1200)
        return board
    }

    func testVerticalScrollPerformance() {
        let app = launch()
        let board = board(app)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTClockMetric()], options: options) {
            board.scroll(byDeltaX: 0, deltaY: -2400)
            board.scroll(byDeltaX: 0, deltaY: 2400)
        }
        app.terminate()
    }

    /// Horizontal scrolling also moves the sticky row headers.
    func testHorizontalScrollPerformance() {
        let app = launch()
        let board = board(app)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTClockMetric()], options: options) {
            board.scroll(byDeltaX: -1200, deltaY: 0)
            board.scroll(byDeltaX: 1200, deltaY: 0)
        }
        app.terminate()
    }

    /// A fresh launch, scrolled once through content never drawn before: what opening a big board costs.
    /// Both directions, since scroll-wheel signs differ between machines; one of them is a no-op at the top.
    func testColdScrollThroughTheBoard() {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            let app = launch()
            openVolumeBoard(app)
            let board = element(app, "kanban-board")
            XCTAssertTrue(board.waitForExistence(timeout: 10))
            startMeasuring()
            for _ in 0..<4 { board.scroll(byDeltaX: 0, deltaY: -1500) }
            for _ in 0..<4 { board.scroll(byDeltaX: 0, deltaY: 1500) }
            stopMeasuring()
            app.terminate()
        }
    }
}
