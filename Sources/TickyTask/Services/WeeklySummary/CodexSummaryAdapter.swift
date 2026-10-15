import Foundation

/// Argument construction and result parsing for `codex exec`. Codex has no
/// system-prompt flag, so instructions + payload go on stdin; the final message
/// is read from the `-o` file and failures from the `--json` event stream.
enum CodexSummaryAdapter {
    /// Every per-run switch needed to make the run text-only. All are required:
    /// if this Codex version rejects any of them, generation fails with
    /// `cliIncompatible` rather than ever running a summary with tools enabled.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "hooks", "plugins", "apps", "multi_agent",
        "browser_use", "computer_use", "image_generation", "skill_search", "tool_suggest", "view_image",
    ]

    /// Feature disables, web search off, and every configured MCP server
    /// disabled for this run only. The provider/auth config is left untouched.
    static func isolationArguments(mcpServerNames: [String]) -> [String] {
        var args: [String] = []
        for feature in disabledFeatures { args += ["--disable", feature] }
        args += ["-c", #"web_search="disabled""#]
        for name in mcpServerNames { args += ["-c", "mcp_servers.\(tomlKey(name)).enabled=false"] }
        return args
    }

    /// Throws when a local server's address is missing or unsafe to embed.
    static func arguments(config: SummaryRunConfig, lastMessagePath: String, mcpServerNames: [String],
                          hasAPIKey: Bool = false) throws -> [String] {
        var args = ["exec", "--json", "--skip-git-repo-check", "--ephemeral",
                    "-s", "read-only", "--color", "never"]
        args += try SummaryConnectionArguments.codexArguments(for: config.connection, hasAPIKey: hasAPIKey)
        args += isolationArguments(mcpServerNames: mcpServerNames)
        if let model = config.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            args += ["-m", model]
        }
        if let effort = config.effort, isSafeConfigToken(effort) {
            args += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
        args += ["-o", lastMessagePath, "-"]
        return args
    }

    /// A model-free check that this Codex version accepts every isolation switch
    /// (`debug prompt-input` parses the same flags and config overrides).
    static func preflightArguments(mcpServerNames: [String]) -> [String] {
        ["debug", "prompt-input"] + isolationArguments(mcpServerNames: mcpServerNames) + ["ping"]
    }

    static let mcpListArguments = ["mcp", "list", "--json"]

    struct UnrecognizedMCPList: Error {}

    /// Server names from `codex mcp list --json` (an array, or `{"servers": [...]}`).
    /// Fails closed: anything that isn't a list of named servers throws, since a
    /// server we can't name is a server we can't disable.
    static func mcpServerNames(fromListJSON data: Data) throws -> [String] {
        let root = try? JSONSerialization.jsonObject(with: data)
        let items: [Any]
        if let array = root as? [Any] {
            items = array
        } else if let object = root as? [String: Any], let servers = object["servers"] as? [Any] {
            items = servers
        } else {
            throw UnrecognizedMCPList()
        }
        var names: [String] = []
        for item in items {
            guard let name = (item as? [String: Any])?["name"] as? String, !name.isEmpty else {
                throw UnrecognizedMCPList()
            }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Accepts output only when the process exited 0, no turn failed, and the
    /// `-o` file holds a non-blank message; a terminal failure overrides output.
    static func parse(_ output: CLIProcessOutput,
                      lastMessage: String?,
                      config: SummaryRunConfig,
                      cliVersion: String?,
                      executablePath: String?) -> Result<SummaryResult, WeeklySummaryError> {
        let events = Events(jsonl: output.stdout)
        let text = (lastMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if output.succeeded, events.turnFailure == nil {
            guard !text.isEmpty else { return .failure(.emptyResponse(.codex)) }
            return .success(SummaryResult(text: text, config: config, resolvedModel: nil,
                                          duration: output.duration, usage: events.usage))
        }
        let message = events.turnFailure
            ?? events.lastError.map(stripReconnectWrapper)
            ?? joined(output.stderrText, fallback: exitDescription(output))
        return .failure(SummaryErrorClassifier.classify(
            message: message, provider: .codex, model: config.modelID,
            exitCode: output.exitCode, cliVersion: cliVersion, executablePath: executablePath))
    }

    /// The pieces of the JSONL event stream the app cares about.
    struct Events {
        var turnFailure: String?
        var lastError: String?
        var usage: SummaryUsage?

        init(jsonl data: Data) {
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = object["type"] as? String else { continue }
                switch type {
                case "turn.failed":
                    let error = object["error"] as? [String: Any]
                    turnFailure = (error?["message"] as? String) ?? (object["message"] as? String) ?? "The turn failed."
                case "error":
                    if let message = object["message"] as? String { lastError = message }
                case "turn.completed":
                    if let usage = object["usage"] as? [String: Any] {
                        self.usage = SummaryUsage(inputTokens: usage["input_tokens"] as? Int,
                                                  outputTokens: usage["output_tokens"] as? Int)
                    }
                default:
                    break
                }
            }
        }
    }

    /// `Reconnecting... 2/5 (unexpected status 404 …)` → the inner message.
    static func stripReconnectWrapper(_ message: String) -> String {
        guard message.hasPrefix("Reconnecting..."),
              let open = message.firstIndex(of: "("), message.hasSuffix(")") else { return message }
        return String(message[message.index(after: open)..<message.index(before: message.endIndex)])
    }

    static func exitDescription(_ output: CLIProcessOutput) -> String {
        if let signal = output.signal { return "The CLI was terminated by signal \(signal)." }
        return "The CLI exited with status \(output.exitCode.map(String.init) ?? "unknown")."
    }

    /// Non-empty trimmed parts joined by newlines, or `fallback` when all are empty.
    static func joined(_ parts: String..., fallback: String) -> String {
        let text = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? fallback : text
    }

    /// Values interpolated into `-c key=value` must be plain tokens.
    static func isSafeConfigToken(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    /// A TOML key segment: bare when possible, otherwise quoted.
    static func tomlKey(_ name: String) -> String {
        if name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil { return name }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static let loginStatusArguments = ["login", "status"]
    static let loginArguments = ["login"]

    /// `codex login status` prints e.g. "Logged in using ChatGPT" (exit 0) or
    /// "Not logged in" (non-zero).
    static func accountStatus(from output: CLIProcessOutput) -> SummaryAccountStatus {
        let text = joined(output.stdoutText, output.stderrText, fallback: "")
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("not signed in") { return .signedOut }
        if output.succeeded, lower.contains("logged in") {
            return .signedIn(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text)
        }
        return output.succeeded ? .unknown : .signedOut
    }
}
