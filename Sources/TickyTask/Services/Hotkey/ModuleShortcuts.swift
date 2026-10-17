import SwiftUI
import AppKit
import KeyboardShortcuts

/// A Planner / Kanban shortcut: a key and its modifiers, used only as the View menu's key
/// equivalent. Kept out of the KeyboardShortcuts package on purpose: saving a shortcut there
/// registers it as a system-wide hotkey, which would take ⌘1 / ⌘2 from every other app.
struct ModuleShortcut: Codable, Equatable, Sendable {
    /// The virtual key code, to compare with the global shortcuts (Carbon uses the same codes).
    var keyCode: Int
    /// The unshifted character ("1", "k", a function-key scalar) or a named key ("upArrow", …).
    var key: String
    /// Only ⌘ ⌃ ⌥ ⇧.
    var modifiers: UInt

    static let plannerDefault = ModuleShortcut(keyCode: 18, key: "1", modifiers: NSEvent.ModifierFlags.command.rawValue)
    static let kanbanDefault = ModuleShortcut(keyCode: 19, key: "2", modifiers: NSEvent.ModifierFlags.command.rawValue)

    private static let allowedFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Keys that need SwiftUI's own key equivalent rather than a character, by key code.
    private static let named: [Int: (name: String, key: KeyEquivalent, glyph: String)] = [
        126: ("upArrow", .upArrow, "↑"), 125: ("downArrow", .downArrow, "↓"), 123: ("leftArrow", .leftArrow, "←"),
        124: ("rightArrow", .rightArrow, "→"), 36: ("return", .return, "↩"), 48: ("tab", .tab, "⇥"), 49: ("space", .space, "Space"),
        51: ("delete", .delete, "⌫"), 117: ("deleteForward", .deleteForward, "⌦"), 115: ("home", .home, "↖"),
        119: ("end", .end, "↘"), 116: ("pageUp", .pageUp, "⇞"), 121: ("pageDown", .pageDown, "⇟"),
    ]
    /// The numeric keypad's keys, which a menu can't tell from the main ones.
    private static let keypad: Set<Int> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    private static let functionKeys: ClosedRange<UInt32> = 0xF704...0xF726   // F1–F35

    /// What a key press records, or nil for one that can't be a menu shortcut: a keypad key,
    /// or a key without ⌘, ⌃ or ⌥ that isn't a function key.
    init?(event: NSEvent) {
        let code = Int(event.keyCode)
        guard !Self.keypad.contains(code) else { return nil }
        let flags = event.modifierFlags.intersection(Self.allowedFlags)
        let raw = event.charactersIgnoringModifiers ?? ""
        let isFunctionKey = raw.unicodeScalars.first.map { Self.functionKeys.contains($0.value) } ?? false
        // The unshifted character, so ⇧⌘1 records "1" with ⇧ rather than "!".
        let character = isFunctionKey ? raw : event.characters(byApplyingModifiers: []) ?? raw
        guard !flags.subtracting(.shift).isEmpty || isFunctionKey else { return nil }
        if let named = Self.named[code] {
            key = named.name
        } else if let first = character.lowercased().first, !first.isWhitespace {
            key = String(first)
        } else {
            return nil
        }
        keyCode = code
        modifiers = flags.rawValue
    }

    init(keyCode: Int, key: String, modifiers: UInt) {
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.allowedFlags) }

    private var namedKey: (name: String, key: KeyEquivalent, glyph: String)? { Self.named.values.first { $0.name == key } }

    var keyEquivalent: KeyEquivalent { namedKey?.key ?? KeyEquivalent(key.first ?? " ") }

    var menuShortcut: KeyboardShortcut {
        var modifiers: EventModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return KeyboardShortcut(keyEquivalent, modifiers: modifiers, localization: .custom)
    }

    /// As menus write it: "⌃⌥⌘K", "⌘↑", "F5".
    var description: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        if let namedKey { return text + namedKey.glyph }
        if let scalar = key.unicodeScalars.first, Self.functionKeys.contains(scalar.value) {
            return text + "F\(scalar.value - Self.functionKeys.lowerBound + 1)"
        }
        return text + key.uppercased()
    }

    /// Whether a menu item's key equivalent is this shortcut.
    func matches(_ item: NSMenuItem) -> Bool {
        guard !item.keyEquivalent.isEmpty else { return false }
        var equivalent = item.keyEquivalent
        var mask = item.keyEquivalentModifierMask.intersection(Self.allowedFlags)
        // A menu writes ⇧⌘K as "K" with ⌘ only.
        if equivalent.count == 1, equivalent.lowercased() != equivalent {
            equivalent = equivalent.lowercased()
            mask.insert(.shift)
        }
        return equivalent == String(keyEquivalent.character) && mask == flags
    }
}

/// The Planner / Kanban shortcuts the View menu and the shortcuts list show (⌘1 / ⌘2 until
/// changed in Settings › Shortcuts; either can be cleared). UI tests get a fresh store each launch.
@MainActor @Observable
final class ModuleShortcuts {
    static let shared = ModuleShortcuts(defaults: UITestSupport.isRunning ? UITestSupport.scratchDefaults : .standard)

    private let defaults: UserDefaults
    private(set) var planner: ModuleShortcut?
    private(set) var kanban: ModuleShortcut?

    /// Stored when a shortcut is cleared, so it isn't mistaken for "never set".
    private static let cleared = "none"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        planner = load(.planner)
        kanban = load(.kanban)
    }

    static func defaultsKey(_ module: AppModule) -> String { "moduleShortcut.\(module.rawValue)" }

    private func load(_ module: AppModule) -> ModuleShortcut? {
        let fallback = module == .planner ? ModuleShortcut.plannerDefault : .kanbanDefault
        guard let stored = defaults.string(forKey: Self.defaultsKey(module)) else { return fallback }
        if stored == Self.cleared { return nil }
        // Unreadable (a hand edit, a newer format): the default, leaving the stored value alone.
        return (try? JSONDecoder().decode(ModuleShortcut.self, from: Data(stored.utf8))) ?? fallback
    }

    func shortcut(for module: AppModule) -> ModuleShortcut? { module == .planner ? planner : kanban }

    func menuShortcut(for module: AppModule) -> KeyboardShortcut? { shortcut(for: module)?.menuShortcut }

    func set(_ shortcut: ModuleShortcut?, for module: AppModule) {
        let stored = shortcut.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? Self.cleared
        defaults.set(stored, forKey: Self.defaultsKey(module))
        if module == .planner { planner = shortcut } else { kanban = shortcut }
    }

    func restoreDefaults() {
        for module in AppModule.allCases { defaults.removeObject(forKey: Self.defaultsKey(module)) }
        planner = .plannerDefault
        kanban = .kanbanDefault
    }

    /// "⌘1 / ⌘2" for the shortcuts list; a cleared one shows as "none".
    var summary: String { "\(planner?.description ?? "none") / \(kanban?.description ?? "none")" }

    /// Why `candidate` can't be `module`'s shortcut, or nil if it can. Its own current keys are
    /// always fine; the other module's, a global shortcut's or another menu item's are not.
    func conflict(_ candidate: ModuleShortcut, for module: AppModule, menu: NSMenu? = NSApp.mainMenu) -> String? {
        if candidate == shortcut(for: module) { return nil }
        let other: AppModule = module == .planner ? .kanban : .planner
        if candidate == shortcut(for: other) { return "\(other.label) already uses \(candidate.description). Clear it there first." }
        let globals: [KeyboardShortcuts.Name] = [.openApp, .newTaskToday, .toggleMenuBar]
        if globals.contains(where: { name in
            KeyboardShortcuts.getShortcut(for: name).map { $0.carbonKeyCode == candidate.keyCode && $0.modifiers.intersection([.command, .option, .control, .shift]) == candidate.flags } ?? false
        }) {
            return "A global shortcut above already uses \(candidate.description)."
        }
        if let item = menu.flatMap({ Self.menuItem(matching: candidate, in: $0) }) {
            return "“\(item.title)” already uses \(candidate.description)."
        }
        return nil
    }

    /// A main-menu item using `shortcut`, other than View › Planner / Kanban themselves.
    private static func menuItem(matching shortcut: ModuleShortcut, in menu: NSMenu) -> NSMenuItem? {
        let own = Set(AppModule.allCases.map(\.label))
        for item in menu.items {
            if !own.contains(item.title), shortcut.matches(item) { return item }
            if let submenu = item.submenu, let found = menuItem(matching: shortcut, in: submenu) { return found }
        }
        return nil
    }
}

/// Settings › Shortcuts: click, then press the new keys (Esc cancels). Keys are read only while
/// recording and only inside TickyTask.
struct ModuleShortcutRecorder: View {
    let module: AppModule
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?
    private let store = ModuleShortcuts.shared

    var body: some View {
        LabeledContent("Show \(module.label):") {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Button(recording ? "Press keys…" : store.shortcut(for: module)?.description ?? "None") {
                        recording ? stop() : start()
                    }
                    .frame(minWidth: 110)
                    .help(recording ? "Press the new shortcut, or Esc to cancel" : "Click, then press a new shortcut")
                    .accessibilityLabel("\(module.label) shortcut")
                    .accessibilityValue(store.shortcut(for: module)?.description ?? "None")
                    .accessibilityIdentifier("shortcut-show-\(module.rawValue)")
                    if store.shortcut(for: module) != nil, !recording {
                        Button { store.set(nil, for: module) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear")
                            .accessibilityLabel("Clear the \(module.label) shortcut")
                            .accessibilityIdentifier("shortcut-clear-\(module.rawValue)")
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                stop()
                return nil
            }
            guard let shortcut = ModuleShortcut(event: event) else {
                message = "Use ⌘, ⌃ or ⌥ with a key, or a function key (not the keypad)."
                NSSound.beep()
                return nil
            }
            if let conflict = store.conflict(shortcut, for: module) {
                message = conflict
                NSSound.beep()
                return nil
            }
            store.set(shortcut, for: module)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
