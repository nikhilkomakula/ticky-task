import Testing
import Foundation
@testable import TickyTask

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

/// Records invocations and answers from a closure (thread-safe for concurrent tests).
private final class FakeCLIRunner: CLICommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CLIInvocation] = []
    private let handler: @Sendable (CLIInvocation) async throws -> CLIProcessOutput

    init(handler: @escaping @Sendable (CLIInvocation) async throws -> CLIProcessOutput) {
        self.handler = handler
    }

    var invocations: [CLIInvocation] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput {
        lock.lock(); recorded.append(invocation); lock.unlock()
        return try await handler(invocation)
    }
}

private func output(_ stdout: String, exit: Int32 = 0, stderr: String = "") -> CLIProcessOutput {
    CLIProcessOutput(exitCode: exit, signal: nil, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), duration: .seconds(1))
}

private let catalogJSON = #"{"models":[{"slug":"gpt-6-sol","display_name":"GPT-6-Sol","visibility":"list","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}],"base_instructions":"HUGE-INSTRUCTIONS-BLOB"}]}"#

@Suite("Weekly Summary — model catalog")
struct SummaryModelCatalogTests {
    fileprivate func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("catalog-tests-\(UUID().uuidString)", isDirectory: true)
    }

    fileprivate func catalog(runner: FakeCLIRunner, cache: URL,
                         resolve: @escaping @Sendable () async throws -> URL = { URL(fileURLWithPath: "/opt/homebrew/bin/codex") },
                         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { _ in throw URLError(.cannotConnectToHost) },
                         apiKey: String? = nil) -> SummaryModelCatalog {
        SummaryModelCatalog(runner: runner, resolveExecutable: resolve, environment: { _ in [:] },
                            fetch: fetch, localAPIKey: { apiKey }, cacheDirectory: cache)
    }

    @Test("ChatGPT account lists models via `codex debug models` with the openai provider override")
    func chatGPTCatalog() async throws {
        let runner = FakeCLIRunner { _ in output(catalogJSON) }
        let cache = tempDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let list = try await catalog(runner: runner, cache: cache).models(for: .chatGPTAccount, refresh: false)
        #expect(list.models.map(\.id) == ["", "gpt-6-sol"])
        let args = runner.invocations.first?.arguments ?? []
        #expect(Array(args.prefix(2)) == ["debug", "models"])
        #expect(args.contains(#"model_provider="openai""#))
    }

    @Test("CLI configuration lists models without overriding the provider")
    func cliConfigurationCatalog() async throws {
        let runner = FakeCLIRunner { _ in output(catalogJSON) }
        let cache = tempDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        _ = try await catalog(runner: runner, cache: cache).models(for: .cliConfiguration, refresh: false)
        #expect(runner.invocations.first?.arguments == ["debug", "models"])
    }

    @Test("Codex lists are cached compactly per connection and reused without re-running")
    func compactCache() async throws {
        let runner = FakeCLIRunner { _ in output(catalogJSON) }
        let cache = tempDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let first = catalog(runner: runner, cache: cache)
        _ = try await first.models(for: .chatGPTAccount, refresh: false)
        _ = try await first.models(for: .chatGPTAccount, refresh: false)
        #expect(runner.invocations.count == 1)
        let file = cache.appendingPathComponent("codex-models-chatgpt.json")
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(!contents.contains("HUGE-INSTRUCTIONS-BLOB"))
        // A fresh catalog loads the disk cache without running the CLI.
        let secondRunner = FakeCLIRunner { _ in output(catalogJSON) }
        let second = catalog(runner: secondRunner, cache: cache)
        let list = try await second.models(for: .chatGPTAccount, refresh: false)
        #expect(list.models.map(\.id).contains("gpt-6-sol"))
        #expect(secondRunner.invocations.isEmpty)
        // A different connection does not reuse it.
        _ = try? await second.models(for: .cliConfiguration, refresh: false)
        #expect(secondRunner.invocations.count == 1)
    }

    @Test("A failed refresh returns the last good list marked stale; with no list it throws")
    func staleOnFailure() async throws {
        let cache = tempDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let good = FakeCLIRunner { _ in output(catalogJSON) }
        let catalogA = catalog(runner: good, cache: cache)
        _ = try await catalogA.models(for: .chatGPTAccount, refresh: true)

        let failing = FakeCLIRunner { _ in output("", exit: 1, stderr: "boom") }
        let catalogB = catalog(runner: failing, cache: cache)
        let stale = try await catalogB.models(for: .chatGPTAccount, refresh: true)
        #expect(stale.isStale)
        #expect(stale.models.map(\.id).contains("gpt-6-sol"))

        let empty = tempDirectory()
        await #expect(throws: WeeklySummaryError.self) {
            _ = try await catalog(runner: failing, cache: empty).models(for: .chatGPTAccount, refresh: true)
        }
    }

    @Test("Resolution failures map to cliNotFound / invalidCLIPath")
    func resolutionErrors() async {
        let runner = FakeCLIRunner { _ in output("") }
        let cache = tempDirectory()
        do {
            _ = try await catalog(runner: runner, cache: cache, resolve: { throw CLIResolutionError.notFound(name: "codex") })
                .models(for: .chatGPTAccount, refresh: true)
            Issue.record("expected throw")
        } catch let error as WeeklySummaryError {
            #expect(error == .cliNotFound(.codex))
        } catch { Issue.record("unexpected \(error)") }
        do {
            _ = try await catalog(runner: runner, cache: cache, resolve: { throw CLIResolutionError.invalidOverride(path: "/bad") })
                .models(for: .chatGPTAccount, refresh: true)
            Issue.record("expected throw")
        } catch let error as WeeklySummaryError {
            #expect(error == .invalidCLIPath(.codex, path: "/bad"))
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test("Local servers list models from GET {base}/models, sending the API key as a bearer token")
    func localListing() async throws {
        let runner = FakeCLIRunner { _ in Issue.record("local listing must not run the CLI"); return output("") }
        let cache = tempDirectory()
        let seen = RequestBox()
        let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            seen.set(request)
            let body = Data(#"{"object":"list","data":[{"id":"llama3.1:8b"},{"id":"qwen2.5"},{"id":"llama3.1:8b"}]}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let list = try await catalog(runner: runner, cache: cache, fetch: fetch, apiKey: "sk-local")
            .models(for: .local(server: .ollama, baseURL: nil), refresh: true)
        #expect(list.models.map(\.id) == ["", "llama3.1:8b", "qwen2.5"])
        #expect(seen.request?.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(seen.request?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-local")
    }

    @Test("Local listing failures: 401 → authenticationRejected; unreachable → networkFailure; missing URL → configurationRejected")
    func localFailures() async {
        let runner = FakeCLIRunner { _ in output("") }
        let cache = tempDirectory()
        let unauthorized: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: WeeklySummaryError.self) {
            _ = try await catalog(runner: runner, cache: cache, fetch: unauthorized)
                .models(for: .local(server: .lmStudio, baseURL: nil), refresh: true)
        }
        do {
            _ = try await catalog(runner: runner, cache: cache, fetch: unauthorized)
                .models(for: .local(server: .lmStudio, baseURL: nil), refresh: true)
        } catch let error as WeeklySummaryError {
            if case .authenticationRejected(_, let d) = error { #expect(d.httpStatus == 401) } else { Issue.record("got \(error)") }
        } catch { Issue.record("unexpected \(error)") }
        do {
            _ = try await catalog(runner: runner, cache: cache).models(for: .local(server: .ollama, baseURL: nil), refresh: true)
        } catch let error as WeeklySummaryError {
            if case .networkFailure = error {} else { Issue.record("got \(error)") }
        } catch { Issue.record("unexpected \(error)") }
        do {
            _ = try await catalog(runner: runner, cache: cache).models(for: .local(server: .openAICompatible, baseURL: nil), refresh: true)
        } catch let error as WeeklySummaryError {
            if case .configurationRejected = error {} else { Issue.record("got \(error)") }
        } catch { Issue.record("unexpected \(error)") }
    }
}

extension SummaryModelCatalogTests {
    @Test("A stale list stays marked stale on later reads until a refresh succeeds")
    func staleStaysStale() async throws {
        let cache = tempDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let fails = FailSwitch()
        let runner = FakeCLIRunner { _ in fails.isOn ? output("", exit: 1, stderr: "boom") : output(catalogJSON) }
        let catalog = catalog(runner: runner, cache: cache)
        _ = try await catalog.models(for: .chatGPTAccount, refresh: true)
        fails.isOn = true
        #expect(try await catalog.models(for: .chatGPTAccount, refresh: true).isStale)
        #expect(try await catalog.models(for: .chatGPTAccount, refresh: false).isStale)
        fails.isOn = false
        #expect(try await !catalog.models(for: .chatGPTAccount, refresh: true).isStale)
    }

    @Test("Local listing: HTTP 429 → rateLimited; a non-model-list reply → invalidResponse")
    func localRateLimitAndBadJSON() async {
        let runner = FakeCLIRunner { _ in output("") }
        let cache = tempDirectory()
        let limited: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        }
        let garbage: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            (Data("<html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await catalog(runner: runner, cache: cache, fetch: limited).models(for: .local(server: .ollama, baseURL: nil), refresh: true)
            Issue.record("expected throw")
        } catch let error as WeeklySummaryError {
            if case .rateLimited(_, let detail) = error { #expect(detail.httpStatus == 429) } else { Issue.record("got \(error)") }
        } catch { Issue.record("unexpected \(error)") }
        do {
            _ = try await catalog(runner: runner, cache: cache, fetch: garbage).models(for: .local(server: .ollama, baseURL: nil), refresh: true)
            Issue.record("expected throw")
        } catch let error as WeeklySummaryError {
            if case .invalidResponse = error {} else { Issue.record("got \(error)") }
        } catch { Issue.record("unexpected \(error)") }
    }
}

private final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ request: URLRequest) { lock.lock(); stored = request; lock.unlock() }
}

@Suite("Weekly Summary — catalog release review regressions")
struct SummaryCatalogReleaseReviewTests {
    @Test("Changing a local endpoint fetches that endpoint's models instead of reusing another host's cache")
    func localCatalogFollowsEndpoint() async throws {
        let catalog = SummaryModelCatalog(
            runner: UnexpectedLocalCLIRunner(),
            resolveExecutable: { URL(fileURLWithPath: "/unused/codex") },
            environment: { _ in [:] },
            fetch: { request in
                let host = request.url?.host ?? "missing"
                let data = try JSONSerialization.data(withJSONObject: ["data": [["id": host]]])
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            cacheDirectory: URL(fileURLWithPath: "/unused/local-catalog-cache")
        )
        let first = try await catalog.models(
            for: .local(server: .ollama, baseURL: "http://first.example:11434/v1"), refresh: false)
        #expect(first.models.map(\.id) == ["", "first.example"])

        let second = try await catalog.models(
            for: .local(server: .ollama, baseURL: "http://second.example:11434/v1"), refresh: false)
        #expect(second.models.map(\.id) == ["", "second.example"])
        #expect(second.sourceDescription.contains("second.example"))
    }

    @Test("A local catalog error and its presentation redact credentials embedded in the endpoint URL")
    func localCatalogDiagnosticsRedactEndpointCredentials() async throws {
        let secret = "release-review-credential"
        let target = SummaryConnectionTarget.local(
            server: .openAICompatible,
            baseURL: "https://models.example/v1?token=\(secret)")
        let catalog = SummaryModelCatalog(
            runner: UnexpectedLocalCLIRunner(),
            resolveExecutable: { URL(fileURLWithPath: "/unused/codex") },
            environment: { _ in [:] },
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                               httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            },
            cacheDirectory: URL(fileURLWithPath: "/unused/local-catalog-cache")
        )
        do {
            _ = try await catalog.models(for: target, refresh: true)
            Issue.record("Expected the simulated server failure")
        } catch let failure as WeeklySummaryError {
            let detail = try #require(failure.detail)
            #expect(!detail.message.contains(secret))
            let presentation = SummaryErrorPresenter.present(failure, connection: target)
            #expect(!(presentation.details ?? "").contains(secret))
        }
    }
}

private struct UnexpectedLocalCLIRunner: CLICommandRunning {
    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput {
        Issue.record("Local catalog tests must use their injected HTTP transport exclusively")
        return CLIProcessOutput(exitCode: 1, signal: nil, stdout: Data(), stderr: Data(), duration: .zero)
    }
}
