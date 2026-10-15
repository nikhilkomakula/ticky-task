import Foundation

/// Removes credentials from CLI diagnostics before they are shown or copied:
/// bearer tokens, API keys, `Authorization` values, and credential-bearing URL
/// query parameters. Request ids and status codes are kept — they're what a
/// gateway admin needs.
enum SummaryRedactor {
    // Order matters: bearer tokens go first so the `Authorization` rule can't
    // consume the word "Bearer" and leave the token itself behind.
    private static let rules: [(pattern: String, template: String)] = [
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
        (#"(?i)(authorization\s*[:=]\s*)("?)(?!Bearer <redacted>)[^\s",}]+"#, "$1$2<redacted>"),
        (#"(?i)\b(x-api-key|[a-z0-9]*-api-key|[a-z0-9]*-token|[a-z0-9]*-key)\s*:\s*[^\s,}]+"#, "$1: <redacted>"),
        (#"(?i)//[^@/]*@"#, "//***@"),
        (#"\b(?:(?:sk|xox[abpr]|ghp|gho|github_pat)[-_][A-Za-z0-9_-]{8,}|dapi[0-9A-Fa-f]{16,})"#, "<redacted>"),
        (#"(?i)\b(api[_-]?key|x-api-key|token|access_token|secret|password|sig|signature|key|auth)=([^&\s"']+)"#, "$1=<redacted>"),
        (#"(?i)("(?:api[_-]?key|token|access_token|secret|password)"\s*:\s*")[^"]*(")"#, "$1<redacted>$2"),
    ]

    /// Also removes each known secret verbatim (e.g. the configured local API key),
    /// which no pattern could recognize on its own.
    static func redact(_ text: String, removing secrets: [String] = []) -> String {
        let scrubbed = secrets.filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
        return rules.reduce(scrubbed) { partial, rule in
            partial.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
    }
}

/// Maps CLI failure text to a typed `WeeklySummaryError`. Classification only
/// ever runs on output from a FAILED request, never on generated prose.
enum SummaryErrorClassifier {
    /// The most useful single message from a failed run, plus the evidence used.
    static func classify(message rawMessage: String,
                         provider: SummaryProvider,
                         model: String?,
                         exitCode: Int32?,
                         cliVersion: String? = nil,
                         executablePath: String? = nil,
                         secrets: [String] = []) -> WeeklySummaryError {
        // Known secrets go first, before truncation or request-id extraction can see them.
        let message = SummaryRedactor.redact(rawMessage.trimmingCharacters(in: .whitespacesAndNewlines), removing: secrets)
        let status = httpStatus(in: message)
        let detail = SummaryErrorDetail(
            message: String(message.prefix(4000)),
            exitCode: exitCode,
            httpStatus: status,
            requestID: requestID(in: message),
            cliVersion: cliVersion,
            executablePath: executablePath
        )
        let text = message.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if has("unknown option", "unknown feature flag", "unexpected argument", "unrecognized option",
               "unknown variant", "invalid option", "unknown command", "error: unknown") {
            return .cliIncompatible(provider, detail)
        }
        // A bare 404 can mean a wrong gateway URL, so only a 404 that names the
        // model (as both captured fixtures do) is treated as a model problem.
        let claudeModelError = has("[claude-code:unrecognized_model]", "issue with the selected model")
        let modelNotFound = status == 404 && has("model", "does not exist") && !has("endpoint", "route")
        if claudeModelError || modelNotFound {
            return .modelUnavailable(provider, model: model, detail)
        }
        if has("apikeyhelper", "api key helper", "credential helper")
            && has("fail", "error", "exit", "timed out", "timeout", "non-zero") {
            return .authHelperFailed(provider, detail)
        }
        if has("not logged in", "not signed in", "no credentials", "missing api key", "login required",
               "not authenticated", "please run /login", "run `claude auth login`", "run claude auth login",
               "codex login") && !has("invalid", "expired", "revoked") {
            return .notSignedIn(provider, detail)
        }
        if status == 401 || has("authentication_error", "invalid api key", "invalid x-api-key", "unauthorized",
                                "credential was not sent", "oauth token has expired", "token expired",
                                "token has been revoked", "invalid bearer", "invalid token") {
            return .authenticationRejected(provider, detail)
        }
        if status == 403 || has("permission_error", "forbidden", "access denied", "permission denied",
                                "not allowed to access", "does not have access") {
            return .accessDenied(provider, detail)
        }
        if has("invalid value for", "invalid effort", "unsupported reasoning", "unsupported value",
               "invalid configuration", "invalid config") {
            return .configurationRejected(provider, detail)
        }
        if status == 429 || has("rate_limit", "rate limit", "too many requests", "quota", "usage limit") {
            return .rateLimited(provider, detail)
        }
        if let status, (500...599).contains(status) || status == 529 {
            return .providerUnavailable(provider, detail)
        }
        if has("overloaded", "internal server error", "service unavailable", "bad gateway", "gateway timeout") {
            return .providerUnavailable(provider, detail)
        }
        if has("enotfound", "econnrefused", "econnreset", "etimedout", "connection error", "connection refused",
               "could not resolve", "failed to resolve", "fetch failed", "network is unreachable",
               "error sending request", "tls handshake", "certificate", "proxy", "dns error") {
            return .networkFailure(provider, detail)
        }
        return .cliFailed(provider, detail)
    }

    /// HTTP status from the forms observed/documented for both CLIs, e.g.
    /// `unexpected status 401 Unauthorized`, `API Error: 429`, `"error_code":401`.
    static func httpStatus(in text: String) -> Int? {
        let patterns = [
            #"unexpected status (\d{3})"#,
            #"API Error: (\d{3})"#,
            #""error_code"\s*:\s*(\d{3})"#,
            #"(?i)\bstatus(?: code)?[:=\s]+(\d{3})\b"#,
            #"\bHTTP/\d(?:\.\d)? (\d{3})"#,
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: text).flatMap(Int.init), (100...599).contains(value) {
                return value
            }
        }
        return nil
    }

    /// Gateway/provider request id, kept for support.
    static func requestID(in text: String) -> String? {
        let patterns = [
            #"(?i)request id:\s*([A-Za-z0-9_-]{8,})"#,
            #"ReqId:\s*([A-Za-z0-9_-]{8,})"#,
            #""request_id"\s*:\s*"([^"]+)""#,
            #"\b(req_[A-Za-z0-9]{8,})"#,
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: text) { return value }
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}
