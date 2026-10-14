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
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("catalog-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func catalog(runner: FakeCLIRunner, cache: URL,
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

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ request: URLRequest) { lock.lock(); stored = request; lock.unlock() }
}
