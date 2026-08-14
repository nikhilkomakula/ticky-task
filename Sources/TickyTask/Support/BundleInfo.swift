import Foundation

extension Bundle {
    /// Marketing version (CFBundleShortVersionString) — stamped from the latest
    /// git release tag at build time (see the target's post-build script), e.g. "0.1.0".
    var appVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—" }
    /// Build number (CFBundleVersion).
    var appBuild: String { (infoDictionary?["CFBundleVersion"] as? String) ?? "—" }
}
