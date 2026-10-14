import Testing
import Foundation
@testable import TickyTask

@Suite("SummaryPreferences")
struct SummaryPreferencesTests {
    private func isolatedDefaults() -> (defaults: UserDefaults, name: String) {
        let id = UUID().uuidString
        let name = "SummaryPreferencesTests-\(id)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    @Test("provider defaults to claude")
    func providerDefault() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let prefs = SummaryPreferences(defaults: defaults)
        #expect(prefs.provider == .claude)
    }

    @Test("provider round-trips")
    func providerRoundTrip() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.provider = .codex
        let prefs2 = SummaryPreferences(defaults: defaults)
        #expect(prefs2.provider == .codex)
    }

    @Test("model ID defaults to empty string")
    func modelIDDefault() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let prefs = SummaryPreferences(defaults: defaults)
        #expect(prefs.modelID(for: .claude) == "")
        #expect(prefs.modelID(for: .codex) == "")
    }

    @Test("model IDs per provider independent")
    func modelIDPerProvider() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.setModelID("opus", for: .claude)
        prefs.setModelID("gpt-5.5", for: .codex)

        let prefs2 = SummaryPreferences(defaults: defaults)
        #expect(prefs2.modelID(for: .claude) == "opus")
        #expect(prefs2.modelID(for: .codex) == "gpt-5.5")
    }

    @Test("setModelID trims whitespace")
    func modelIDTrimsWhitespace() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.setModelID("  sonnet  ", for: .claude)
        #expect(prefs.modelID(for: .claude) == "sonnet")
    }

    @Test("setModelID empty removes the key")
    func modelIDEmptyRemoves() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.setModelID("opus", for: .claude)
        prefs.setModelID("", for: .claude)
        #expect(prefs.modelID(for: .claude) == "")
    }

    @Test("effort round-trips per provider and model")
    func effortRoundTrip() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.setEffort(.level("high"), for: .claude, modelID: "opus")
        prefs.setEffort(.modelDefault("medium"), for: .codex, modelID: "gpt-5.5")

        #expect(prefs.effort(for: .claude, modelID: "opus") == .level("high"))
        #expect(prefs.effort(for: .codex, modelID: "gpt-5.5") == .modelDefault("medium"))
    }

    @Test("effort with different models independent")
    func effortPerModel() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.setEffort(.level("low"), for: .claude, modelID: "opus")
        prefs.setEffort(.level("high"), for: .claude, modelID: "sonnet")

        #expect(prefs.effort(for: .claude, modelID: "opus") == .level("low"))
        #expect(prefs.effort(for: .claude, modelID: "sonnet") == .level("high"))
    }

    @Test("cliDefault effort round-trips")
    func cliDefaultEffort() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.setEffort(.cliDefault, for: .claude, modelID: "")
        #expect(prefs.effort(for: .claude, modelID: "") == .cliDefault)
    }

    @Test("corrupt effort JSON returns nil")
    func corruptEffortJSON() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("not valid json", forKey: "weeklySummary.efforts")
        let prefs = SummaryPreferences(defaults: defaults)
        #expect(prefs.effort(for: .claude, modelID: "opus") == nil)
    }

    @Test("custom model IDs per provider")
    func customModelIDs() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.addCustomModelID("model-a", for: .claude)
        prefs.addCustomModelID("model-b", for: .codex)

        #expect(prefs.customModelIDs(for: .claude) == ["model-a"])
        #expect(prefs.customModelIDs(for: .codex) == ["model-b"])
    }

    @Test("custom model IDs most recent first")
    func customModelIDsOrder() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.addCustomModelID("first", for: .claude)
        prefs.addCustomModelID("second", for: .claude)
        prefs.addCustomModelID("third", for: .claude)

        #expect(prefs.customModelIDs(for: .claude) == ["third", "second", "first"])
    }

    @Test("custom model IDs deduplicates")
    func customModelIDsDedupe() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.addCustomModelID("dup", for: .claude)
        prefs.addCustomModelID("dup", for: .claude)

        #expect(prefs.customModelIDs(for: .claude).count == 1)
    }

    @Test("custom model IDs capped at 10")
    func customModelIDsCap() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        for i in 1...15 {
            prefs.addCustomModelID("model-\(i)", for: .claude)
        }

        let ids = prefs.customModelIDs(for: .claude)
        #expect(ids.count == 10)
        #expect(ids[0] == "model-15")  // Most recent first.
    }

    @Test("custom model IDs ignores empty strings")
    func customModelIDsIgnoresEmpty() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.addCustomModelID("", for: .claude)
        prefs.addCustomModelID("   ", for: .claude)
        prefs.addCustomModelID("valid", for: .claude)

        #expect(prefs.customModelIDs(for: .claude) == ["valid"])
    }

    @Test("CLI path override get/set")
    func cliPathOverride() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.setCLIPathOverride("/usr/local/bin/claude", for: .claude)
        #expect(prefs.cliPathOverride(for: .claude) == "/usr/local/bin/claude")
    }

    @Test("CLI path override nil removes key")
    func cliPathOverrideNilRemoves() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.setCLIPathOverride("/usr/local/bin/claude", for: .claude)
        prefs.setCLIPathOverride(nil, for: .claude)
        #expect(prefs.cliPathOverride(for: .claude) == nil)
    }

    @Test("CLI path override empty string returns nil")
    func cliPathOverrideEmptyReturnsNil() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var prefs = SummaryPreferences(defaults: defaults)
        prefs.setCLIPathOverride("   ", for: .claude)
        #expect(prefs.cliPathOverride(for: .claude) == nil)
    }

    @Test("portableKeys excludes CLI paths")
    func portableKeysExcludesPaths() {
        let portableKeys = Set(SummaryPreferences.portableKeys)
        #expect(!portableKeys.contains("weeklySummary.cliPath.claude"))
        #expect(!portableKeys.contains("weeklySummary.cliPath.codex"))
        #expect(portableKeys.contains("weeklySummary.provider"))
        #expect(portableKeys.contains("weeklySummary.model.claude"))
    }
}
