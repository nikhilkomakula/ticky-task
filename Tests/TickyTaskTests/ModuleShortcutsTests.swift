import Testing
import SwiftUI
import AppKit
@testable import TickyTask

/// The Planner / Kanban menu shortcuts recorded in Settings › Shortcuts: what a key press
/// records, how the menu uses it, how it's stored and which keys are refused. Every store here
/// is a throwaway defaults suite.
@MainActor
@Suite("Module shortcuts", .serialized)
struct ModuleShortcutsTests {
    private func store() -> (ModuleShortcuts, UserDefaults, String) {
        let name = "module-shortcuts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (ModuleShortcuts(defaults: defaults), defaults, name)
    }

    private func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> ModuleShortcut? {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        return event.flatMap(ModuleShortcut.init(event:))
    }

    @Test("Unset, they are ⌘1 and ⌘2")
    func defaults() {
        let (shortcuts, defaults, name) = store()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(shortcuts.planner == .plannerDefault && shortcuts.kanban == .kanbanDefault)
        #expect(shortcuts.summary == "⌘1 / ⌘2")
        let menu = shortcuts.menuShortcut(for: .planner)
        #expect(menu?.key.character == "1" && menu?.modifiers == .command)
    }

    @Test("A recorded shortcut, a cleared one and Restore survive a relaunch")
    func storage() {
        let (shortcuts, defaults, name) = store()
        defer { defaults.removePersistentDomain(forName: name) }
        let k = ModuleShortcut(keyCode: 40, key: "k", modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue)
        shortcuts.set(k, for: .kanban)
        shortcuts.set(nil, for: .planner)
        let relaunched = ModuleShortcuts(defaults: defaults)
        #expect(relaunched.kanban == k && relaunched.planner == nil, "cleared stays cleared")
        #expect(relaunched.summary == "none / ⌃⌘K")
        relaunched.restoreDefaults()
        #expect(ModuleShortcuts(defaults: defaults).planner == .plannerDefault)
        defaults.set("not json", forKey: ModuleShortcuts.defaultsKey(.kanban))
        #expect(ModuleShortcuts(defaults: defaults).kanban == .kanbanDefault, "unreadable: the default")
    }

    @Test("Key presses record letters, arrows and function keys; plain or keypad keys are refused")
    func recording() {
        let k = press("k", keyCode: 40, [.command, .option])
        #expect(k?.description == "⌥⌘K" && k?.menuShortcut.modifiers == [.command, .option])
        let up = press(String(UnicodeScalar(NSUpArrowFunctionKey)!), keyCode: 126, [.command, .function, .numericPad])
        #expect(up?.description == "⌘↑" && up?.keyEquivalent == .upArrow, "an arrow uses SwiftUI's arrow key")
        let f5 = press(String(UnicodeScalar(NSF5FunctionKey)!), keyCode: 96, [.function])
        #expect(f5?.description == "F5", "a function key needs no modifier")
        #expect(press("k", keyCode: 40, []) == nil, "a plain key is refused")
        #expect(press("K", keyCode: 40, [.shift]) == nil, "so is ⇧ alone")
        #expect(press("1", keyCode: 83, [.command, .numericPad]) == nil, "keypad keys are refused")
    }

    @Test("Its own keys are fine; the other module's and another menu item's are refused")
    func conflicts() {
        let (shortcuts, defaults, name) = store()
        defer { defaults.removePersistentDomain(forName: name) }
        let menu = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu()
        file.submenu?.addItem(NSMenuItem(title: "New Card", action: nil, keyEquivalent: "n"))
        file.submenu?.addItem(NSMenuItem(title: "Kanban", action: nil, keyEquivalent: "2"))
        menu.addItem(file)
        #expect(shortcuts.conflict(.kanbanDefault, for: .kanban, menu: menu) == nil, "re-recording its own keys")
        #expect(shortcuts.conflict(.kanbanDefault, for: .planner, menu: menu)?.contains("Kanban already uses ⌘2") == true)
        let n = ModuleShortcut(keyCode: 45, key: "n", modifiers: NSEvent.ModifierFlags.command.rawValue)
        #expect(shortcuts.conflict(n, for: .kanban, menu: menu)?.contains("New Card") == true)
        let duplicate = ModuleShortcut(keyCode: 2, key: "d", modifiers: NSEvent.ModifierFlags.command.rawValue)
        #expect(shortcuts.conflict(duplicate, for: .planner, menu: menu)?.contains("duplicate a card") == true, "the board's own keys are refused")
        let reorder = ModuleShortcut(keyCode: 126, key: "upArrow", modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue)
        #expect(shortcuts.conflict(reorder, for: .kanban, menu: menu) != nil)
        // The board ignores ⌃ and ⇧ when it reads these keys, so their variants are reserved too.
        for flags: NSEvent.ModifierFlags in [[.command, .control], [.command, .shift], [.command, .control, .shift]] {
            let arrow = ModuleShortcut(keyCode: 124, key: "rightArrow", modifiers: flags.rawValue)
            #expect(shortcuts.conflict(arrow, for: .planner, menu: menu) != nil, "\(arrow.description)")
        }
        let shiftD = ModuleShortcut(keyCode: 2, key: "d", modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        #expect(shortcuts.conflict(shiftD, for: .planner, menu: menu) != nil)
        let optionD = ModuleShortcut(keyCode: 2, key: "d", modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue)
        #expect(shortcuts.conflict(optionD, for: .planner, menu: menu) == nil, "⌥⌘D isn't the board's")
        let free = ModuleShortcut(keyCode: 40, key: "k", modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue)
        #expect(shortcuts.conflict(free, for: .kanban, menu: menu) == nil)
    }
}
