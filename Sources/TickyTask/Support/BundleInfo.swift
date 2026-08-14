import Foundation

extension Bundle {
    /// Marketing version, e.g. "3.0.0" (CFBundleShortVersionString).
    var appVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—" }
    /// Build number (CFBundleVersion).
    var appBuild: String { (infoDictionary?["CFBundleVersion"] as? String) ?? "—" }
}
