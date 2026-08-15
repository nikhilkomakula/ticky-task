import SwiftUI
import AppKit
import KeyboardShortcuts

/// Global keyboard-shortcut names, configurable in Settings › Shortcuts.
extension KeyboardShortcuts.Name {
    /// Bring the main TickyTask window to the front.
    static let openApp = Self("openApp")
    /// Open the quick-capture window to add a task for today from anywhere.
    static let newTaskToday = Self("newTaskToday")
    /// Show or hide the menu-bar popover from anywhere.
    static let toggleMenuBar = Self("toggleMenuBar")
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
        KeyboardShortcuts.onKeyUp(for: .toggleMenuBar) {
            Task { @MainActor in MenuBarPopover.toggle() }
        }
    }
}

/// Shows/hides the menu-bar popover programmatically. SwiftUI's `MenuBarExtra`
/// owns the `NSStatusItem` and exposes no handle to it, so we locate its button
/// structurally — an `NSStatusBarButton` in the app's windows — and synthesize
/// the same click a user would make (which toggles the popover open/closed).
/// No-ops if the button can't be found, so it never crashes.
@MainActor
enum MenuBarPopover {
    static func toggle() {
        statusItemButton()?.performClick(nil)
    }

    private static func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = firstStatusBarButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func firstStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = firstStatusBarButton(in: subview) { return found }
        }
        return nil
    }
}
