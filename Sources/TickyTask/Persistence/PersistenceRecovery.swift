import Foundation
import SwiftData

/// The last resort when a failed save can't be undone (SwiftData crashes rolling back
/// a deletion). The change must never reach the disk — not by autosave, nor carried
/// along by a later, unrelated save — so this instance quits without saving and a
/// fresh one reopens the last saved data and says what happened.
@MainActor
enum PersistenceRecovery {
    static let relaunchArgument = "-relaunchedAfterFailedSave"

    /// This instance was started by `discardByRelaunching`. It skips automatic
    /// deletions (auto-delete), so a store that keeps failing to save can't restart
    /// the app over and over.
    static var didRelaunch = ProcessInfo.processInfo.arguments.contains(relaunchArgument)

    /// Called instead of quitting when set (unit tests can't quit their host).
    static var testHook: (() -> Void)?

    static func discardByRelaunching(_ context: ModelContext) {
        context.autosaveEnabled = false
        NSLog("TickyTask: a save failed and can't be undone; restarting to reload the saved data")
        if let testHook { testHook(); return }
        guard !UITestSupport.isHostingUnitTests else { return }
        if !AppRelaunch.startAfterExit(adding: [relaunchArgument]) {
            NSLog("TickyTask: couldn't start the relaunch helper; quitting without saving")
        }
        // `_exit`, not `exit`: no atexit handlers run, so nothing can save the change.
        _exit(0)
    }
}
