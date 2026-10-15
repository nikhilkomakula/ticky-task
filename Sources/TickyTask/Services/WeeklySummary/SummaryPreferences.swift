import Foundation

/// Remembered Weekly Summary choices (UserDefaults). Models, efforts, and custom
/// model ids are kept per connection, since each reaches different models.
/// Every portable value is stored as a String so the settings backup can carry
/// them generically; the CLI path (machine-specific) and the local API key
/// (Keychain) are never part of it.
struct SummaryPreferences {
    enum ConnectionKind: String, CaseIterable, Identifiable, Sendable {
        case chatGPTAccount = "chatgpt"
        case cliConfiguration = "cli"
        case local

        var id: String { rawValue }

        var label: String {
            switch self {
            case .chatGPTAccount: "ChatGPT account"
            case .cliConfiguration: "Codex CLI configuration"
            case .local: "Local model"
            }
        }
    }

    private enum Key {
        static let connection = "weeklySummary.connection"
        static let localServer = "weeklySummary.local.server"
        static let localBaseURL = "weeklySummary.local.baseURL"
        static let efforts = "weeklySummary.efforts"
        static let instructions = "weeklySummary.instructions"
        static let cliPath = "weeklySummary.cliPath.codex"
        static func model(_ connection: String) -> String { "weeklySummary.model.\(connection)" }
        static func customModels(_ connection: String) -> String { "weeklySummary.customModels.\(connection)" }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = SummaryPreferences.store) {
        self.defaults = defaults
    }

    /// UI-test runs use a throwaway suite so they never change the user's real choices.
    static let store: UserDefaults = UITestSupport.isRunning ? UITestSupport.scratchDefaults : .standard

    // MARK: - Connection

    /// Defaults to the user's own ChatGPT sign-in — no gateway setup needed.
    var connectionKind: ConnectionKind {
        get { defaults.string(forKey: Key.connection).flatMap(ConnectionKind.init(rawValue:)) ?? .chatGPTAccount }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.connection) }
    }

    var localServer: SummaryLocalServer {
        get { defaults.string(forKey: Key.localServer).flatMap(SummaryLocalServer.init(rawValue:)) ?? .ollama }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.localServer) }
    }

    /// Blank = the server's default address. A URL carrying credentials is never
    /// stored (they belong in the Keychain-backed API key), so it reads as blank.
    var localBaseURL: String {
        get {
            let stored = defaults.string(forKey: Key.localBaseURL) ?? ""
            return SummaryConnectionArguments.containsCredentials(stored) ? "" : stored
        }
        nonmutating set {
            let safe = SummaryConnectionArguments.containsCredentials(newValue) ? "" : newValue
            setOrRemove(safe, forKey: Key.localBaseURL)
        }
    }

    var connection: SummaryConnectionTarget {
        switch connectionKind {
        case .chatGPTAccount: .chatGPTAccount
        case .cliConfiguration: .cliConfiguration
        case .local: .local(server: localServer, baseURL: localBaseURL.isEmpty ? nil : localBaseURL)
        }
    }

    // MARK: - Models (per connection)

    /// "" = CLI default.
    func modelID(for connection: SummaryConnectionTarget) -> String {
        defaults.string(forKey: Key.model(connection.storageKey)) ?? ""
    }

    func setModelID(_ id: String, for connection: SummaryConnectionTarget) {
        setOrRemove(id, forKey: Key.model(connection.storageKey))
    }

    // MARK: - Efforts (per connection + model)

    func effort(for connection: SummaryConnectionTarget, modelID: String) -> EffortChoice? {
        efforts()[effortKey(connection, modelID)]
    }

    func setEffort(_ effort: EffortChoice, for connection: SummaryConnectionTarget, modelID: String) {
        var all = efforts()
        all[effortKey(connection, modelID)] = effort
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Key.efforts)
        }
    }

    private func efforts() -> [String: EffortChoice] {
        guard let json = defaults.string(forKey: Key.efforts),
              let decoded = try? JSONDecoder().decode([String: EffortChoice].self, from: Data(json.utf8)) else { return [:] }
        return decoded
    }

    private func effortKey(_ connection: SummaryConnectionTarget, _ modelID: String) -> String {
        "\(connection.storageKey)|\(modelID)"
    }

    // MARK: - Custom model ids (per connection)

    /// Most recent first.
    func customModelIDs(for connection: SummaryConnectionTarget) -> [String] {
        guard let json = defaults.string(forKey: Key.customModels(connection.storageKey)),
              let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return ids
    }

    /// Trims, ignores blanks, de-duplicates (moving a repeat to the front), keeps 10.
    func addCustomModelID(_ id: String, for connection: SummaryConnectionTarget) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var ids = customModelIDs(for: connection).filter { $0 != trimmed }
        ids.insert(trimmed, at: 0)
        if let data = try? JSONEncoder().encode(Array(ids.prefix(10))) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Key.customModels(connection.storageKey))
        }
    }

    /// Whether `value` is an endpoint URL carrying credentials (only the base URL
    /// setting is checked; instructions may legitimately mention URLs).
    static func isUnsafeEndpoint(_ value: String, forKey key: String) -> Bool {
        key == Key.localBaseURL && SummaryConnectionArguments.containsCredentials(value)
    }

    // MARK: - Custom instructions

    /// The user's own summary instructions, applied on top of the built-in rules.
    /// Until the user changes them they're the defaults; clearing them is kept
    /// (stored as empty), not reverted.
    var customInstructions: String {
        get { defaults.string(forKey: Key.instructions) ?? SummaryPrompt.defaultCustomInstructions }
        nonmutating set {
            let limited = String(newValue.prefix(SummaryPrompt.customInstructionsLimit))
            let isBlank = limited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            defaults.set(isBlank ? "" : limited, forKey: Key.instructions)
        }
    }

    // MARK: - CLI path (machine-specific; not backed up)

    var cliPathOverride: String? {
        get { defaults.string(forKey: Key.cliPath).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { setOrRemove(newValue ?? "", forKey: Key.cliPath) }
    }

    // MARK: - Backup

    /// Every connection's storage key, so per-connection keys can be enumerated.
    static let connectionStorageKeys = ["chatgpt", "cli"] + SummaryLocalServer.allCases.map { "local-\($0.rawValue)" }

    /// String-valued keys safe to include in the portable settings backup.
    static let portableKeys: [String] =
        [Key.connection, Key.localServer, Key.localBaseURL, Key.efforts, Key.instructions]
        + connectionStorageKeys.flatMap { [Key.model($0), Key.customModels($0)] }

    private func setOrRemove(_ value: String, forKey key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(key == Key.instructions ? value : trimmed, forKey: key) }
    }
}
