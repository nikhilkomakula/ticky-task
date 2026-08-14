import SwiftUI
import AppKit

/// The menu-bar popover: a compact header, a mini month calendar, and the
/// selected day's agenda with inline quick-add. "Open TickyTask" collapses this
/// popover and brings the main window forward; the gear opens Settings (the only
/// way to reach it when the Dock icon is hidden).
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(AppState.self) private var app

    /// Weak handle to this popover's own `NSPanel`, captured from the view tree,
    /// so we can close it on demand. `MenuBarExtra(.window)` is an `NSPanel`
    /// (not an `NSPopover`), so `performClose:`/`dismiss()` don't collapse it.
    @State private var panelRef = WeakWindowReference()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("TickyTask")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: openSettingsWindow) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .help("Settings")
                Button(action: openMainWindow) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .help("Open TickyTask")
            }

            MiniMonthCalendar()
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            DayAgendaView(dayKey: app.selectedDayKey, insets: 8)
                .frame(minHeight: 180, maxHeight: 260)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(10)
        .frame(width: 340)
        .background {
            // Capture the hosting panel (structurally, not by private class name).
            HostingWindowAccessor { [panelRef] window in
                if MenuBarWindowSupport.isMenuBarExtraPanel(window) { panelRef.window = window }
            }
            .frame(width: 0, height: 0)
        }
    }

    /// Close this popover's own panel (`MenuBarExtra(.window)` is an `NSPanel`;
    /// `close()` sends the will-close notification SwiftUI needs to reset its
    /// presentation state so the next status-item click reopens cleanly).
    private func dismissPopover() {
        if let window = panelRef.window, MenuBarWindowSupport.isMenuBarExtraPanel(window) {
            window.close()
        }
    }

    /// Collapse the popover, then open/activate the main window one run-loop turn
    /// later (so AppKit finishes the close first).
    private func openMainWindow() {
        dismissPopover()
        DispatchQueue.main.async {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Collapse the popover, then open Settings and bring it frontmost. Activation
    /// is explicit so Settings appears above other apps even when the Dock icon is
    /// hidden (accessory mode), where SettingsLink alone can open it behind.
    private func openSettingsWindow() {
        dismissPopover()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}

/// Weak box so `@State` can hold a reference to the panel without retaining it.
final class WeakWindowReference {
    weak var window: NSWindow?
    init() {}
}

enum MenuBarWindowSupport {
    /// Structural test that a window is the `MenuBarExtra(.window)` panel — an
    /// `NSPanel` above the normal window level, borderless or non-activating —
    /// never the main titled window. Deliberately avoids private class-name
    /// checks, which drift across macOS releases.
    static func isMenuBarExtraPanel(_ window: NSWindow) -> Bool {
        guard window is NSPanel else { return false }
        guard window.level != .normal else { return false }
        return !window.styleMask.contains(.titled) || window.styleMask.contains(.nonactivatingPanel)
    }
}

/// Reports the `NSWindow` currently hosting this view (once it's in the tree).
private struct HostingWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { WindowObservingView(onResolve: onResolve) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowObservingView else { return }
        view.onResolve = onResolve
        view.resolveWindow()
    }

    private final class WindowObservingView: NSView {
        var onResolve: (NSWindow) -> Void
        init(onResolve: @escaping (NSWindow) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveWindow()
        }
        func resolveWindow() {
            if let window { onResolve(window) }
        }
    }
}
