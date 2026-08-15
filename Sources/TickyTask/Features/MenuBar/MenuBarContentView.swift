import SwiftUI
import AppKit

/// The menu-bar popover: a compact header, a mini month calendar, and the
/// selected day's agenda with inline quick-add. "Open TickyTask" collapses this
/// popover and brings the main window forward; the gear opens Settings (the only
/// way to reach it when the Dock icon is hidden).
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.modelContext) private var context
    @AppStorage("taskSortMode") private var sortModeRaw = TaskSortMode.manual.rawValue
    @AppStorage("moveCompletedToBottom") private var moveCompletedToBottom = true

    /// This popover's own drag-to-reorder controller. `MenuBarExtra(.window)` is a
    /// separate `NSPanel` scene, so it needs its own `"planner"` space + overlay
    /// (the main window's overlay can't cover it).
    @State private var dragController = DragController()

    /// The menu bar shows a self-contained day that resets to today each time the
    /// popover opens — independent of the main window's selection.
    @State private var selectedDayKey = WeekMath.dayKey(for: Date())

    /// Weak handle to this popover's own `NSPanel`, captured from the view tree,
    /// so we can close it on demand. `MenuBarExtra(.window)` is an `NSPanel`
    /// (not an `NSPopover`), so `performClose:`/`dismiss()` don't collapse it.
    @State private var panelRef = WeakWindowReference()

    /// Natural (unclipped) height of the day agenda, measured so the popover can
    /// hug short days and scroll only when a day would exceed `agendaMaxHeight`.
    @State private var agendaContentHeight: CGFloat = 0

    /// Cap the agenda so a day with an unusually long list scrolls instead of
    /// growing the popover off-screen; sized to the current screen, leaving room
    /// for the calendar and chrome above it. A normal day stays well under this
    /// and never scrolls.
    private var agendaMaxHeight: CGFloat {
        let usable = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, usable * 0.55)
    }

    /// The day agenda, measured for its natural height and made scrollable only
    /// when it would exceed `agendaMaxHeight` — so a normal day shows every task
    /// with no scrolling and no blank space, while a very long day scrolls inside
    /// the cap instead of pushing the popover off-screen.
    @ViewBuilder private var menuBarAgenda: some View {
        let agenda = DayAgendaView(dayKey: selectedDayKey, dragController: dragController, insets: 8, scrolls: false)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: AgendaHeightKey.self, value: geo.size.height)
                }
            )
        if agendaContentHeight > agendaMaxHeight {
            ScrollView { agenda }.frame(height: agendaMaxHeight)
        } else {
            agenda
        }
    }

    var body: some View {
        ZStack {
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

                MiniMonthCalendar(selectedDayKey: $selectedDayKey)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                menuBarAgenda
                    .onPreferenceChange(AgendaHeightKey.self) { agendaContentHeight = $0 }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(10)

            DragOverlayView(controller: dragController)
        }
        .frame(width: 340)
        .coordinateSpace(.named("planner"))
        .environment(dragController)
        .onPreferenceChange(RowFramesKey.self) { dragController.rowFrames = $0 }
        .onPreferenceChange(ContainerFramesKey.self) { dragController.containerFrames = $0 }
        .background {
            // Capture the hosting panel (structurally, not by private class name).
            HostingWindowAccessor { [panelRef] window in
                if MenuBarWindowSupport.isMenuBarExtraPanel(window) { panelRef.window = window }
            }
            .frame(width: 0, height: 0)
        }
        .onAppear {
            // Always open on today.
            selectedDayKey = WeekMath.dayKey(for: Date())
            syncDragConfig()
        }
        .onChange(of: sortModeRaw) { _, _ in syncDragConfig() }
        .onChange(of: moveCompletedToBottom) { _, _ in syncDragConfig() }
    }

    /// Keep the popover's drag controller pointed at the store + current sort config.
    private func syncDragConfig() {
        dragController.context = context
        dragController.sortMode = TaskSortMode(rawValue: sortModeRaw) ?? .manual
        dragController.completedToBottom = moveCompletedToBottom
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

/// Carries the day agenda's natural (unclipped) height up to the menu-bar view,
/// which uses it to decide whether the agenda needs to scroll.
private struct AgendaHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
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
