import Foundation
import CryptoKit

/// A self-hosted model server Codex can talk to.
enum SummaryLocalServer: String, CaseIterable, Identifiable, Codable, Sendable {
    case ollama
    case lmStudio
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openAICompatible: "OpenAI-compatible server"
        }
    }

    /// The server's usual OpenAI-compatible endpoint (`…/v1`); blank for a custom server.
    var defaultBaseURL: String {
        switch self {
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        case .openAICompatible: ""
        }
    }

    /// Codex's built-in `--local-provider` name, when it has one.
    var codexLocalProvider: String? {
        switch self {
        case .ollama: "ollama"
        case .lmStudio: "lmstudio"
        case .openAICompatible: nil
        }
    }
}

/// Where Codex sends the summary request for one run.
enum SummaryConnectionTarget: Hashable, Codable, Sendable {
    /// The user's own ChatGPT sign-in (`codex login`), bypassing any custom
    /// provider configured in `~/.codex/config.toml`.
    case chatGPTAccount
    /// Whatever `~/.codex/config.toml` selects (e.g. a company gateway).
    case cliConfiguration
    /// A self-hosted server. `baseURL` nil = the server's default address.
    case local(server: SummaryLocalServer, baseURL: String?)

    /// A stable key for per-connection preferences and caches.
    var storageKey: String {
        switch self {
        case .chatGPTAccount: "chatgpt"
        case .cliConfiguration: "cli"
        case .local(let server, _): "local-\(server.rawValue)"
        }
    }

    /// Identifies the model list a connection reaches: unlike `storageKey`, two
    /// local servers of the same kind at different addresses differ.
    var catalogKey: String {
        guard isLocal else { return storageKey }
        // Only the scheme and host are case-insensitive; paths and queries can differ by case.
        var normalized = localBaseURL ?? ""
        if var components = URLComponents(string: normalized) {
            let scheme = components.scheme?.lowercased(), host = components.host?.lowercased()
            components.scheme = scheme
            components.host = host
            normalized = components.string ?? normalized
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return storageKey + "-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    var label: String {
        switch self {
        case .chatGPTAccount: "ChatGPT account"
        case .cliConfiguration: "Codex CLI configuration"
        case .local(let server, _): server.displayName
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    /// The endpoint a local server is reached at (`…/v1`), if this is local.
    var localBaseURL: String? {
        guard case .local(let server, let url) = self else { return nil }
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? (server.defaultBaseURL.isEmpty ? nil : server.defaultBaseURL) : trimmed
    }
}

/// The child-process name of the API-key variable for an OpenAI-compatible
/// server — the key travels in the environment, never in the argument list.
enum SummaryConnectionArguments {
    static let customProviderID = "tickytask_local"
    static let apiKeyVariable = "TICKYTASK_LOCAL_API_KEY"

    enum ValidationError: Error, Equatable {
        case missingBaseURL
        case invalidBaseURL(String)
        /// A user name, password, or token in the URL — credentials belong in the API key field (Keychain).
        case credentialsInBaseURL
    }

    /// A query parameter whose name contains any of these carries credentials
    /// (`token`, `x-api-key`, `client_secret`, …); such URLs are refused outright.
    private static let credentialNameFragments = ["key", "token", "secret", "password", "auth", "sig", "credential"]

    /// Codex arguments that select the connection. Applied to generation and to
    /// the model catalog so both see the same provider.
    static func codexArguments(for target: SummaryConnectionTarget, hasAPIKey: Bool) throws -> [String] {
        switch target {
        case .chatGPTAccount:
            return ["-c", #"model_provider="openai""#]
        case .cliConfiguration:
            return []
        case .local(let server, _):
            guard let url = target.localBaseURL else { throw ValidationError.missingBaseURL }
            let safeURL = try validatedBaseURL(url)
            // Codex's built-in Ollama/LM Studio providers send no API key, so a
            // server that needs one goes through the custom provider instead.
            if let provider = server.codexLocalProvider, !hasAPIKey {
                return ["--oss", "--local-provider", provider]
            }
            var table = #"{name="TickyTask local", base_url="\#(safeURL)", wire_api="responses""#
            if hasAPIKey { table += #", env_key="\#(apiKeyVariable)""# }
            table += "}"
            return ["-c", #"model_provider="\#(customProviderID)""#,
                    "-c", "model_providers.\(customProviderID)=\(table)"]
        }
    }

    /// Inherited variables that could redirect Codex's built-in local providers
    /// away from the address shown in Settings; dropped for local connections.
    static let inheritedLocalOverrides = ["CODEX_OSS_BASE_URL", "CODEX_OSS_PORT"]

    /// Extra child environment for the connection (the local server address for
    /// Codex's built-in Ollama/LM Studio providers, and the API key).
    static func environment(for target: SummaryConnectionTarget, apiKey: String?) -> [String: String] {
        guard case .local(let server, _) = target else { return [:] }
        var env: [String: String] = [:]
        let hasAPIKey = !(apiKey ?? "").isEmpty
        // Always explicit, so generation reaches the same server the model list came from.
        if server.codexLocalProvider != nil, !hasAPIKey, let url = target.localBaseURL {
            env["CODEX_OSS_BASE_URL"] = url
        }
        if hasAPIKey, let apiKey { env[apiKeyVariable] = apiKey }
        return env
    }

    /// Only plain http(s) URLs without quotes or control characters may be
    /// embedded in the TOML provider table. Rejects URLs with userinfo or
    /// credential-bearing query parameters.
    static func validatedBaseURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "\"\\'\n\r\t ")) == nil else {
            throw ValidationError.invalidBaseURL(trimmed)
        }
        if containsCredentials(trimmed) { throw ValidationError.credentialsInBaseURL }
        return trimmed
    }

    /// Whether a URL carries a user name/password or a credential query parameter.
    static func containsCredentials(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        if components.user != nil || components.password != nil { return true }
        return components.queryItems?.contains { item in
            let name = item.name.lowercased()
            return credentialNameFragments.contains { name.contains($0) }
        } ?? false
    }
}

/// Lists the models a local server offers via its OpenAI-compatible
/// `GET {base}/models` (supported by Ollama and LM Studio).
enum LocalModelListing {
    static func parse(_ data: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        var seen = Set<String>()
        return items.compactMap { $0["id"] as? String }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func request(baseURL: String, apiKey: String?) throws -> URLRequest {
        let base = try SummaryConnectionArguments.validatedBaseURL(baseURL)
        // Append to the path, keeping any routing query (`?tenant=A`) intact.
        guard var components = URLComponents(string: base) else {
            throw SummaryConnectionArguments.ValidationError.invalidBaseURL(base)
        }
        let path = components.percentEncodedPath   // keeps escapes like %2F intact
        components.percentEncodedPath = (path.hasSuffix("/") ? path : path + "/") + "models"
        guard let url = components.url else {
            throw SummaryConnectionArguments.ValidationError.invalidBaseURL(base)
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
