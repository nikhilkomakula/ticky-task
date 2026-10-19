import AppKit
import ApplicationServices
import XCTest

/// The board must never stop answering while it scrolls. Its person rows were once built
/// lazily; a row thrown away off screen lost its card measurements and came back at estimated
/// heights, and on a board shaped like `-uitestKanbanVaried` jumping the scroller re-laid the
/// window forever (100% CPU; with a context menu open AppKit gave up and the app crashed).
final class KanbanBoardFreezeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ seed: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-calendarColumns", "7", "-weekStartsMonday", "YES", "-showWeekends", "YES",
                               "-kanban.defaultBoard", ""] + seed
        app.launchWithMainWindow()
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 20), "the planner opens first")
        app.typeKey("2", modifierFlags: .command)
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openBoard(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let sidebar = element(app, "kanban-sidebar-\(name)")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "the \(name) board is in the sidebar")
        sidebar.click()
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the board's columns render")
        let board = element(app, "kanban-board")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        return board
    }

    /// The app under test, for direct Accessibility calls (the newest TickyTask process).
    private func appElement() -> AXUIElement? {
        let running = NSWorkspace.shared.runningApplications
            .filter { ($0.bundleIdentifier ?? "").hasPrefix("com.tickytask.mac") && !($0.bundleIdentifier ?? "").contains("uitests") }
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        return running.map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func find(_ root: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
        if attribute(root, "AXIdentifier") as? String == identifier { return root }
        guard depth < 40 else { return nil }
        for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = find(child, identifier: identifier, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Fails if the app crashed or its main thread stopped answering for 5 seconds.
    private func assertResponsive(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        if let ax = appElement() {
            AXUIElementSetMessagingTimeout(ax, 5)
            var window: AnyObject?
            let result = AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window)
            XCTAssertNotEqual(result, .cannotComplete, "the app answers within 5 s after \(step)", file: file, line: line)
        }
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after \(step)", file: file, line: line)
        XCTAssertTrue(element(app, "kanban-colhdr-To Do").waitForExistence(timeout: 10), "the board still answers after \(step)",
                      file: file, line: line)
    }

    /// Jumps the vertical scroller top to bottom and back, the way dragging its thumb does.
    func testJumpingTheScrollerDoesNotFreezeTheBoard() throws {
        let app = launch(["-uitestKanbanVaried"])
        let board = openBoard(app, "Varied")
        let ax = try XCTUnwrap(appElement(), "the app under test is running")
        AXUIElementSetMessagingTimeout(ax, 5)
        if let scrollArea = find(ax, identifier: "kanban-board"),
           let scroller = attribute(scrollArea, kAXVerticalScrollBarAttribute).map({ $0 as! AXUIElement }) {
            for round in 0..<6 {
                for step in 0...12 {
                    let fraction = Double(step) / 12
                    AXUIElementSetAttributeValue(scroller, kAXValueAttribute as CFString,
                                                 NSNumber(value: round.isMultiple(of: 2) ? fraction : 1 - fraction))
                    usleep(16_000)
                }
                Thread.sleep(forTimeInterval: 1)
                assertResponsive(app, "scroller sweep \(round)")
            }
        } else {
            // No Accessibility access from the runner: drag the scroller's thumb instead.
            XCTContext.runActivity(named: "dragging the scroll bar (no direct Accessibility)") { _ in
                let scrollBar = board.scrollBars.element(boundBy: board.scrollBars.count - 1)
                XCTAssertTrue(scrollBar.exists, "the board has a vertical scroll bar")
                for round in 0..<6 {
                    let top = scrollBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
                    let bottom = scrollBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
                    (round.isMultiple(of: 2) ? top : bottom).press(forDuration: 0.1, thenDragTo: round.isMultiple(of: 2) ? bottom : top)
                    Thread.sleep(forTimeInterval: 1)
                    assertResponsive(app, "scroll bar drag \(round)")
                }
            }
        }
        // Wheel scrolling in big steps too.
        for round in 0..<6 { board.scroll(byDeltaX: 0, deltaY: round.isMultiple(of: 2) ? -3000 : 3000) }
        assertResponsive(app, "wheel jumps")
    }

    /// A card's context menu over a board that's still settling from a scroll.
    func testContextMenusWhileScrollingKeepTheBoardResponsive() {
        let app = launch(["-uitestKanbanVaried"])
        let board = openBoard(app, "Varied")
        var menusOpened = 0
        for round in 0..<6 {
            board.scroll(byDeltaX: 0, deltaY: round.isMultiple(of: 2) ? -1500 : 900)
            let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'kanban-card-'"))
            let headers = element(app, "kanban-colhdr-To Do").frame.maxY
            let visible = (0..<min(cards.count, 40)).map { cards.element(boundBy: $0) }.first {
                $0.frame.minY > headers + 4 && $0.frame.maxY < board.frame.maxY - 4 && $0.isHittable
            }
            guard let card = visible else { continue }
            card.rightClick()
            XCTAssertTrue(app.menuItems["Duplicate"].firstMatch.waitForExistence(timeout: 10), "round \(round): the card's menu opens")
            menusOpened += 1
            Thread.sleep(forTimeInterval: 1.5)
            app.typeKey(.escape, modifierFlags: [])
            assertResponsive(app, "round \(round)'s menu")
        }
        XCTAssertGreaterThanOrEqual(menusOpened, 4, "most rounds opened a menu")
    }
}
