import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// View › Planner. Only the View menu uses it, so it works inside TickyTask, not from other apps.
    static let showPlanner = Self("switchToPlanner", default: .init(.one, modifiers: .command))
    /// View › Kanban, in-app like `showPlanner`.
    static let showKanban = Self("switchToKanban", default: .init(.two, modifiers: .command))
}

/// The Planner / Kanban shortcuts as the View menu and the shortcuts list show them, changeable
/// in Settings › Shortcuts (⌘1 / ⌘2 until changed; either can be cleared).
@MainActor @Observable
final class ModuleShortcuts {
    static let shared = ModuleShortcuts()

    private(set) var planner: KeyboardShortcuts.Shortcut?
    private(set) var kanban: KeyboardShortcuts.Shortcut?

    private init() { reload() }

    /// Called when Settings records, clears or restores a shortcut.
    func reload() {
        planner = KeyboardShortcuts.getShortcut(for: .showPlanner)
        kanban = KeyboardShortcuts.getShortcut(for: .showKanban)
    }

    func restoreDefaults() {
        KeyboardShortcuts.reset(.showPlanner, .showKanban)
        reload()
    }

    func menuShortcut(for module: AppModule) -> KeyboardShortcut? {
        Self.menuShortcut(module == .planner ? planner : kanban)
    }

    /// "⌘1 / ⌘2" for the shortcuts list; a cleared one shows as "none".
    var summary: String { "\(planner?.description ?? "none") / \(kanban?.description ?? "none")" }

    /// A recorded shortcut as a SwiftUI menu shortcut.
    static func menuShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) -> KeyboardShortcut? {
        guard let shortcut, let character = shortcut.nsMenuItemKeyEquivalent?.first else { return nil }
        let flags = shortcut.modifiers
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers, localization: .custom)
    }
}
