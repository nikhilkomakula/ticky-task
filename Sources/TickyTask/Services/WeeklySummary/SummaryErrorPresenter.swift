import Foundation

/// How a CLI authenticates — determines which auth remediation is actually
/// correct. A gateway/credential-helper setup isn't fixed by an account login.
enum SummaryAuthSetup: Sendable, Equatable {
    case accountLogin
    case customProvider(name: String?)
    case unknown

    /// From the top-level `model_provider = "…"` in `~/.codex/config.toml`.
    static func codex(configTOML: String?) -> SummaryAuthSetup {
        guard let configTOML else { return .unknown }
        for line in configTOML.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }   // only the top-level table selects the provider
            guard trimmed.hasPrefix("model_provider") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "model_provider" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.lowercased() == "openai" ? .accountLogin : .customProvider(name: value)
        }
        return .accountLogin
    }
}

/// Turns a `WeeklySummaryError` into the banner's title, remediation, and the
/// copyable "Details" text.
enum SummaryErrorPresenter {
    struct Presentation: Equatable {
        var title: String
        var message: String
        /// Raw (already redacted) diagnostics for the Details disclosure; nil when there are none.
        var details: String?
    }

    static func present(_ error: WeeklySummaryError, authSetup: SummaryAuthSetup = .unknown,
                        connection: SummaryConnectionTarget? = nil) -> Presentation {
        Presentation(title: title(error), message: remediation(error, authSetup: authSetup, connection: connection),
                     details: details(error))
    }

    private static func title(_ error: WeeklySummaryError) -> String {
        switch error {
        case .cliNotFound(let p): "\(p.cliName) not found"
        case .invalidCLIPath(let p, _): "The \(p.cliName) path can't be used"
        case .launchFailed(let p, _): "Couldn't start the \(p.cliName)"
        case .cancelled: "Generation cancelled"
        case .timedOut: "Generation took too long"
        case .inputTooLarge: "Too much selected"
        case .notSignedIn(let p, _): "\(p.displayName) has no usable credentials"
        case .authenticationRejected(let p, let d): "\(p.displayName) authentication was rejected\(statusSuffix(d))"
        case .authHelperFailed(let p, _): "\(p.displayName)'s credential helper failed"
        case .accessDenied(let p, let d): "\(p.displayName) access was denied\(statusSuffix(d))"
        case .modelUnavailable(_, let model, _): model.map { "Model “\($0)” is unavailable" } ?? "The selected model is unavailable"
        case .configurationRejected(let p, _): "\(p.displayName) rejected this configuration"
        case .rateLimited(let p, _): "\(p.displayName) is rate limited"
        case .providerUnavailable(let p, _): "\(p.displayName)'s model provider is unavailable"
        case .networkFailure(let p, _): "Couldn't reach \(p.displayName)'s provider"
        case .cliIncompatible(let p, _): "This \(p.cliName) version isn't compatible"
        case .invalidResponse(let p, _): "\(p.displayName) returned an unreadable response"
        case .emptyResponse(let p): "\(p.displayName) returned no summary"
        case .cliFailed(let p, _): "The \(p.cliName) stopped with an error"
        }
    }

    private static func remediation(_ error: WeeklySummaryError, authSetup: SummaryAuthSetup,
                                    connection: SummaryConnectionTarget?) -> String {
        switch error {
        case .cliNotFound(let p):
            return "Install the \(p.cliName), or set the path to the `\(p.executableName)` executable in Settings › AI."
        case .invalidCLIPath(_, let path):
            return "“\(path)” is missing or not executable. Choose a valid executable in Settings › AI, or clear the path to search automatically."
        case .launchFailed:
            return "Check that the CLI is installed correctly and is executable, then try again."
        case .cancelled:
            return "Your selection and any previous summary are kept."
        case .timedOut(let seconds):
            return "No result after \(seconds / 60) minutes. Try again, choose a lower effort, or select fewer tasks."
        case .inputTooLarge(let bytes, let limit):
            return "The selected notes are \(bytes / 1024) KB; the limit is \(limit / 1024) KB. Select fewer tasks and try again."
        case .notSignedIn, .authenticationRejected:
            if let connection, connection.isLocal {
                return "The local server rejected the request. If it requires an API key, enter it in Settings › AI, then try again."
            }
            return authRemediation(setup: authSetup)
        case .authHelperFailed:
            return "The credential helper configured for this CLI didn't return a usable credential. Run the CLI once in Terminal to see the helper's error, fix its setup, then try again."
        case .accessDenied:
            return "The provider recognized your credentials but refused this request. Check that your account and gateway policy allow this model, or choose another model."
        case .modelUnavailable:
            return "It may not exist or you may not have access to it. Refresh the model list, or choose another model."
        case .configurationRejected:
            return "Choose a different effort level (or CLI default) for this model and try again."
        case .rateLimited:
            return "Wait a little and try again. If the message mentions a quota, check your plan or gateway limits."
        case .providerUnavailable:
            return "The provider reported a server-side problem. Try again in a few minutes."
        case .networkFailure:
            if let connection, case .local(let server, _) = connection {
                let url = connection.localBaseURL.map { SummaryRedactor.redact($0) } ?? ""
                let address = url.isEmpty ? "" : " at \(url)"
                return "Make sure \(server.displayName) is running and serving a model\(address), then try again."
            }
            return "Check your network, VPN, or proxy, and that the provider endpoint is reachable, then try again."
        case .cliIncompatible(let p, _):
            return "TickyTask needs \(p.cliName) options this version doesn't support (it never runs a summary without them). Update the \(p.cliName), then try again."
        case .invalidResponse:
            return "Try again. If it keeps happening, update the CLI."
        case .emptyResponse:
            return "Try again, or choose another model."
        case .cliFailed:
            return "See Details for the CLI's message."
        }
    }

    private static func authRemediation(setup: SummaryAuthSetup) -> String {
        switch setup {
        case .customProvider(let name):
            let via = name.map { " (\($0))" } ?? ""
            return "Codex is using a custom provider or credential helper from your Codex configuration\(via). Check that setup — or switch the connection to your ChatGPT account in Settings › AI — then try again."
        case .accountLogin:
            return "Sign in to your ChatGPT account: use Sign in under Settings › AI, or run `codex login` in Terminal, then try again."
        case .unknown:
            return "Sign in with Settings › AI › Sign in (or `codex login` in Terminal) — or, if Codex uses a gateway or credential helper, check that setup — then try again."
        }
    }

    private static func statusSuffix(_ detail: SummaryErrorDetail) -> String {
        detail.httpStatus.map { " (\($0))" } ?? ""
    }

    private static func details(_ error: WeeklySummaryError) -> String? {
        var lines: [String] = []
        switch error {
        case .invalidCLIPath(_, let path): lines.append("Path: \(path)")
        case .timedOut(let seconds): lines.append("Deadline: \(seconds) s")
        case .inputTooLarge(let bytes, let limit): lines.append("Payload: \(bytes) bytes (limit \(limit))")
        default: break
        }
        if let detail = error.detail {
            if !detail.message.isEmpty { lines.append(detail.message) }
            if let status = detail.httpStatus { lines.append("HTTP status: \(status)") }
            if let requestID = detail.requestID { lines.append("Request ID: \(requestID)") }
            if let code = detail.exitCode { lines.append("Exit code: \(code)") }
            if let version = detail.cliVersion { lines.append("CLI version: \(version)") }
            if let path = detail.executablePath { lines.append("Executable: \(path)") }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
