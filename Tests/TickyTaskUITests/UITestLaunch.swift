import XCTest

extension XCUIApplication {
    /// Launches and makes sure the main window is open. macOS sometimes starts
    /// the app with no window (it stays reachable from the Window menu), which
    /// would otherwise fail every test before it begins.
    func launchWithMainWindow() {
        launch()
        guard !windows.firstMatch.waitForExistence(timeout: 5) else { return }
        menuBars.menuBarItems["Window"].click()
        menuBars.menuItems["TickyTask"].click()
        _ = windows.firstMatch.waitForExistence(timeout: 5)
    }
}
