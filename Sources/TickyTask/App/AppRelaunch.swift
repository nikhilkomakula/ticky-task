import AppKit

/// Relaunches the app, e.g. so a pending data-folder move can be applied at the next
/// launch (the store is relocated before it's opened).
enum AppRelaunch {
    /// Wait for this instance to fully exit — releasing the store — then relaunch,
    /// so two instances never touch the store at once. Returns false if the helper
    /// couldn't be started; the caller then stays open rather than quitting into
    /// nothing (the pending data move still applies on the next manual launch).
    @discardableResult
    static func now() -> Bool {
        guard startAfterExit() else { return false }
        NSApp.terminate(nil)
        return true
    }

    /// Start a helper that opens the app again once this process has exited, with
    /// this launch's arguments (so an isolated test launch stays isolated) plus
    /// `extra`. The caller must then exit.
    static func startAfterExit(adding extra: [String] = []) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments.dropFirst()
            .filter { $0 != PersistenceRecovery.relaunchArgument } + extra
        let pid = ProcessInfo.processInfo.processIdentifier
        var script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \(quoted(Bundle.main.bundlePath))"
        if !arguments.isEmpty { script += " --args " + arguments.map(quoted).joined(separator: " ") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            return false
        }
        return true
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
