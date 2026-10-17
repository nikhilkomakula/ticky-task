import SwiftUI
import SwiftData
import AppKit

/// The menu-bar popover: a compact header, a mini month calendar, and the
/// selected day's agenda with inline quick-add. "Open TickyTask" collapses this
/// popover and brings the main window forward; the gear opens Settings (the only
/// way to reach it when the Dock icon is hidden).
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @AppStorage(ModulePolicy.showPlannerKey) private var showPlanner = true
    @AppStorage(ModulePolicy.showKanbanKey) private var showKanban = true
    @AppStorage("defaultModule") private var defaultModule = AppModule.planner.rawValue
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
    /// Planner or Kanban: the choice made here this session, else the Default view.
    private var mode: AppModule {
        let policy = ModulePolicy(showPlanner: showPlanner, showKanban: showKanban)
        return policy.resolve(app.popoverModule ?? AppModule(rawValue: defaultModule) ?? .planner)
    }

    @ViewBuilder private var menuBarAgenda: some View {
        let agenda = Group {
            if mode == .kanban {
                KanbanDayAgendaView(dayKey: selectedDayKey, open: openCard, openKanban: openKanbanModule)
            } else {
                DayAgendaView(dayKey: selectedDayKey, dragController: dragController, insets: 8, scrolls: false)
            }
        }
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
                    // The only way to quit when running menu-bar-only (no Dock icon / app menu).
                    Button { NSApp.terminate(nil) } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .help("Quit TickyTask (⌘Q)")
                    .keyboardShortcut("q", modifiers: .command)
                    .accessibilityLabel("Quit TickyTask")
                    .accessibilityIdentifier("menubar-quit")
                }

                Group {
                    if mode == .kanban {
                        MenuBarKanbanCalendarView(selectedDayKey: $selectedDayKey)
                    } else {
                        MiniMonthCalendar(selectedDayKey: $selectedDayKey,
                                          markedDays: [],
                                          acceptsDrops: true)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                if ModulePolicy(showPlanner: showPlanner, showKanban: showKanban).showsSwitcher {
                    Picker("Show", selection: Binding(get: { mode }, set: { app.popoverModule = $0 })) {
                        ForEach(AppModule.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("menubar-module")
                }

                menuBarAgenda
                    .onPreferenceChange(AgendaHeightKey.self) { agendaContentHeight = $0 }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(10)

            DragOverlayView(controller: dragController)
        }
        .frame(width: 340)
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
        .onChange(of: mode) { _, _ in dragController.cancel() }
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

    /// The main window on the card's board, highlighted, after the panel closes.
    private func openCard(_ task: KanbanTask) {
        guard let projectID = task.project?.id else { return }
        app.revealKanban(taskID: task.id, projectID: projectID)
        openMainWindow()
    }

    /// The main window's Kanban module, where boards are created.
    private func openKanbanModule() {
        app.module = .kanban
        app.kanban.selection = .allProjects
        openMainWindow()
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

/// Kanban-only child that restricts the query to active tasks/projects only,
/// so Planner mode does not instantiate it.
private struct MenuBarKanbanCalendarView: View {
    @Binding var selectedDayKey: String
    @Query(filter: #Predicate<KanbanTask> {
        $0.dueDate != nil &&
        $0.archivedAt == nil &&
        $0.project?.archivedAt == nil
    }) private var kanbanDueTasks: [KanbanTask]

    var body: some View {
        MiniMonthCalendar(selectedDayKey: $selectedDayKey,
                          markedDays: KanbanPopover.dueDayKeys(kanbanDueTasks),
                          acceptsDrops: false)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
