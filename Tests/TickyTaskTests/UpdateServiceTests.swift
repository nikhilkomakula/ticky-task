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
}
