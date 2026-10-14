import Testing
import Foundation
@testable import TickyTask

@Suite("Weekly Summary — release generator isolation")
struct SummaryGeneratorReleaseReviewTests {
    private func generator(runner: ReleaseGeneratorRunner, root: URL) -> LiveSummaryGenerator {
        LiveSummaryGenerator(runner: runner,
                             resolveExecutable: { URL(fileURLWithPath: "/synthetic/codex") },
                             environment: { _ in ["PATH": "/usr/bin:/bin"] },
                             localAPIKey: { "release-review-opaque-key" }, runRoot: root)
    }

    private func runRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("summary-generator-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Generation carries every isolation flag, private stdin and account override")
    func successfulAccountGeneration() async throws {
        let root = try runRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ReleaseGeneratorRunner()
        let live = generator(runner: runner, root: root)
        let request = SummaryRequest(instructions: SummaryPrompt.instructions, payload: Data("{}".utf8),
                                     config: SummaryRunConfig(modelID: nil, effort: nil))
        let result = try await live.generate(request)
        #expect(result.text == "Synthetic summary")
        let calls = await runner.invocations
        #expect(calls.map { Array($0.arguments.prefix(2)) } == [["--version"], ["mcp", "list"], ["debug", "prompt-input"], ["exec", "--json"]])
        let exec = try #require(calls.last)
        #expect(exec.arguments.contains(#"model_provider="openai""#))
        for feature in CodexSummaryAdapter.disabledFeatures {
            #expect(zip(exec.arguments, exec.arguments.dropFirst()).contains { $0 == "--disable" && $1 == feature })
        }
        #expect(exec.arguments.contains("mcp_servers.synthetic.enabled=false"))
        #expect(exec.arguments.contains(#"web_search="disabled""#))
        #expect(exec.arguments.contains("--ephemeral"))
        #expect(zip(exec.arguments, exec.arguments.dropFirst()).contains { $0 == "-s" && $1 == "read-only" })
        #expect(exec.stdin == SummaryPrompt.codexStdin(instructions: request.instructions, payload: request.payload))
        #expect(exec.timeout == .seconds(300))
        #expect(exec.environment[SummaryConnectionArguments.apiKeyVariable] == nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    @Test("A failed isolation preflight never reaches exec")
    func preflightFailureStopsExec() async throws {
        let root = try runRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ReleaseGeneratorRunner(preflightExit: 1)
        do {
            _ = try await generator(runner: runner, root: root).generate(
                SummaryRequest(instructions: "instruction", payload: Data("{}".utf8), config: SummaryRunConfig(modelID: nil, effort: nil)))
            Issue.record("Expected isolation preflight rejection")
        } catch let failure as WeeklySummaryError {
            if case .cliIncompatible = failure {} else { Issue.record("Unexpected failure: \(failure)") }
        }
        #expect(await runner.invocations.allSatisfy { $0.arguments.first != "exec" })
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    @Test("Malformed successful MCP output must fail closed before exec")
    func malformedMCPEnumerationStopsExec() async throws {
        let root = try runRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ReleaseGeneratorRunner(mcpJSON: #"{"unexpected_schema":[{"name":"synthetic"}]}"#)
        do {
            _ = try await generator(runner: runner, root: root).generate(
                SummaryRequest(instructions: "instruction", payload: Data("{}".utf8), config: SummaryRunConfig(modelID: nil, effort: nil)))
            Issue.record("Malformed enumeration was accepted and a potentially unisolated exec launched")
        } catch let failure as WeeklySummaryError {
            if case .cliIncompatible = failure {} else { Issue.record("Unexpected failure: \(failure)") }
        }
        #expect(await runner.invocations.allSatisfy { $0.arguments.first != "exec" })
    }

    @Test("OpenAI-compatible credentials remain in child environment")
    func localCredentialTransport() async throws {
        let root = try runRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ReleaseGeneratorRunner()
        let config = SummaryRunConfig(connection: .local(server: .openAICompatible, baseURL: "http://models.example/v1"), modelID: "model", effort: "high")
        _ = try await generator(runner: runner, root: root).generate(SummaryRequest(instructions: "instruction", payload: Data("{}".utf8), config: config))
        let calls = await runner.invocations
        let exec = try #require(calls.last)
        #expect(exec.environment[SummaryConnectionArguments.apiKeyVariable] == "release-review-opaque-key")
        #expect(!exec.arguments.contains { $0.contains("release-review-opaque-key") })
        #expect(exec.arguments.contains { $0.contains(#"env_key="TICKYTASK_LOCAL_API_KEY""#) })
    }

    @Test("Opaque API-key header values are redacted")
    func opaqueAPIKeyHeaderIsRedacted() {
        let redacted = SummaryRedactor.redact("HTTP 401 X-API-Key: release-review-opaque-key")
        #expect(!redacted.contains("release-review-opaque-key"))
    }

    @Test("URL userinfo credentials are redacted")
    func urlUserinfoIsRedacted() {
        let redacted = SummaryRedactor.redact("Cannot connect to https://user:release-review-password@models.example/v1")
        #expect(!redacted.contains("release-review-password"))
    }
}

private actor ReleaseGeneratorRunner: CLICommandRunning {
    private(set) var invocations: [CLIInvocation] = []
    let mcpJSON: String
    let preflightExit: Int32

    init(mcpJSON: String = #"[{"name":"synthetic"}]"#, preflightExit: Int32 = 0) {
        self.mcpJSON = mcpJSON
        self.preflightExit = preflightExit
    }

    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput {
        invocations.append(invocation)
        var stdout = ""
        var stderr = ""
        var exit: Int32 = 0
        switch invocation.arguments.first {
        case "--version": stdout = "codex-cli synthetic-review"
        case "mcp": stdout = mcpJSON
        case "debug":
            exit = preflightExit
            if exit != 0 { stderr = "Error: Unknown feature flag: shell_tool" }
        case "exec":
            let index = try #require(invocation.arguments.firstIndex(of: "-o"))
            try "Synthetic summary".write(toFile: invocation.arguments[index + 1], atomically: true, encoding: .utf8)
            stdout = #"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}"#
        default: Issue.record("Unexpected invocation")
        }
        return CLIProcessOutput(exitCode: exit, signal: nil, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), duration: .milliseconds(1))
    }
}

/// Fixtures captured from the real Codex CLI on 2026-10-14 (codex
/// 0.162.1, Databricks AI gateway). Anything marked SYNTHETIC is a documented
/// error form we could not induce on that machine.
private enum Fixture {
    static let codex401 = #"""
    {"type":"thread.started","thread_id":"t1"}
    {"type":"turn.started"}
    {"type":"error","message":"Reconnecting... 1/5 (unexpected status 401 Unauthorized: {\"error_code\":401,\"message\":\"Credential was not sent or was of an unsupported type for this API. [ReqId: d38cce76-98bf-4d32-a700-29e83122c8b1]\"}, url: https://dbc-a5d4177a-49dc.cloud.databricks.com/ai-gateway/codex/v1/responses, request id: d38cce76-98bf-4d32-a700-29e83122c8b1)"}
    {"type":"error","message":"unexpected status 401 Unauthorized: {\"error_code\":401,\"message\":\"Credential was not sent or was of an unsupported type for this API. [ReqId: d38cce76-98bf-4d32-a700-29e83122c8b1]\"}, url: https://dbc-a5d4177a-49dc.cloud.databricks.com/ai-gateway/codex/v1/responses, request id: d38cce76-98bf-4d32-a700-29e83122c8b1"}
    {"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: {\"error_code\":401,\"message\":\"Credential was not sent or was of an unsupported type for this API. [ReqId: d38cce76-98bf-4d32-a700-29e83122c8b1]\"}, url: https://dbc-a5d4177a-49dc.cloud.databricks.com/ai-gateway/codex/v1/responses, request id: d38cce76-98bf-4d32-a700-29e83122c8b1"}}
    """#

    static let codex404 = #"""
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `not-a-real-model` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."}}
    {"type":"error","message":"Reconnecting... 1/5 (unexpected status 404 Not Found: {\"error_code\":\"NOT_FOUND\",\"message\":\"'not-a-real-model' does not exist.\"}, url: https://dbc-a5d4177a-49dc.cloud.databricks.com/ai-gateway/codex/v1/responses, request id: f8a94596-10a4-4e06-84b6-bcd43c6ab659)"}
    {"type":"turn.failed","error":{"message":"unexpected status 404 Not Found: {\"error_code\":\"NOT_FOUND\",\"message\":\"'not-a-real-model' does not exist.\"}, url: https://dbc-a5d4177a-49dc.cloud.databricks.com/ai-gateway/codex/v1/responses, request id: 75d33e59-2005-4663-a215-45eb321b0f58"}}
    """#

    static let codexSuccess = #"""
    {"type":"thread.started","thread_id":"t1"}
    {"type":"turn.started"}
    {"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion)"}
    {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Summary"}}
    {"type":"turn.completed","usage":{"input_tokens":22695,"cached_input_tokens":0,"output_tokens":120}}
    """#

    static let codexUnknownFeatureStderr = "Error: Unknown feature flag: not_a_real_feature\n"

}

private func output(stdout: String, stderr: String = "", exit: Int32?) -> CLIProcessOutput {
    CLIProcessOutput(exitCode: exit, signal: nil, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8),
                     duration: .seconds(3))
}

private let codexConfig = SummaryRunConfig(connection: .chatGPTAccount, modelID: "gpt-5.5", effort: "low")

@Suite("Weekly Summary — Codex adapter")
struct CodexSummaryAdapterTests {
    @Test("REAL 401: terminal turn.failed → authenticationRejected with status + request id")
    func real401() {
        let result = CodexSummaryAdapter.parse(output(stdout: Fixture.codex401, exit: 1), lastMessage: "",
                                               config: codexConfig, cliVersion: "0.162.1", executablePath: "/opt/homebrew/bin/codex")
        guard case .failure(.authenticationRejected(.codex, let detail)) = result else {
            Issue.record("expected authenticationRejected, got \(result)"); return
        }
        #expect(detail.httpStatus == 401)
        #expect(detail.requestID == "d38cce76-98bf-4d32-a700-29e83122c8b1")
        #expect(detail.exitCode == 1)
        #expect(detail.cliVersion == "0.162.1")
    }

    @Test("REAL 404: model does not exist → modelUnavailable (not five reconnect errors)")
    func real404() {
        let result = CodexSummaryAdapter.parse(output(stdout: Fixture.codex404, exit: 1), lastMessage: nil,
                                               config: SummaryRunConfig(connection: .cliConfiguration, modelID: "not-a-real-model", effort: nil),
                                               cliVersion: nil, executablePath: nil)
        guard case .failure(.modelUnavailable(.codex, let model, let detail)) = result else {
            Issue.record("expected modelUnavailable, got \(result)"); return
        }
        #expect(model == "not-a-real-model")
        #expect(detail.httpStatus == 404)
        #expect(detail.message.hasPrefix("unexpected status 404"))
    }

    @Test("REAL unknown feature flag on stderr → cliIncompatible")
    func realUnknownFeature() {
        let result = CodexSummaryAdapter.parse(output(stdout: "", stderr: Fixture.codexUnknownFeatureStderr, exit: 1),
                                               lastMessage: nil, config: codexConfig, cliVersion: nil, executablePath: nil)
        guard case .failure(.cliIncompatible(.codex, let detail)) = result else {
            Issue.record("expected cliIncompatible, got \(result)"); return
        }
        #expect(detail.message.contains("not_a_real_feature"))
    }

    @Test("Intermediate reconnect errors followed by success are not a failure")
    func reconnectThenSuccess() {
        let result = CodexSummaryAdapter.parse(output(stdout: Fixture.codexSuccess, exit: 0), lastMessage: "  Summary text \n",
                                               config: codexConfig, cliVersion: nil, executablePath: nil)
        guard case .success(let summary) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(summary.text == "Summary text")
        #expect(summary.usage?.inputTokens == 22695)
        #expect(summary.usage?.outputTokens == 120)
    }

    @Test("Exit 0 with a blank -o file → emptyResponse")
    func blankFinalMessage() {
        let result = CodexSummaryAdapter.parse(output(stdout: Fixture.codexSuccess, exit: 0), lastMessage: "   ",
                                               config: codexConfig, cliVersion: nil, executablePath: nil)
        #expect(result == .failure(.emptyResponse(.codex)))
    }

    @Test("A terminal failure overrides apparent output, and non-zero exit never succeeds")
    func failureOverridesOutput() {
        let failed = Fixture.codexSuccess + "\n" + #"{"type":"turn.failed","error":{"message":"stream error: connection refused"}}"#
        let a = CodexSummaryAdapter.parse(output(stdout: failed, exit: 0), lastMessage: "Looks fine",
                                          config: codexConfig, cliVersion: nil, executablePath: nil)
        if case .failure(.networkFailure) = a {} else { Issue.record("expected networkFailure, got \(a)") }
        let b = CodexSummaryAdapter.parse(output(stdout: Fixture.codexSuccess, stderr: "boom", exit: 2), lastMessage: "Looks fine",
                                          config: codexConfig, cliVersion: nil, executablePath: nil)
        if case .failure(.cliFailed(.codex, let d)) = b { #expect(d.exitCode == 2) } else { Issue.record("expected cliFailed, got \(b)") }
    }

    @Test("Arguments: text-only isolation, MCP servers disabled, model/effort as single values, stdin prompt")
    func arguments() throws {
        let args = try CodexSummaryAdapter.arguments(
            config: SummaryRunConfig(connection: .cliConfiguration, modelID: "gpt-6-sol; rm -rf ~", effort: "xhigh"),
            lastMessagePath: "/tmp/run/last.txt", mcpServerNames: ["jira", "chrome-devtools", "odd name"]
        )
        #expect(Array(args.prefix(8)) == ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "--color", "never"])
        for feature in CodexSummaryAdapter.disabledFeatures {
            let ok = zip(args, args.dropFirst()).contains { $0 == "--disable" && $1 == feature }
            #expect(ok, "missing --disable \(feature)")
        }
        #expect(args.contains(#"web_search="disabled""#))
        #expect(args.contains("mcp_servers.jira.enabled=false"))
        #expect(args.contains("mcp_servers.chrome-devtools.enabled=false"))
        #expect(args.contains(#"mcp_servers."odd name".enabled=false"#))
        // The model id is one argv element (never shell-interpolated).
        let modelIndex = args.firstIndex(of: "-m")
        #expect(modelIndex.map { args[$0 + 1] } == "gpt-6-sol; rm -rf ~")
        #expect(args.contains(#"model_reasoning_effort="xhigh""#))
        #expect(Array(args.suffix(3)) == ["-o", "/tmp/run/last.txt", "-"])
    }

    @Test("CLI-default model and effort omit their flags; unsafe effort tokens are dropped")
    func defaultsOmitted() throws {
        let args = try CodexSummaryAdapter.arguments(config: SummaryRunConfig(connection: .cliConfiguration, modelID: nil, effort: nil),
                                                 lastMessagePath: "/x", mcpServerNames: [])
        #expect(!args.contains("-m"))
        #expect(!args.contains { $0.hasPrefix("model_reasoning_effort") })
        let unsafe = try CodexSummaryAdapter.arguments(config: SummaryRunConfig(connection: .cliConfiguration, modelID: nil, effort: #"high" evil="1"#),
                                                   lastMessagePath: "/x", mcpServerNames: [])
        #expect(!unsafe.contains { $0.hasPrefix("model_reasoning_effort") })
    }

    @Test("Preflight checks the same isolation flags without calling a model")
    func preflight() {
        let args = CodexSummaryAdapter.preflightArguments(mcpServerNames: ["slack"])
        #expect(Array(args.prefix(2)) == ["debug", "prompt-input"])
        #expect(args.contains("mcp_servers.slack.enabled=false"))
        #expect(args.last == "ping")
    }

    @Test("MCP server names parse from an array or a servers object; junk yields none")
    func mcpNames() {
        let array = Data(#"[{"name":"jira","enabled":true},{"name":"slack"},{"name":"jira"},{"enabled":true}]"#.utf8)
        #expect(CodexSummaryAdapter.mcpServerNames(fromListJSON: array) == ["jira", "slack"])
        let object = Data(#"{"servers":[{"name":"glean"}]}"#.utf8)
        #expect(CodexSummaryAdapter.mcpServerNames(fromListJSON: object) == ["glean"])
        #expect(CodexSummaryAdapter.mcpServerNames(fromListJSON: Data("nope".utf8)).isEmpty)
    }
}

@Suite("Weekly Summary — error classifier & presenter")
struct SummaryErrorClassifierTests {
    private func kind(_ message: String, _ provider: SummaryProvider = .codex) -> WeeklySummaryError {
        SummaryErrorClassifier.classify(message: message, provider: provider, model: "m", exitCode: 1)
    }

    @Test("Classification by status code and wording")
    func classes() {
        func is_(_ e: WeeklySummaryError, _ check: (WeeklySummaryError) -> Bool) -> Bool { check(e) }
        if case .notSignedIn = kind("Not logged in · Please run /login") {} else { Issue.record("notSignedIn") }
        if case .authenticationRejected = kind("API Error: 401 authentication_error") {} else { Issue.record("401") }
        if case .authenticationRejected = kind("Invalid API key · Please run /login") {} else { Issue.record("invalid key beats /login") }
        if case .authHelperFailed = kind("apiKeyHelper failed: exited with code 1") {} else { Issue.record("helper") }
        if case .accessDenied = kind("unexpected status 403 Forbidden") {} else { Issue.record("403") }
        if case .rateLimited = kind("API Error: 429 rate_limit_error") {} else { Issue.record("429") }
        if case .providerUnavailable = kind("API Error: 529 overloaded_error") {} else { Issue.record("529") }
        if case .providerUnavailable = kind("unexpected status 502 Bad Gateway") {} else { Issue.record("502") }
        if case .networkFailure = kind("Connection error: getaddrinfo ENOTFOUND gateway.example") {} else { Issue.record("network") }
        if case .cliIncompatible = kind("error: unknown option '--safe-mode'") {} else { Issue.record("incompatible") }
        if case .configurationRejected = kind("Invalid value for --effort: turbo") {} else { Issue.record("config") }
        if case .cliFailed = kind("something odd happened") {} else { Issue.record("fallback") }
    }

    @Test("A bare 404 without a model mention is not mislabelled as a model problem")
    func bare404() {
        if case .modelUnavailable = kind("unexpected status 404 Not Found: route /v2/foo endpoint missing", .codex) {
            Issue.record("bare 404 must not be modelUnavailable")
        }
    }

    @Test("Status and request-id extraction")
    func extraction() {
        #expect(SummaryErrorClassifier.httpStatus(in: "unexpected status 401 Unauthorized") == 401)
        #expect(SummaryErrorClassifier.httpStatus(in: "API Error: 429 {}") == 429)
        #expect(SummaryErrorClassifier.httpStatus(in: #"{"error_code":403}"#) == 403)
        #expect(SummaryErrorClassifier.httpStatus(in: "no status here, 2026 notes") == nil)
        #expect(SummaryErrorClassifier.requestID(in: "x, request id: 75d33e59-2005-4663-a215-45eb321b0f58") == "75d33e59-2005-4663-a215-45eb321b0f58")
        #expect(SummaryErrorClassifier.requestID(in: "[ReqId: d38cce76-98bf]") == "d38cce76-98bf")
        #expect(SummaryErrorClassifier.requestID(in: #"{"request_id":"req_abc123XYZ890"}"#) == "req_abc123XYZ890")
    }

    @Test("Credentials are redacted from diagnostics; request ids survive")
    func redaction() {
        let raw = """
        Authorization: Bearer abc.def.ghi
        x-api-key=sk-ant-REALSECRET1234567890
        token dapi0123456789abcdef0123 used
        https://gw.example.com/v1?token=s3cr3t&model=x
        {"api_key":"hunter2"} request id: 75d33e59-2005-4663
        """
        let redacted = SummaryRedactor.redact(raw)
        for secret in ["abc.def.ghi", "REALSECRET", "dapi0123456789abcdef0123", "s3cr3t", "hunter2"] {
            #expect(!redacted.contains(secret), "leaked \(secret)")
        }
        #expect(redacted.contains("request id: 75d33e59-2005-4663"))
        #expect(redacted.contains("model=x"))
        let detail = kind(raw).detail
        #expect(detail.map { !$0.message.contains("hunter2") } == true)
    }

    @Test("Auth remediation follows the connection and setup")
    func authRemediation() {
        let error = WeeklySummaryError.authenticationRejected(.codex, SummaryErrorDetail(message: "401", httpStatus: 401))
        let gateway = SummaryErrorPresenter.present(error, authSetup: .customProvider(name: "Databricks"))
        #expect(gateway.title == "Codex authentication was rejected (401)")
        #expect(gateway.message.contains("custom provider or credential helper from your Codex configuration (Databricks)"))
        #expect(gateway.message.contains("ChatGPT account"))
        let account = SummaryErrorPresenter.present(error, authSetup: .accountLogin)
        #expect(account.message.contains("`codex login`"))
        #expect(account.message.contains("Settings › AI"))
        #expect(!account.message.contains("custom provider"))
        let local = SummaryErrorPresenter.present(error, connection: .local(server: .ollama, baseURL: nil))
        #expect(local.message.contains("API key"))
        let offline = SummaryErrorPresenter.present(.networkFailure(.codex, SummaryErrorDetail(message: "refused")),
                                                    connection: .local(server: .lmStudio, baseURL: nil))
        #expect(offline.message.contains("LM Studio is running"))
        #expect(offline.message.contains("http://localhost:1234/v1"))
    }

    @Test("Every error has a title and remediation; details carry the diagnostics")
    func presentationCoverage() {
        let d = SummaryErrorDetail(message: "raw message", exitCode: 1, httpStatus: 500, requestID: "req_1", cliVersion: "1.0", executablePath: "/bin/x")
        let all: [WeeklySummaryError] = [
            .cliNotFound(.codex), .invalidCLIPath(.codex, path: "/nope"), .launchFailed(.codex, d), .cancelled,
            .timedOut(seconds: 300), .inputTooLarge(bytes: 300_000, limit: 262_144), .notSignedIn(.codex, d),
            .authenticationRejected(.codex, d), .authHelperFailed(.codex, d), .accessDenied(.codex, d),
            .modelUnavailable(.codex, model: "x", d), .configurationRejected(.codex, d), .rateLimited(.codex, d),
            .providerUnavailable(.codex, d), .networkFailure(.codex, d), .cliIncompatible(.codex, d),
            .invalidResponse(.codex, d), .emptyResponse(.codex), .cliFailed(.codex, d),
        ]
        for error in all {
            let p = SummaryErrorPresenter.present(error)
            #expect(!p.title.isEmpty && !p.message.isEmpty, "\(error)")
        }
        let details = SummaryErrorPresenter.present(.cliFailed(.codex, d)).details ?? ""
        for piece in ["raw message", "HTTP status: 500", "Request ID: req_1", "Exit code: 1", "CLI version: 1.0", "Executable: /bin/x"] {
            #expect(details.contains(piece))
        }
        #expect(SummaryErrorPresenter.present(.cliNotFound(.codex)).message.contains("Settings › AI"))
    }

    @Test("Codex auth setup detection from config.toml")
    func authSetup() {
        #expect(SummaryAuthSetup.codex(configTOML: "model = \"x\"\nmodel_provider = \"Databricks\"\n[model_providers.Databricks]\n")
                == .customProvider(name: "Databricks"))
        #expect(SummaryAuthSetup.codex(configTOML: "model_provider = \"openai\"") == .accountLogin)
        #expect(SummaryAuthSetup.codex(configTOML: "[profiles.x]\nmodel_provider = \"Other\"") == .accountLogin)
        #expect(SummaryAuthSetup.codex(configTOML: nil) == .unknown)
    }
}

@Suite("Weekly Summary — Codex connections")
struct SummaryConnectionTests {
    @Test("ChatGPT account overrides the provider; CLI configuration adds nothing")
    func accountAndCLI() throws {
        #expect(try SummaryConnectionArguments.codexArguments(for: .chatGPTAccount, hasAPIKey: false)
                == ["-c", #"model_provider="openai""#])
        #expect(try SummaryConnectionArguments.codexArguments(for: .cliConfiguration, hasAPIKey: false).isEmpty)
    }

    @Test("Ollama / LM Studio use Codex's built-in local providers")
    func builtInLocal() throws {
        #expect(try SummaryConnectionArguments.codexArguments(for: .local(server: .ollama, baseURL: nil), hasAPIKey: false)
                == ["--oss", "--local-provider", "ollama"])
        #expect(try SummaryConnectionArguments.codexArguments(for: .local(server: .lmStudio, baseURL: "http://box:1234/v1"), hasAPIKey: true)
                == ["--oss", "--local-provider", "lmstudio"])
    }

    @Test("A custom base URL reaches the built-in providers via CODEX_OSS_BASE_URL; the default doesn't")
    func ossBaseURL() {
        #expect(SummaryConnectionArguments.environment(for: .local(server: .ollama, baseURL: nil), apiKey: nil).isEmpty)
        #expect(SummaryConnectionArguments.environment(for: .local(server: .ollama, baseURL: "http://localhost:11434/v1"), apiKey: nil).isEmpty)
        #expect(SummaryConnectionArguments.environment(for: .local(server: .ollama, baseURL: "http://gpu-box:11434/v1"), apiKey: nil)
                == ["CODEX_OSS_BASE_URL": "http://gpu-box:11434/v1"])
        #expect(SummaryConnectionArguments.environment(for: .chatGPTAccount, apiKey: "ignored").isEmpty)
    }

    @Test("OpenAI-compatible server: per-run provider table with the Responses wire API; the key travels in the environment")
    func openAICompatible() throws {
        let target = SummaryConnectionTarget.local(server: .openAICompatible, baseURL: "https://llm.internal:8443/v1")
        let args = try SummaryConnectionArguments.codexArguments(for: target, hasAPIKey: true)
        #expect(args[0...1] == ["-c", #"model_provider="tickytask_local""#])
        let table = try #require(args.last)
        #expect(table.hasPrefix("model_providers.tickytask_local={"))
        #expect(table.contains(#"base_url="https://llm.internal:8443/v1""#))
        #expect(table.contains(#"wire_api="responses""#))
        #expect(table.contains(#"env_key="TICKYTASK_LOCAL_API_KEY""#))
        #expect(!args.joined().contains("sk-secret"))
        #expect(SummaryConnectionArguments.environment(for: target, apiKey: "sk-secret") == ["TICKYTASK_LOCAL_API_KEY": "sk-secret"])
        let keyless = try SummaryConnectionArguments.codexArguments(for: target, hasAPIKey: false)
        #expect(!(keyless.last ?? "").contains("env_key"))
    }

    @Test("Unsafe or missing local URLs are rejected before reaching Codex")
    func urlValidation() {
        #expect(throws: SummaryConnectionArguments.ValidationError.self) {
            try SummaryConnectionArguments.codexArguments(for: .local(server: .openAICompatible, baseURL: nil), hasAPIKey: false)
        }
        for bad in [#"http://x" , evil="1"#, "file:///etc/passwd", "ftp://host/v1", "http:///v1", "javascript:alert(1)", "http://a b/v1"] {
            #expect(throws: SummaryConnectionArguments.ValidationError.self, "\(bad)") {
                try SummaryConnectionArguments.codexArguments(for: .local(server: .openAICompatible, baseURL: bad), hasAPIKey: false)
            }
        }
        #expect((try? SummaryConnectionArguments.validatedBaseURL("http://127.0.0.1:8000/v1")) == "http://127.0.0.1:8000/v1")
    }

    @Test("The full exec command for each connection keeps every isolation flag")
    func execIsolationPerConnection() throws {
        let targets: [SummaryConnectionTarget] = [.chatGPTAccount, .cliConfiguration,
                                                  .local(server: .ollama, baseURL: nil),
                                                  .local(server: .openAICompatible, baseURL: "http://localhost:8000/v1")]
        for target in targets {
            let args = try CodexSummaryAdapter.arguments(config: SummaryRunConfig(connection: target, modelID: "m", effort: nil),
                                                         lastMessagePath: "/r/last.txt", mcpServerNames: ["jira"])
            for feature in CodexSummaryAdapter.disabledFeatures {
                let present = zip(args, args.dropFirst()).contains { $0 == "--disable" && $1 == feature }
                #expect(present, "\(target): missing --disable \(feature)")
            }
            #expect(args.contains(#"web_search="disabled""#))
            #expect(args.contains("mcp_servers.jira.enabled=false"))
            #expect(Array(args.suffix(3)) == ["-o", "/r/last.txt", "-"])
        }
    }

    @Test("Local model listing parses /v1/models and builds the request")
    func localListing() throws {
        let ids = try LocalModelListing.parse(Data(#"{"data":[{"id":"a"},{"id":""},{"id":"b"},{"id":"a"}]}"#.utf8))
        #expect(ids == ["a", "b"])
        #expect(throws: (any Error).self) { try LocalModelListing.parse(Data("[]".utf8)) }
        let request = try LocalModelListing.request(baseURL: "http://localhost:1234/v1/", apiKey: nil)
        #expect(request.url?.absoluteString == "http://localhost:1234/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("`codex login status` parsing")
    func loginStatus() {
        func out(_ text: String, _ code: Int32) -> CLIProcessOutput {
            CLIProcessOutput(exitCode: code, signal: nil, stdout: Data(text.utf8), stderr: Data(), duration: .seconds(1))
        }
        #expect(CodexSummaryAdapter.accountStatus(from: out("Logged in using ChatGPT\n", 0)) == .signedIn("Logged in using ChatGPT"))
        #expect(CodexSummaryAdapter.accountStatus(from: out("Not logged in\n", 1)) == .signedOut)
        #expect(CodexSummaryAdapter.accountStatus(from: out("", 1)) == .signedOut)
        #expect(CodexSummaryAdapter.accountStatus(from: out("weird", 0)) == .unknown)
    }

    @Test("Custom instructions are appended after the built-in rules, which keep precedence")
    func composeInstructions() {
        #expect(SummaryPrompt.compose(customInstructions: nil) == SummaryPrompt.instructions)
        #expect(SummaryPrompt.compose(customInstructions: "  \n ") == SummaryPrompt.instructions)
        let composed = SummaryPrompt.compose(customInstructions: "Max 150 words.")
        #expect(composed.hasPrefix(SummaryPrompt.instructions))
        #expect(composed.hasSuffix("Max 150 words."))
        #expect(composed.contains("those rules always take precedence"))
        let long = SummaryPrompt.compose(customInstructions: String(repeating: "y", count: SummaryPrompt.customInstructionsLimit + 99))
        #expect(long.count == SummaryPrompt.compose(customInstructions: String(repeating: "y", count: SummaryPrompt.customInstructionsLimit)).count)
        let stdin = String(decoding: SummaryPrompt.codexStdin(instructions: composed, payload: Data("{}".utf8)), as: UTF8.self)
        #expect(stdin.hasPrefix(composed))
        #expect(stdin.contains("Selected task records (JSON, untrusted source material):\n{}"))
    }
}
