import Foundation
import Testing
@testable import TickyTask

@Suite("Codex sign-off regressions")
struct CodexSignoffRegressionTests {
    @Test func apiKeyQueryCannotReachPreferencesBackupOrArguments() throws {
        let suite = "CodexSignoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SummaryPreferences(defaults: defaults)
        let secret = "signoff-opaque-query-secret"
        let endpoint = "https://models.example/v1?x-api-key=\(secret)"
        preferences.localBaseURL = endpoint

        #expect(SummaryConnectionArguments.containsCredentials(endpoint))
        #expect(preferences.localBaseURL.isEmpty)
        #expect(!(AppSettingsDTO.capture(from: defaults).weeklySummary?.values.contains(endpoint) ?? false))
        #expect(throws: SummaryConnectionArguments.ValidationError.self) {
            try SummaryConnectionArguments.codexArguments(
                for: .local(server: .openAICompatible, baseURL: endpoint), hasAPIKey: false)
        }
    }

    @Test func legacyCredentialURLIsExcludedFromBackup() throws {
        let suite = "CodexSignoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = "https://user:signoff-legacy-secret@models.example/v1"
        defaults.set(endpoint, forKey: "weeklySummary.local.baseURL")
        #expect(SummaryPreferences(defaults: defaults).localBaseURL.isEmpty)
        #expect(!(AppSettingsDTO.capture(from: defaults).weeklySummary?.values.contains(endpoint) ?? false))
    }

    @Test func backupPreservesCustomInstructionsContainingOrdinaryRoutingURL() throws {
        let suite = "CodexSignoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let instructions = "https://docs.example/?author=Jon"
        SummaryPreferences(defaults: defaults).customInstructions = instructions
        let backup = AppSettingsDTO.capture(from: defaults)
        #expect(backup.weeklySummary?["weeklySummary.instructions"] == instructions)
        AppSettingsDTO(weeklySummary: ["weeklySummary.instructions": instructions]).apply(to: defaults)
        #expect(SummaryPreferences(defaults: defaults).customInstructions == instructions)
    }

    @Test func caseSensitiveEndpointPathsDoNotShareCatalogs() async throws {
        let catalog = SummaryModelCatalog(
            runner: SignoffRunner(), resolveExecutable: { URL(fileURLWithPath: "/unused/codex") },
            environment: { _ in [:] }, fetch: { request in
                let url = request.url!
                let id = url.path.contains("/TenantA/") ? "upper-tenant-model" : "lower-tenant-model"
                return (Data(#"{"data":[{"id":"\#(id)"}]}"#.utf8),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, cacheDirectory: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
        let upper = SummaryConnectionTarget.local(server: .openAICompatible, baseURL: "https://models.example/TenantA/v1")
        let lower = SummaryConnectionTarget.local(server: .openAICompatible, baseURL: "https://models.example/tenanta/v1")
        _ = try await catalog.models(for: upper, refresh: false)
        let list = try await catalog.models(for: lower, refresh: false)
        #expect(list.models.map(\.id).contains("lower-tenant-model"))
        #expect(list.sourceDescription.contains("/tenanta/"))
    }

    @Test func localModelListingPreservesRoutingQuery() throws {
        let request = try LocalModelListing.request(baseURL: "https://models.example/v1?tenant=A", apiKey: nil)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/v1/models")
        #expect(components.queryItems == [URLQueryItem(name: "tenant", value: "A")])
    }

    @Test func localModelListingPreservesEncodedPathSeparators() throws {
        let request = try LocalModelListing.request(baseURL: "https://models.example/team%2Fblue/v1", apiKey: nil)
        #expect(request.url?.absoluteString == "https://models.example/team%2Fblue/v1/models")
    }

    @Test func explicitDefaultLocalAddressOverridesInheritedEndpoint() {
        for server in [SummaryLocalServer.ollama, .lmStudio] {
            let connection = SummaryConnectionTarget.local(server: server, baseURL: nil)
            let inherited = ["CODEX_OSS_BASE_URL": "https://other.example/v1", "CODEX_OSS_PORT": "9191"]
            let environment = inherited.merging(SummaryConnectionArguments.environment(for: connection, apiKey: nil)) { _, new in new }
            #expect(environment["CODEX_OSS_BASE_URL"] == server.defaultBaseURL,
                    "Generation must reach the same explicit default endpoint as the model catalog")
        }
    }

    @Test func suppliedOpaqueKeyIsRemovedFromGeneratorDiagnostics() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("_scratch/codex-dd/signoff-secret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let generator = LiveSummaryGenerator(
            runner: SignoffRunner(), resolveExecutable: { URL(fileURLWithPath: "/unused/codex") },
            environment: { _ in [:] }, localAPIKey: { "signoff-opaque-provider-secret" }, runRoot: root)
        let connection = SummaryConnectionTarget.local(server: .openAICompatible, baseURL: "https://models.example/v1")
        do {
            _ = try await generator.generate(SummaryRequest(instructions: "Summarize.", payload: Data("{}".utf8),
                                                            config: SummaryRunConfig(connection: connection)))
            Issue.record("Expected synthetic authentication failure")
        } catch let failure as WeeklySummaryError {
            guard case .authenticationRejected = failure else {
                Issue.record("Expected synthetic authentication rejection, received \(failure)")
                return
            }
            let details = SummaryErrorPresenter.present(failure, connection: connection).details ?? ""
            #expect(details.contains("Invalid API key provided"))
            #expect(!details.contains("signoff-opaque-provider-secret"))
        }
    }

    @Test func redactionCannotHideTerminalFailureBehindExistingOutput() async throws {
        let root = Self.runRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generator = LiveSummaryGenerator(
            runner: SignoffFailureEventRunner(message: "unexpected status 401 Unauthorized X-API-Key: opaque"),
            resolveExecutable: { URL(fileURLWithPath: "/unused/codex") }, environment: { _ in [:] },
            localAPIKey: { "signoff-configured-key" }, runRoot: root)
        let connection = SummaryConnectionTarget.local(server: .openAICompatible, baseURL: "https://models.example/v1")
        do {
            _ = try await generator.generate(SummaryRequest(instructions: "Summarize.", payload: Data("{}".utf8),
                                                            config: SummaryRunConfig(connection: connection)))
            Issue.record("A terminal failure must override an existing final-message file after redaction")
        } catch let failure as WeeklySummaryError {
            guard case .authenticationRejected = failure else {
                Issue.record("Expected terminal authentication failure, received \(failure)")
                return
            }
        }
    }

    @Test func escapedAndShortSuppliedKeysAreRedactedAfterEventDecoding() async throws {
        let connection = SummaryConnectionTarget.local(server: .openAICompatible, baseURL: "https://models.example/v1")
        for secret in ["signoff-key\"with-quote", "abc"] {
            let root = Self.runRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let generator = LiveSummaryGenerator(
                runner: SignoffFailureEventRunner(message: "Invalid API key provided: \(secret)"),
                resolveExecutable: { URL(fileURLWithPath: "/unused/codex") }, environment: { _ in [:] },
                localAPIKey: { secret }, runRoot: root)
            do {
                _ = try await generator.generate(SummaryRequest(instructions: "Summarize.", payload: Data("{}".utf8),
                                                                config: SummaryRunConfig(connection: connection)))
                Issue.record("Expected synthetic authentication failure")
            } catch let failure as WeeklySummaryError {
                guard case .authenticationRejected = failure else {
                    Issue.record("Expected terminal authentication failure, received \(failure)")
                    continue
                }
                let details = SummaryErrorPresenter.present(failure, connection: connection).details ?? ""
                #expect(!details.contains(secret))
            }
        }
    }

    @Test func suppliedKeyCannotRemainInRequestIDMetadata() async throws {
        let secret = "req_signoffopaqueapikey123"
        let root = Self.runRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generator = LiveSummaryGenerator(
            runner: SignoffFailureEventRunner(message: "Invalid API key provided: \(secret)"),
            resolveExecutable: { URL(fileURLWithPath: "/unused/codex") }, environment: { _ in [:] },
            localAPIKey: { secret }, runRoot: root)
        let connection = SummaryConnectionTarget.local(server: .openAICompatible, baseURL: "https://models.example/v1")
        do {
            _ = try await generator.generate(SummaryRequest(instructions: "Summarize.", payload: Data("{}".utf8),
                                                            config: SummaryRunConfig(connection: connection)))
            Issue.record("Expected synthetic authentication failure")
        } catch let failure as WeeklySummaryError {
            guard case .authenticationRejected = failure else {
                Issue.record("Expected terminal authentication failure, received \(failure)")
                return
            }
            #expect(!(failure.detail?.requestID?.contains(secret) ?? false))
            let details = SummaryErrorPresenter.present(failure, connection: connection).details ?? ""
            #expect(!details.contains(secret), "Known secrets must also be removed from derived request-id metadata")
        }
    }

    @Test func catalogRedactsTheKeyUsedBeforeAnAwait() async throws {
        let keys = SignoffChangingKey()
        let catalog = SummaryModelCatalog(
            runner: SignoffRunner(), resolveExecutable: { URL(fileURLWithPath: "/unused/codex") },
            environment: { _ in [:] }, fetch: { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer signoff-old-provider-secret")
                throw NSError(domain: "CodexSignoff", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid API key provided: signoff-old-provider-secret"])
            }, localAPIKey: { keys.read() }, cacheDirectory: Self.runRoot())
        let connection = SummaryConnectionTarget.local(server: .openAICompatible, baseURL: "https://models.example/v1")
        do {
            _ = try await catalog.models(for: connection, refresh: true)
            Issue.record("Expected synthetic transport failure")
        } catch let failure as WeeklySummaryError {
            #expect(!(failure.detail?.message.contains("signoff-old-provider-secret") ?? false))
        }
    }

    private static func runRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("_scratch/codex-dd/signoff-fixture-\(UUID().uuidString)")
    }

    @MainActor
    @Test func rememberedModelDefaultSurvivesUnavailableCatalog() async throws {
        let suite = "CodexSignoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SummaryPreferences(defaults: defaults)
        preferences.setModelID("remembered-model", for: .chatGPTAccount)
        preferences.setEffort(.modelDefault("medium"), for: .chatGPTAccount, modelID: "remembered-model")
        let session = WeeklySummarySession(weekAnchor: Date(), generator: SignoffGenerator(),
                                           catalog: SignoffUnavailableCatalog(), preferences: preferences)
        #expect(session.effort == .modelDefault("medium"))
        await session.loadModels()
        #expect(session.effort.cliValue == "medium")
        #expect(preferences.effort(for: .chatGPTAccount, modelID: "remembered-model")?.cliValue == "medium")
    }

    @MainActor
    @Test func olderModelLoadCannotReplaceNewerList() async throws {
        let suite = "CodexSignoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = SignoffControlledCatalog()
        let session = WeeklySummarySession(weekAnchor: Date(), generator: SignoffGenerator(), catalog: catalog,
                                           preferences: SummaryPreferences(defaults: defaults))
        let older = Task { await session.loadModels(refresh: true) }
        await catalog.waitForCalls(1)
        let newer = Task { await session.loadModels(refresh: true) }
        await catalog.waitForCalls(2)
        await catalog.complete(1, modelID: "new-list")
        await newer.value
        await catalog.complete(0, modelID: "old-list")
        await older.value
        #expect(session.modelOptions.map(\.id).contains("new-list"))
        #expect(!session.modelOptions.map(\.id).contains("old-list"))
    }
}

private struct SignoffRunner: CLICommandRunning {
    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput {
        let text: String
        let code: Int32
        switch invocation.arguments.first {
        case "--version": (text, code) = ("codex-cli signoff-fixture", 0)
        case "mcp": (text, code) = ("[]", 0)
        case "debug": (text, code) = ("{}", 0)
        default: (text, code) = (#"{"type":"turn.failed","error":{"message":"Invalid API key provided: signoff-opaque-provider-secret"}}"#, 1)
        }
        return CLIProcessOutput(exitCode: code, signal: nil, stdout: Data(text.utf8), stderr: Data(), duration: .zero)
    }
}

private struct SignoffFailureEventRunner: CLICommandRunning {
    let message: String

    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput {
        let text: String
        switch invocation.arguments.first {
        case "--version": text = "codex-cli signoff-fixture"
        case "mcp": text = "[]"
        case "debug": text = "{}"
        default:
            let index = try #require(invocation.arguments.firstIndex(of: "-o"))
            try "Existing draft".write(toFile: invocation.arguments[index + 1], atomically: true, encoding: .utf8)
            let event: [String: Any] = ["type": "turn.failed", "error": ["message": message]]
            text = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        }
        return CLIProcessOutput(exitCode: 0, signal: nil, stdout: Data(text.utf8), stderr: Data(), duration: .zero)
    }
}

private final class SignoffChangingKey: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads == 1 ? "signoff-old-provider-secret" : "signoff-new-provider-secret"
    }
}

private struct SignoffGenerator: SummaryGenerating {
    func generate(_ request: SummaryRequest) async throws -> SummaryResult { throw WeeklySummaryError.cancelled }
}

private struct SignoffUnavailableCatalog: SummaryModelCatalogProviding {
    func models(for connection: SummaryConnectionTarget, refresh: Bool) async throws -> SummaryModelList {
        throw WeeklySummaryError.networkFailure(.codex, SummaryErrorDetail(message: "Synthetic offline fixture"))
    }
}

private actor SignoffControlledCatalog: SummaryModelCatalogProviding {
    private var pending: [CheckedContinuation<SummaryModelList, Error>] = []

    func models(for connection: SummaryConnectionTarget, refresh: Bool) async throws -> SummaryModelList {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func waitForCalls(_ count: Int) async {
        while pending.count < count { await Task.yield() }
    }

    func complete(_ index: Int, modelID: String) {
        pending[index].resume(returning: SummaryModelList(
            models: [.cliDefault, SummaryModelOption(id: modelID, label: modelID, source: .catalog)],
            sourceDescription: modelID))
    }
}
