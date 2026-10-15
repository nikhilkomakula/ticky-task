import XCTest

extension XCUIApplication {
    /// Launches and makes sure the main window is open. macOS sometimes starts
    /// the app with no window (it stays reachable from the Window menu), which
    /// would otherwise fail every test before it begins.
    func launchWithMainWindow() {
        launch()
        if !windows.firstMatch.waitForExistence(timeout: 5) {
            menuBars.menuBarItems["Window"].click()
            menuBars.menuItems["TickyTask"].click()
            _ = windows.firstMatch.waitForExistence(timeout: 5)
        }
        waitForWindowToSettle()
    }

    /// The window opens and then maximizes; clicks during that resize can miss.
    private func waitForWindowToSettle(timeout: TimeInterval = 5) {
        let window = windows.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var last = window.exists ? window.frame : .zero
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let current = window.exists ? window.frame : .zero
            if current == last && current != .zero { return }
            last = current
        }
    }
}
