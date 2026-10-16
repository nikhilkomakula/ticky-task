import XCTest

extension XCUIApplication {
    /// Launches and makes sure the main window is open. macOS sometimes starts
    /// the app with no window (it stays reachable from the Window menu), which
    /// would otherwise fail every test before it begins.
    func launchWithMainWindow() {
        launch()
        // A cold machine (CI) can take a while to show the first window.
        if !windows.firstMatch.waitForExistence(timeout: 20) {
            let windowMenu = menuBars.menuBarItems["Window"]
            windowMenu.click()
            windowMenu.menuItems["TickyTask"].firstMatch.click()
            _ = windows.firstMatch.waitForExistence(timeout: 10)
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
