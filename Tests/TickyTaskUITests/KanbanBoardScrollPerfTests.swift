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

    /// Scrolls the board vertically by dragging from the middle down and measuring
    /// frame rate (via XCTOSSignpostMetric.scrollingAndDecelerationMetric) to catch
    /// performance drops in data preparation or view rendering with large cards.
    func testVerticalScrollPerformance() {
        let app = launch()
        openVolumeBoard(app)
        
        let board = element(app, "kanban-board")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        
        let startPoint = board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endPoint = board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        }
        
        app.terminate()
    }

    /// Scrolls the board horizontally by dragging across columns and measures
    /// frame rate. Horizontal scrolling must repaint the sticky column headers
    /// and drag preview, so this catches header rendering bottlenecks.
    func testHorizontalScrollPerformance() {
        let app = launch()
        openVolumeBoard(app)
        
        let board = element(app, "kanban-board")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        
        let startPoint = board.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let endPoint = board.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        }
        
        app.terminate()
    }

    /// Performs multiple rapid scrolls in both directions and times the total
    /// elapsed time with XCTClockMetric to measure cumulative scroll responsiveness.
    func testRepeatedScrollTiming() {
        let app = launch()
        openVolumeBoard(app)
        
        let board = element(app, "kanban-board")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<5 {
                let downPoint = board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                let upPoint = board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                downPoint.press(forDuration: 0.05, thenDragTo: upPoint)
                
                let rightPoint = board.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
                let leftPoint = board.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
                rightPoint.press(forDuration: 0.05, thenDragTo: leftPoint)
            }
        }
        
        app.terminate()
    }
}
