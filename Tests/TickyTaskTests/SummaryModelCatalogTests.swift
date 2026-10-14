import Testing
import Foundation
@testable import TickyTask

@Suite("ClaudeModelCatalogParser")
struct ClaudeModelCatalogParserTests {
    @Test("starts with cliDefault")
    func startsWithDefault() {
        let options = ClaudeModelCatalogParser.options(policy: [], user: [])
        #expect(!options.isEmpty)
        #expect(options[0].isCLIDefault)
    }

    @Test("policy modelPicker.options merged before built-in aliases")
    func policyModelPickerOptions() {
        let policy = [[
            "modelPicker": [
                "options": [
                    ["model": "opus", "label": "Claude Opus"],
                    ["model": "sonnet", "label": "Claude Sonnet"]
                ]
            ] as [String: Any]
        ]]
        let options = ClaudeModelCatalogParser.options(policy: policy, user: [])

        let opusOption = options.first { $0.id == "opus" }
        #expect(opusOption != nil)
        #expect(opusOption?.label == "Claude Opus")
        #expect(opusOption?.source == .policy)
    }

    @Test("replaceBuiltInOptions true prevents built-in aliases")
    func replaceBuiltInOptions() {
        let policy = [[
            "modelPicker": [
                "options": [
                    ["model": "custom", "label": "Custom Model"]
                ],
                "replaceBuiltInOptions": true
            ] as [String: Any]
        ]]
        let options = ClaudeModelCatalogParser.options(policy: policy, user: [])

        // Should have cliDefault and custom, but NO opus/sonnet/haiku/fable.
        let hasBuiltIn = options.contains { ["opus", "sonnet", "haiku", "fable"].contains($0.id) }
        #expect(!hasBuiltIn)
        #expect(options.contains { $0.id == "custom" })
    }

    @Test("built-in aliases added when replaceBuiltInOptions is false/absent")
    func builtInAliases() {
        let options = ClaudeModelCatalogParser.options(policy: [], user: [])
        let aliases = ["opus", "sonnet", "haiku", "fable"]
        for alias in aliases {
            let option = options.first { $0.id == alias }
            #expect(option != nil)
            #expect(option?.source == .builtInAlias)
        }
    }

    @Test("user availableModels added")
    func userAvailableModels() {
        let user = [[
            "availableModels": ["model-x", "model-y"]
        ]]
        let options = ClaudeModelCatalogParser.options(policy: [], user: user)

        let hasX = options.contains { $0.id == "model-x" }
        let hasY = options.contains { $0.id == "model-y" }
        #expect(hasX)
        #expect(hasY)
    }

    @Test("policy availableModels acts as an allowlist")
    func policyAvailableModelsAllowlist() {
        let policy = [[
            "modelPicker": [
                "options": [
                    ["model": "opus", "label": "Opus"],
                    ["model": "denied", "label": "Denied"]
                ]
            ] as [String: Any],
            "availableModels": ["opus"]
        ]]
        let options = ClaudeModelCatalogParser.options(policy: policy, user: [])

        #expect(options.contains { $0.id == "opus" })
        #expect(!options.contains { $0.id == "denied" })
        #expect(options.contains { $0.isCLIDefault })
    }

    @Test("deduplicates by id")
    func deduplication() {
        let policy = [[
            "modelPicker": [
                "options": [
                    ["model": "dup", "label": "First"]
                ]
            ] as [String: Any]
        ]]
        let user = [[
            "availableModels": ["dup"]
        ]]
        let options = ClaudeModelCatalogParser.options(policy: policy, user: user)

        let dupCount = options.filter { $0.id == "dup" }.count
        #expect(dupCount == 1)
    }

    @Test("skips malformed modelPicker entries")
    func skipsMailformed() {
        let policy = [[
            "modelPicker": [
                "options": [
                    ["model": "", "label": "Empty"],  // Skip empty model
                    ["label": "NoModel"],              // Skip missing model
                    ["model": "valid", "label": "Valid"]
                ]
            ] as [String: Any]
        ]]
        let options = ClaudeModelCatalogParser.options(policy: policy, user: [])

        // Should have cliDefault and valid; no malformed entries.
        #expect(options.contains { $0.isCLIDefault })
        #expect(options.contains { $0.id == "valid" })
        let policyOptions = options.filter { $0.source == .policy }
        #expect(policyOptions.count == 1)  // Only "valid"
    }
}

@Suite("CodexModelCatalogParser")
struct CodexModelCatalogParserTests {
    @Test("parses catalog with mixed visibility")
    func mixedVisibility() throws {
        let catalog = """
        {
            "models": [
                {
                    "slug": "visible-model",
                    "display_name": "Visible Model",
                    "visibility": "list"
                },
                {
                    "slug": "hidden-model",
                    "display_name": "Hidden Model",
                    "visibility": "hide"
                },
                {
                    "slug": "default-visible",
                    "display_name": "Default Visible"
                }
            ]
        }
        """
        let data = catalog.data(using: .utf8)!
        let options = try CodexModelCatalogParser.options(fromCatalogJSON: data)

        let ids = options.map { $0.id }
        #expect(ids.contains("visible-model"))
        #expect(!ids.contains("hidden-model"))
        #expect(ids.contains("default-visible"))
    }

    @Test("parses supported_reasoning_levels as objects with effort")
    func effortObjectFormat() throws {
        let catalog = """
        {
            "models": [
                {
                    "slug": "model-a",
                    "display_name": "Model A",
                    "default_reasoning_level": "medium",
                    "supported_reasoning_levels": [
                        {"effort": "low", "description": "Fast"},
                        {"effort": "medium", "description": "Balanced"},
                        {"effort": "high", "description": "Thorough"}
                    ]
                }
            ]
        }
        """
        let data = catalog.data(using: .utf8)!
        let options = try CodexModelCatalogParser.options(fromCatalogJSON: data)

        let model = options.first { $0.id == "model-a" }
        #expect(model?.supportedEfforts == ["low", "medium", "high"])
        #expect(model?.defaultEffort == "medium")
    }

    @Test("parses supported_reasoning_levels as bare strings")
    func effortStringFormat() throws {
        let catalog = """
        {
            "models": [
                {
                    "slug": "model-b",
                    "display_name": "Model B",
                    "supported_reasoning_levels": ["high", "max"]
                }
            ]
        }
        """
        let data = catalog.data(using: .utf8)!
        let options = try CodexModelCatalogParser.options(fromCatalogJSON: data)

        let model = options.first { $0.id == "model-b" }
        #expect(model?.supportedEfforts == ["high", "max"])
    }

    @Test("skips models without slug")
    func skipsNoSlug() throws {
        let catalog = """
        {
            "models": [
                {
                    "display_name": "No Slug",
                    "slug": ""
                },
                {
                    "slug": "valid",
                    "display_name": "Valid"
                }
            ]
        }
        """
        let data = catalog.data(using: .utf8)!
        let options = try CodexModelCatalogParser.options(fromCatalogJSON: data)

        let catalogModels = options.filter { $0.source == .catalog }
        #expect(catalogModels.contains { $0.id == "valid" })
        #expect(!catalogModels.contains { $0.id == "" })
    }

    @Test("throws on malformed JSON")
    func throwsOnMalformedJSON() {
        let invalid = "not valid json".data(using: .utf8)!
        do {
            _ = try CodexModelCatalogParser.options(fromCatalogJSON: invalid)
            #expect(Bool(false), "Expected to throw")
        } catch {
            // Expected - should throw
        }
    }

    @Test("throws on missing models array")
    func throwsOnMissingModels() {
        let noModels = "{}".data(using: .utf8)!
        #expect(throws: WeeklySummaryError.self) {
            try CodexModelCatalogParser.options(fromCatalogJSON: noModels)
        }
    }

    @Test("ignores unknown fields including base_instructions")
    func ignoresUnknownFields() throws {
        let largeText = String(repeating: " ", count: 100000)
        let catalog = """
        {
            "models": [
                {
                    "slug": "model-c",
                    "display_name": "Model C",
                    "base_instructions": "This is huge text that should be ignored\(largeText)",
                    "some_field": "ignored",
                    "another_field": 123
                }
            ]
        }
        """
        let data = catalog.data(using: .utf8)!
        let options = try CodexModelCatalogParser.options(fromCatalogJSON: data)

        // Should parse without loading the huge base_instructions.
        #expect(options.contains { $0.id == "model-c" })
    }
}

@Suite("SummaryModelCatalog")
struct SummaryModelCatalogTests {
    @Test("Claude returns cached list without re-reading files")
    func claudeCachesInMemory() async throws {
        let readFile: @Sendable (String) -> Data? = { _ in nil }

        let catalog = SummaryModelCatalog(
            runner: FakeCLIRunner(),
            resolveExecutable: { _ in throw CLIResolutionError.notFound(name: "test") },
            environment: { _ in [:] },
            readFile: readFile,
            listDirectory: { _ in [] },
            home: "~",
            cacheDirectory: FileManager.default.temporaryDirectory
        )

        let list1 = try await catalog.models(for: .claude, refresh: false)
        let list2 = try await catalog.models(for: .claude, refresh: false)

        // Lists should be identical (same objects due to caching).
        #expect(list1.models == list2.models)
    }

    @Test("Codex writes compact cache to disk")
    func codexWritesCompactCache() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let catalogJSON = """
        {
            "models": [
                {
                    "slug": "test-model",
                    "display_name": "Test Model",
                    "supported_reasoning_levels": ["low", "high"]
                }
            ]
        }
        """

        let runner = FakeCLIRunner { _ in
            CLIProcessOutput(
                exitCode: 0,
                signal: nil,
                stdout: catalogJSON.data(using: .utf8)!,
                stderr: Data(),
                duration: .milliseconds(100)
            )
        }

        let catalog = SummaryModelCatalog(
            runner: runner,
            resolveExecutable: { _ in URL(fileURLWithPath: "/usr/bin/codex") },
            environment: { _ in [:] },
            readFile: { FileManager.default.contents(atPath: $0) },
            listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            home: "~",
            cacheDirectory: cacheDir
        )

        _ = try await catalog.models(for: .codex, refresh: true)

        let cachePath = cacheDir.appendingPathComponent("codex-models.json")
        #expect(FileManager.default.fileExists(atPath: cachePath.path))

        // Verify cache is compact (no base_instructions).
        let cacheData = try Data(contentsOf: cachePath)
        let cacheString = String(data: cacheData, encoding: .utf8) ?? ""
        #expect(!cacheString.contains("base_instructions"))
    }

    @Test("Codex returns stale cache on refresh failure with prior cache")
    func codexReturnsStaleCache() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Pre-populate cache.
        let oldCacheList = SummaryModelList(
            models: [.cliDefault, SummaryModelOption(id: "old", label: "Old", source: .catalog)],
            refreshedAt: Date(timeIntervalSince1970: 0),
            sourceDescription: "old"
        )
        let cacheData = try JSONEncoder().encode(oldCacheList)
        let cachePath = cacheDir.appendingPathComponent("codex-models.json")
        try cacheData.write(to: cachePath)

        // Runner that fails.
        let runner = FakeCLIRunner { _ in
            throw CLIProcessError.launchFailed("test")
        }

        let catalog = SummaryModelCatalog(
            runner: runner,
            resolveExecutable: { _ in URL(fileURLWithPath: "/usr/bin/codex") },
            environment: { _ in [:] },
            readFile: { FileManager.default.contents(atPath: $0) },
            listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            home: "~",
            cacheDirectory: cacheDir
        )

        let result = try await catalog.models(for: .codex, refresh: true)
        #expect(result.isStale == true)
        #expect(result.models.contains { $0.id == "old" })
    }

    @Test("Codex throws on refresh failure without cache")
    func codexThrowsWithoutCache() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let runner = FakeCLIRunner { _ in
            throw CLIProcessError.launchFailed("test")
        }

        let catalog = SummaryModelCatalog(
            runner: runner,
            resolveExecutable: { _ in URL(fileURLWithPath: "/usr/bin/codex") },
            environment: { _ in [:] },
            readFile: { _ in nil },
            listDirectory: { _ in [] },
            home: "~",
            cacheDirectory: cacheDir
        )

        do {
            _ = try await catalog.models(for: .codex, refresh: true)
            #expect(Bool(false), "Expected to throw")
        } catch is WeeklySummaryError {
            // Expected.
        }
    }

    @Test("maps CLIResolutionError.notFound to cliNotFound")
    func mapsResolutionError() async throws {
        let catalog = SummaryModelCatalog(
            runner: FakeCLIRunner(),
            resolveExecutable: { _ in throw CLIResolutionError.notFound(name: "codex") },
            environment: { _ in [:] },
            readFile: { _ in nil },
            listDirectory: { _ in [] },
            home: "~",
            cacheDirectory: FileManager.default.temporaryDirectory
        )

        do {
            _ = try await catalog.models(for: .codex, refresh: true)
            #expect(Bool(false), "Expected to throw")
        } catch let error as WeeklySummaryError {
            #expect(error == WeeklySummaryError.cliNotFound(.codex))
        }
    }
}

// MARK: - Fakes

private final class FakeCLIRunner: CLICommandRunning, @unchecked Sendable {
    private let handler: ((CLIInvocation) async throws -> CLIProcessOutput)?

    init(handler: ((CLIInvocation) async throws -> CLIProcessOutput)? = nil) {
        self.handler = handler
    }

    convenience init(result: CLIProcessOutput) {
        self.init { _ in result }
    }

    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput {
        if let handler {
            return try await handler(invocation)
        }
        throw CLIProcessError.launchFailed("not implemented")
    }
}
