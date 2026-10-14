import Testing
import Foundation
@testable import TickyTask

/// Fixtures captured from the real CLIs on 2026-10-14 (claude 2.1.299, codex
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

    static let claudeSuccess = #"""
    {"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"Summary\n\n- Shipped the retry fix.","usage":{"input_tokens":350,"output_tokens":12},"modelUsage":{"system.ai.claude-haiku-4-5":{"inputTokens":350}}}
    """#

    static let claudeBadModel = #"""
    {"type":"result","subtype":"success","is_error":true,"result":"There's an issue with the selected model (not-a-real-model). It may not exist or you may not have access to it. Run --model to pick a different model."}
    """#
    static let claudeBadModelStderr = #"[claude-code:unrecognized_model] {"model":"not-a-real-model","query_source":"sdk"}"#

    // SYNTHETIC — documented Claude auth failure shapes.
    static let claudeInvalidKey = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":401,"result":"Invalid API key · Please run /login"}"#
    static let claudeForbidden = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":403,"result":"API Error: 403 {\"type\":\"error\",\"error\":{\"type\":\"permission_error\",\"message\":\"Your organization does not have access\"}}"}"#
}

private func output(stdout: String, stderr: String = "", exit: Int32?) -> CLIProcessOutput {
    CLIProcessOutput(exitCode: exit, signal: nil, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8),
                     duration: .seconds(3))
}

private let claudeConfig = SummaryRunConfig(provider: .claude, modelID: "haiku", effort: "low")
private let codexConfig = SummaryRunConfig(provider: .codex, modelID: "gpt-5.5", effort: "low")

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
                                               config: SummaryRunConfig(provider: .codex, modelID: "not-a-real-model", effort: nil),
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
    func arguments() {
        let args = CodexSummaryAdapter.arguments(
            config: SummaryRunConfig(provider: .codex, modelID: "gpt-6-sol; rm -rf ~", effort: "xhigh"),
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
    func defaultsOmitted() {
        let args = CodexSummaryAdapter.arguments(config: SummaryRunConfig(provider: .codex, modelID: nil, effort: nil),
                                                 lastMessagePath: "/x", mcpServerNames: [])
        #expect(!args.contains("-m"))
        #expect(!args.contains { $0.hasPrefix("model_reasoning_effort") })
        let unsafe = CodexSummaryAdapter.arguments(config: SummaryRunConfig(provider: .codex, modelID: nil, effort: #"high" evil="1"#),
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

@Suite("Weekly Summary — Claude adapter")
struct ClaudeSummaryAdapterTests {
    @Test("REAL success envelope → text, resolved model, usage")
    func realSuccess() {
        let result = ClaudeSummaryAdapter.parse(output(stdout: Fixture.claudeSuccess, exit: 0), config: claudeConfig,
                                                cliVersion: nil, executablePath: nil)
        guard case .success(let summary) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(summary.text == "Summary\n\n- Shipped the retry fix.")
        #expect(summary.resolvedModel == "system.ai.claude-haiku-4-5")
        #expect(summary.usage?.inputTokens == 350)
    }

    @Test("REAL bad model (is_error + unrecognized_model tag) → modelUnavailable")
    func realBadModel() {
        let result = ClaudeSummaryAdapter.parse(output(stdout: Fixture.claudeBadModel, stderr: Fixture.claudeBadModelStderr, exit: 1),
                                                config: SummaryRunConfig(provider: .claude, modelID: "not-a-real-model", effort: nil),
                                                cliVersion: nil, executablePath: nil)
        guard case .failure(.modelUnavailable(.claude, let model, _)) = result else {
            Issue.record("expected modelUnavailable, got \(result)"); return
        }
        #expect(model == "not-a-real-model")
    }

    @Test("SYNTHETIC 401 / 403 envelopes use api_error_status")
    func syntheticAuth() {
        let rejected = ClaudeSummaryAdapter.parse(output(stdout: Fixture.claudeInvalidKey, exit: 1), config: claudeConfig,
                                                  cliVersion: nil, executablePath: nil)
        if case .failure(.authenticationRejected(.claude, let d)) = rejected { #expect(d.httpStatus == 401) }
        else { Issue.record("expected authenticationRejected, got \(rejected)") }
        let denied = ClaudeSummaryAdapter.parse(output(stdout: Fixture.claudeForbidden, exit: 1), config: claudeConfig,
                                                cliVersion: nil, executablePath: nil)
        if case .failure(.accessDenied(.claude, let d)) = denied { #expect(d.httpStatus == 403) }
        else { Issue.record("expected accessDenied, got \(denied)") }
    }

    @Test("Non-zero exit with a plausible success envelope must fail")
    func nonZeroExitFails() {
        let result = ClaudeSummaryAdapter.parse(output(stdout: Fixture.claudeSuccess, stderr: "killed", exit: 137),
                                                config: claudeConfig, cliVersion: nil, executablePath: nil)
        if case .success = result { Issue.record("non-zero exit must not succeed") }
    }

    @Test("Unreadable output: exit 0 → invalidResponse; non-zero → classified stderr")
    func unreadable() {
        let a = ClaudeSummaryAdapter.parse(output(stdout: "not json", exit: 0), config: claudeConfig, cliVersion: nil, executablePath: nil)
        if case .failure(.invalidResponse(.claude, _)) = a {} else { Issue.record("expected invalidResponse, got \(a)") }
        let b = ClaudeSummaryAdapter.parse(output(stdout: "", stderr: "error: unknown option '--safe-mode'", exit: 1),
                                           config: claudeConfig, cliVersion: nil, executablePath: nil)
        if case .failure(.cliIncompatible(.claude, _)) = b {} else { Issue.record("expected cliIncompatible, got \(b)") }
    }

    @Test("Blank result on success → emptyResponse")
    func blank() {
        let json = #"{"type":"result","subtype":"success","is_error":false,"result":"  \n "}"#
        #expect(ClaudeSummaryAdapter.parse(output(stdout: json, exit: 0), config: claudeConfig,
                                           cliVersion: nil, executablePath: nil) == .failure(.emptyResponse(.claude)))
    }

    @Test("Arguments: safe mode, no tools, instructions as system prompt, optional model/effort")
    func arguments() {
        let args = ClaudeSummaryAdapter.arguments(config: claudeConfig, instructions: "INSTR")
        for flag in ["-p", "--safe-mode", "--strict-mcp-config", "--no-session-persistence"] { #expect(args.contains(flag)) }
        #expect(zip(args, args.dropFirst()).contains { $0 == "--tools" && $1 == "" })
        #expect(zip(args, args.dropFirst()).contains { $0 == "--output-format" && $1 == "json" })
        #expect(zip(args, args.dropFirst()).contains { $0 == "--system-prompt" && $1 == "INSTR" })
        #expect(zip(args, args.dropFirst()).contains { $0 == "--model" && $1 == "haiku" })
        #expect(zip(args, args.dropFirst()).contains { $0 == "--effort" && $1 == "low" })
        let defaults = ClaudeSummaryAdapter.arguments(config: SummaryRunConfig(provider: .claude, modelID: "  ", effort: nil),
                                                      instructions: "I")
        #expect(!defaults.contains("--model"))
        #expect(!defaults.contains("--effort"))
        #expect(!defaults.contains("--setting-sources"))   // never strip settings — auth may live there
        #expect(!defaults.contains("--bare"))              // --bare skips keychain/OAuth reads
    }
}

@Suite("Weekly Summary — error classifier & presenter")
struct SummaryErrorClassifierTests {
    private func kind(_ message: String, _ provider: SummaryProvider = .claude) -> WeeklySummaryError {
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

    @Test("Auth remediation follows the CLI's setup")
    func authRemediation() {
        let error = WeeklySummaryError.authenticationRejected(.codex, SummaryErrorDetail(message: "401", httpStatus: 401))
        let gateway = SummaryErrorPresenter.present(error, authSetup: .customProvider(name: "Databricks"))
        #expect(gateway.title == "Codex authentication was rejected (401)")
        #expect(gateway.message.contains("custom provider or credential helper (Databricks)"))
        #expect(gateway.message.contains("may not fix it"))
        let account = SummaryErrorPresenter.present(error, authSetup: .accountLogin)
        #expect(account.message.contains("`codex login`"))
        #expect(!account.message.contains("custom provider"))
    }

    @Test("Every error has a title and remediation; details carry the diagnostics")
    func presentationCoverage() {
        let d = SummaryErrorDetail(message: "raw message", exitCode: 1, httpStatus: 500, requestID: "req_1", cliVersion: "1.0", executablePath: "/bin/x")
        let all: [WeeklySummaryError] = [
            .cliNotFound(.claude), .invalidCLIPath(.codex, path: "/nope"), .launchFailed(.claude, d), .cancelled,
            .timedOut(seconds: 300), .inputTooLarge(bytes: 300_000, limit: 262_144), .notSignedIn(.claude, d),
            .authenticationRejected(.claude, d), .authHelperFailed(.claude, d), .accessDenied(.codex, d),
            .modelUnavailable(.codex, model: "x", d), .configurationRejected(.codex, d), .rateLimited(.claude, d),
            .providerUnavailable(.claude, d), .networkFailure(.codex, d), .cliIncompatible(.codex, d),
            .invalidResponse(.claude, d), .emptyResponse(.codex), .cliFailed(.claude, d),
        ]
        for error in all {
            let p = SummaryErrorPresenter.present(error)
            #expect(!p.title.isEmpty && !p.message.isEmpty, "\(error)")
        }
        let details = SummaryErrorPresenter.present(.cliFailed(.claude, d)).details ?? ""
        for piece in ["raw message", "HTTP status: 500", "Request ID: req_1", "Exit code: 1", "CLI version: 1.0", "Executable: /bin/x"] {
            #expect(details.contains(piece))
        }
        #expect(SummaryErrorPresenter.present(.cliNotFound(.codex)).message.contains("Settings › AI"))
    }

    @Test("Auth setup detection for both CLIs")
    func authSetup() {
        let helper = Data(#"{"loggedIn":true,"authMethod":"api_key_helper","apiProvider":"firstParty"}"#.utf8)
        #expect(SummaryAuthSetup.claude(authStatusJSON: helper, baseURL: "https://dbc.example.com/ai-gateway/anthropic")
                == .customProvider(name: "dbc.example.com"))
        let oauth = Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#.utf8)
        #expect(SummaryAuthSetup.claude(authStatusJSON: oauth, baseURL: nil) == .accountLogin)
        #expect(SummaryAuthSetup.claude(authStatusJSON: nil, baseURL: nil) == .unknown)
        #expect(SummaryAuthSetup.codex(configTOML: "model = \"x\"\nmodel_provider = \"Databricks\"\n[model_providers.Databricks]\n")
                == .customProvider(name: "Databricks"))
        #expect(SummaryAuthSetup.codex(configTOML: "model_provider = \"openai\"") == .accountLogin)
        #expect(SummaryAuthSetup.codex(configTOML: "[profiles.x]\nmodel_provider = \"Other\"") == .accountLogin)
        #expect(SummaryAuthSetup.codex(configTOML: nil) == .unknown)
    }
}
