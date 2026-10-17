import Testing
import SwiftUI
import KeyboardShortcuts
@testable import TickyTask

/// The Planner / Kanban menu shortcuts recorded in Settings › Shortcuts, as the View menu uses
/// them. Only the conversion is tested: recording writes the app's real preferences.
@MainActor
@Suite("Module shortcuts")
struct ModuleShortcutsTests {
    private func menu(_ key: KeyboardShortcuts.Key, _ flags: NSEvent.ModifierFlags) -> KeyboardShortcut? {
        ModuleShortcuts.menuShortcut(.init(key, modifiers: flags))
    }

    @Test("The defaults are ⌘1 and ⌘2")
    func defaults() {
        #expect(KeyboardShortcuts.Name.showPlanner.defaultShortcut == .init(.one, modifiers: .command))
        #expect(KeyboardShortcuts.Name.showKanban.defaultShortcut == .init(.two, modifiers: .command))
        let planner = menu(.one, .command)
        #expect(planner?.key.character == "1" && planner?.modifiers == .command)
    }

    @Test("A recorded shortcut keeps its key and every modifier")
    func recorded() {
        let controlOption = menu(.k, [.control, .option])
        #expect(controlOption?.key.character == "k" && controlOption?.modifiers == [.control, .option])
        let shiftCommand = menu(.p, [.shift, .command])
        #expect(shiftCommand?.key.character == "p" && shiftCommand?.modifiers == [.shift, .command])
        let function = menu(.f5, [.command])
        #expect(function != nil && function?.modifiers == .command, "function keys work too")
    }

    @Test("A cleared shortcut gives the menu item none")
    func cleared() {
        #expect(ModuleShortcuts.menuShortcut(nil) == nil)
    }
}
