import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so TickyTask can launch at login. The system is
/// the source of truth (`status`), so the Settings toggle always reflects the
/// real state — including changes the user makes in System Settings › General ›
/// Login Items. Registration is a no-op error for unsigned dev builds; a
/// signed/installed build registers cleanly.
enum LoginItemService {
    /// Whether the app is currently registered to open at login.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register or unregister, idempotently. Returns whether the resulting state
    /// matches the request (false if the OS refused, e.g. an unsigned build).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return isEnabled == enabled
        } catch {
            // Unsigned/dev builds can't register a login item; surface via `isEnabled`.
            return false
        }
    }

    /// One-time default: enable open-at-login on first run, then leave the user
    /// (and the Settings toggle) in control so we never fight a later opt-out.
    static func applyFirstRunDefaultIfNeeded(defaults: UserDefaults = .standard) {
        let key = "openAtLoginConfigured"
        guard !defaults.bool(forKey: key) else { return }
        // Record the one-time default as done only once it actually registered,
        // so a build that couldn't register (e.g. an unsigned dev build) retries
        // next launch rather than being permanently marked configured.
        if setEnabled(true) {
            defaults.set(true, forKey: key)
        }
    }
}
