import Testing
import Foundation
@testable import TickyTask

@Suite("Update version comparison")
struct UpdateServiceTests {
    @Test("Strips a leading v")
    func normalize() {
        #expect(UpdateService.normalize("v3.1.0") == "3.1.0")
        #expect(UpdateService.normalize("3.1.0") == "3.1.0")
        #expect(UpdateService.normalize("  v2.0.0 ") == "2.0.0")
    }

    @Test("Detects a newer version")
    func newer() {
        #expect(UpdateService.isNewer("3.1.0", than: "3.0.0"))
        #expect(UpdateService.isNewer("v3.0.1", than: "3.0.0"))
        #expect(UpdateService.isNewer("4.0.0", than: "3.9.9"))
    }

    @Test("Same or older is not newer")
    func notNewer() {
        #expect(!UpdateService.isNewer("3.0.0", than: "3.0.0"))
        #expect(!UpdateService.isNewer("2.9.9", than: "3.0.0"))
        #expect(!UpdateService.isNewer("v3.0.0", than: "3.0.0"))
    }

    @Test("Compares numerically, not lexically")
    func numericOrdering() {
        #expect(UpdateService.isNewer("3.0.10", than: "3.0.9"))   // 10 > 9, not "10" < "9"
        #expect(UpdateService.compare("3.0", "3.0.0") == .orderedSame)
        #expect(UpdateService.compare("3.2.0", "3.10.0") == .orderedAscending)
    }

    @Test("Prerelease tags rank below the matching stable release")
    func prerelease() {
        #expect(!UpdateService.isNewer("1.0.0-beta.1", than: "1.0.0"))  // beta is NOT an update to stable
        #expect(!UpdateService.isNewer("v2.0.0-rc.2", than: "2.0.0"))
        #expect(UpdateService.isNewer("1.0.0", than: "1.0.0-beta"))      // stable > its own prerelease
        #expect(UpdateService.compare("1.0.0-beta", "1.0.0") == .orderedAscending)
        #expect(UpdateService.isNewer("1.1.0-beta", than: "1.0.0"))      // higher core still wins
    }

    // MARK: newestRelease (list selection)

    private func rel(_ tag: String, draft: Bool = false) -> UpdateService.ReleaseInfo {
        UpdateService.ReleaseInfo(tag: tag, urlString: "https://example.com/\(tag)", name: tag, isDraft: draft)
    }

    @Test("Newest release is chosen by version precedence, regardless of list order")
    func newestByVersion() {
        let releases = [rel("v0.1.2"), rel("v0.1.4"), rel("v0.1.3")]
        #expect(UpdateService.newestRelease(from: releases)?.tag == "v0.1.4")
    }

    @Test("Selection considers both stable and pre-releases")
    func newestAcrossReleaseKinds() {
        // GitHub's prerelease *flag* never gates selection — only the version
        // does. A higher-versioned pre-release (plain tag, as this app ships)
        // beats a lower stable one; a SemVer-suffixed prerelease ranks just below
        // its matching stable but above older lines.
        #expect(UpdateService.newestRelease(from: [rel("v0.2.0"), rel("v0.2.1")])?.tag == "v0.2.1")
        #expect(UpdateService.newestRelease(from: [rel("1.0.0"), rel("1.0.0-beta.1")])?.tag == "1.0.0")
        #expect(UpdateService.newestRelease(from: [rel("1.0.0-rc.1"), rel("0.9.9")])?.tag == "1.0.0-rc.1")
    }

    @Test("Drafts are skipped; empty or all-draft yields nil")
    func draftsIgnored() {
        #expect(UpdateService.newestRelease(from: [rel("v0.9.0", draft: true), rel("v0.1.4")])?.tag == "v0.1.4")
        #expect(UpdateService.newestRelease(from: []) == nil)
        #expect(UpdateService.newestRelease(from: [rel("v1.0.0", draft: true)]) == nil)
    }
}
