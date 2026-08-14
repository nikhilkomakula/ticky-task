import SwiftUI
import AppKit
import KeyboardShortcuts

/// Global keyboard-shortcut names, configurable in Settings › Shortcuts.
extension KeyboardShortcuts.Name {
    /// Bring the main TodoPlanner window to the front.
    static let openApp = Self("openApp")
    /// Open the quick-capture window to add a task for today from anywhere.
    static let newTaskToday = Self("newTaskToday")
}

/// Installs the global shortcut handlers exactly once per process. A view-level
/// guard isn't enough (a reopened window would append duplicate handlers), so
/// the guard lives here at process scope.
@MainActor
enum GlobalShortcutsInstaller {
    private static var installed = false

    static func installIfNeeded(openWindow: OpenWindowAction) {
        guard !installed else { return }
        installed = true

        KeyboardShortcuts.onKeyUp(for: .openApp) {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
        }
        KeyboardShortcuts.onKeyUp(for: .newTaskToday) {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "quickCapture")
            }
        }
    }
}
