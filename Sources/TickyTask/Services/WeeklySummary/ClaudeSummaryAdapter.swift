import Foundation

/// Argument construction and result parsing for a headless `claude -p` run.
/// The instructions travel via `--system-prompt` (replacing Claude Code's coding
/// persona) and the task payload via stdin.
enum ClaudeSummaryAdapter {
    /// `--safe-mode` disables CLAUDE.md, skills, plugins, hooks, MCP, and other
    /// customizations while keeping admin policy and auth (verified against a
    /// gateway `apiKeyHelper`); `--tools ""` removes every tool, so the run is
    /// text-in, text-out.
    static func arguments(config: SummaryRunConfig, instructions: String) -> [String] {
        var args = [
            "-p",
            "--output-format", "json",
            "--safe-mode",
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--system-prompt", instructions,
        ]
        if let model = config.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            args += ["--model", model]
        }
        if let effort = config.effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        return args
    }

    private struct ResultEnvelope: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }

        let type: String?
        let subtype: String?
        let is_error: Bool?
        let result: String?
        let usage: Usage?
        let modelUsage: [String: AnyDecodable]?
        /// HTTP status of a failed API call, when Claude reports one.
        let api_error_status: Int?
    }

    /// Accepts output only when the process exited 0 AND the envelope reports
    /// success with a non-blank result; everything else is classified.
    static func parse(_ output: CLIProcessOutput,
                      config: SummaryRunConfig,
                      cliVersion: String?,
                      executablePath: String?) -> Result<SummaryResult, WeeklySummaryError> {
        func failure(_ message: String) -> WeeklySummaryError {
            SummaryErrorClassifier.classify(message: message, provider: .claude, model: config.modelID,
                                            exitCode: output.exitCode, cliVersion: cliVersion,
                                            executablePath: executablePath)
        }

        let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let envelope = decodeEnvelope(output.stdout) else {
            if output.succeeded {
                let preview = String(output.stdoutText.prefix(400))
                return .failure(.invalidResponse(.claude, SummaryErrorDetail(
                    message: SummaryRedactor.redact(preview.isEmpty ? "No output." : preview),
                    exitCode: output.exitCode, cliVersion: cliVersion, executablePath: executablePath)))
            }
            return .failure(failure(joined(stderr, output.stdoutText, fallback: exitDescription(output))))
        }

        let text = (envelope.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if envelope.is_error == true || !output.succeeded {
            // Lead with the structured status so classification doesn't depend on wording.
            let status = envelope.api_error_status.map { "API Error: \($0)" } ?? ""
            return .failure(failure(joined(status, text, stderr, fallback: exitDescription(output))))
        }
        guard !text.isEmpty else { return .failure(.emptyResponse(.claude)) }

        let usage = envelope.usage.map { SummaryUsage(inputTokens: $0.input_tokens, outputTokens: $0.output_tokens) }
        return .success(SummaryResult(
            text: text,
            config: config,
            resolvedModel: envelope.modelUsage?.keys.sorted().first,
            duration: output.duration,
            usage: usage
        ))
    }

    /// `--output-format json` prints one object; tolerate stray leading lines.
    private static func decodeEnvelope(_ data: Data) -> ResultEnvelope? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ResultEnvelope.self, from: data), envelope.type != nil || envelope.result != nil {
            return envelope
        }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).reversed()
        for line in lines where line.hasPrefix("{") {
            if let envelope = try? decoder.decode(ResultEnvelope.self, from: Data(line.utf8)),
               envelope.type == "result" {
                return envelope
            }
        }
        return nil
    }

    static func exitDescription(_ output: CLIProcessOutput) -> String {
        if let signal = output.signal { return "The CLI was terminated by signal \(signal)." }
        return "The CLI exited with status \(output.exitCode.map(String.init) ?? "unknown")."
    }

    static func joined(_ parts: String..., fallback: String) -> String {
        let text = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? fallback : text
    }
}

/// Decodes and discards any JSON value — used for dictionary values whose shape
/// we don't need (e.g. Claude's per-model usage), so their keys can be read.
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd { _ = try array.decode(AnyDecodable.self) }
        } else if let object = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in object.allKeys { _ = try object.decode(AnyDecodable.self, forKey: key) }
        } else {
            _ = try decoder.singleValueContainer()
        }
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}
