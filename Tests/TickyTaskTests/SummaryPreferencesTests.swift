import Testing
import Foundation
@testable import TickyTask

@Suite("Weekly Summary — preferences")
struct SummaryPreferencesTests {
    private func withPreferences(_ body: (SummaryPreferences, UserDefaults) throws -> Void) rethrows {
        let suite = "SummaryPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(SummaryPreferences(defaults: defaults), defaults)
    }

    @Test("Defaults: ChatGPT account, Ollama, blank URL, CLI-default model, no instructions")
    func defaults() {
        withPreferences { prefs, _ in
            #expect(prefs.connectionKind == .chatGPTAccount)
            #expect(prefs.connection == .chatGPTAccount)
            #expect(prefs.localServer == .ollama)
            #expect(prefs.localBaseURL.isEmpty)
            #expect(prefs.modelID(for: .chatGPTAccount).isEmpty)
            #expect(prefs.customInstructions.isEmpty)
            #expect(prefs.cliPathOverride == nil)
        }
    }

    @Test("Connection round-trips, including local server and base URL")
    func connection() {
        withPreferences { prefs, _ in
            prefs.connectionKind = .cliConfiguration
            #expect(prefs.connection == .cliConfiguration)
            prefs.connectionKind = .local
            prefs.localServer = .lmStudio
            #expect(prefs.connection == .local(server: .lmStudio, baseURL: nil))
            prefs.localBaseURL = "  http://10.0.0.5:1234/v1  "
            #expect(prefs.connection == .local(server: .lmStudio, baseURL: "http://10.0.0.5:1234/v1"))
            prefs.localBaseURL = "   "
            #expect(prefs.connection == .local(server: .lmStudio, baseURL: nil))
        }
    }

    @Test("Models, efforts, and custom ids are kept per connection")
    func perConnection() {
        withPreferences { prefs, _ in
            let local = SummaryConnectionTarget.local(server: .ollama, baseURL: nil)
            prefs.setModelID("gpt-6-sol", for: .chatGPTAccount)
            prefs.setModelID("llama3.1:8b", for: local)
            #expect(prefs.modelID(for: .chatGPTAccount) == "gpt-6-sol")
            #expect(prefs.modelID(for: local) == "llama3.1:8b")
            #expect(prefs.modelID(for: .cliConfiguration).isEmpty)

            prefs.setEffort(.level("high"), for: .chatGPTAccount, modelID: "gpt-6-sol")
            prefs.setEffort(.modelDefault("max"), for: .cliConfiguration, modelID: "gpt-6-sol")
            #expect(prefs.effort(for: .chatGPTAccount, modelID: "gpt-6-sol") == .level("high"))
            #expect(prefs.effort(for: .cliConfiguration, modelID: "gpt-6-sol") == .modelDefault("max"))
            #expect(prefs.effort(for: local, modelID: "gpt-6-sol") == nil)

            prefs.addCustomModelID("mine", for: local)
            #expect(prefs.customModelIDs(for: local) == ["mine"])
            #expect(prefs.customModelIDs(for: .chatGPTAccount).isEmpty)

            prefs.setModelID("  ", for: .chatGPTAccount)
            #expect(prefs.modelID(for: .chatGPTAccount).isEmpty)   // blank clears
        }
    }

    @Test("Custom model ids: trimmed, blanks ignored, repeats moved to front, capped at 10")
    func customModels() {
        withPreferences { prefs, _ in
            prefs.addCustomModelID("  a  ", for: .chatGPTAccount)
            prefs.addCustomModelID("", for: .chatGPTAccount)
            prefs.addCustomModelID("b", for: .chatGPTAccount)
            prefs.addCustomModelID("a", for: .chatGPTAccount)
            #expect(prefs.customModelIDs(for: .chatGPTAccount) == ["a", "b"])
            for index in 0..<15 { prefs.addCustomModelID("m\(index)", for: .chatGPTAccount) }
            let ids = prefs.customModelIDs(for: .chatGPTAccount)
            #expect(ids.count == 10)
            #expect(ids.first == "m14")
        }
    }

    @Test("Custom instructions keep their text, clear when blank, and are capped")
    func instructions() {
        withPreferences { prefs, _ in
            prefs.customInstructions = "Write for my manager.\n- Lead with risks."
            #expect(prefs.customInstructions == "Write for my manager.\n- Lead with risks.")
            prefs.customInstructions = "   \n "
            #expect(prefs.customInstructions.isEmpty)
            prefs.customInstructions = String(repeating: "x", count: SummaryPrompt.customInstructionsLimit + 50)
            #expect(prefs.customInstructions.count == SummaryPrompt.customInstructionsLimit)
        }
    }

    @Test("CLI path override sets and clears")
    func cliPath() {
        withPreferences { prefs, _ in
            prefs.cliPathOverride = "/opt/homebrew/bin/codex"
            #expect(prefs.cliPathOverride == "/opt/homebrew/bin/codex")
            prefs.cliPathOverride = ""
            #expect(prefs.cliPathOverride == nil)
        }
    }

    @Test("Corrupt stored values are treated as unset, never crash")
    func corrupt() {
        withPreferences { prefs, defaults in
            defaults.set("{not json", forKey: "weeklySummary.efforts")
            defaults.set("nope", forKey: "weeklySummary.customModels.chatgpt")
            defaults.set("martian", forKey: "weeklySummary.connection")
            defaults.set("toaster", forKey: "weeklySummary.local.server")
            #expect(prefs.effort(for: .chatGPTAccount, modelID: "x") == nil)
            #expect(prefs.customModelIDs(for: .chatGPTAccount).isEmpty)
            #expect(prefs.connectionKind == .chatGPTAccount)
            #expect(prefs.localServer == .ollama)
            // A write after corruption recovers cleanly.
            prefs.setEffort(.level("low"), for: .chatGPTAccount, modelID: "x")
            #expect(prefs.effort(for: .chatGPTAccount, modelID: "x") == .level("low"))
        }
    }

    @Test("Portable keys cover choices + instructions but never the CLI path or API key")
    func portableKeys() {
        let keys = SummaryPreferences.portableKeys
        #expect(keys.contains("weeklySummary.connection"))
        #expect(keys.contains("weeklySummary.instructions"))
        #expect(keys.contains("weeklySummary.efforts"))
        #expect(keys.contains("weeklySummary.model.chatgpt"))
        #expect(keys.contains("weeklySummary.model.local-openAICompatible"))
        #expect(!keys.contains { $0.contains("cliPath") })
        #expect(!keys.contains { $0.lowercased().contains("key") && $0 != "weeklySummary.local.baseURL" })
    }

    @Test("Backup carries Weekly Summary choices and restores only known keys")
    func backupRoundTrip() {
        let suite = "SummaryPreferencesBackup-\(UUID().uuidString)"
        let source = UserDefaults(suiteName: suite)!
        defer { source.removePersistentDomain(forName: suite) }
        let prefs = SummaryPreferences(defaults: source)
        prefs.connectionKind = .local
        prefs.localServer = .lmStudio
        prefs.customInstructions = "Be brief."
        prefs.setModelID("qwen", for: prefs.connection)
        prefs.cliPathOverride = "/secret/path/codex"

        var dto = AppSettingsDTO.capture(from: source)
        #expect(dto.weeklySummary?["weeklySummary.instructions"] == "Be brief.")
        #expect(dto.weeklySummary?.keys.contains("weeklySummary.cliPath.codex") == false)
        dto.weeklySummary?["evil.key"] = "injected"

        let targetSuite = "SummaryPreferencesRestore-\(UUID().uuidString)"
        let target = UserDefaults(suiteName: targetSuite)!
        defer { target.removePersistentDomain(forName: targetSuite) }
        dto.apply(to: target)
        let restored = SummaryPreferences(defaults: target)
        #expect(restored.connection == .local(server: .lmStudio, baseURL: nil))
        #expect(restored.customInstructions == "Be brief.")
        #expect(restored.modelID(for: restored.connection) == "qwen")
        #expect(target.string(forKey: "evil.key") == nil)
        #expect(restored.cliPathOverride == nil)
    }
}
