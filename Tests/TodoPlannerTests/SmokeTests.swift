import Testing
@testable import TodoPlanner

/// Phase 0 smoke test: proves the app module links into the test target and the
/// Swift Testing runner is wired up. Real unit suites (recurrence, backup,
/// legacy import, behaviors) arrive in later phases.
@Suite("Smoke")
struct SmokeTests {
    @Test("App module loads")
    func appModuleLoads() {
        #expect(Bool(true))
    }
}
