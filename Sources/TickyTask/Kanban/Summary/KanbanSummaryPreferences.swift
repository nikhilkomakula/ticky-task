import Foundation

/// Remembered Kanban Summary choices (UserDefaults). Reuses the connection,
/// model, and effort infrastructure from Weekly Summary preferences.
struct KanbanSummaryPreferences {
    private enum Key {
        static let connection = "weeklySummary.connection"
        static let localServer = "weeklySummary.local.server"
        static let localBaseURL = "weeklySummary.local.baseURL"
        static let efforts = "weeklySummary.efforts"
        static let instructions = "kanbanSummary.instructions"
        static let cliPath = "weeklySummary.cliPath.codex"
        static func model(_ connection: String) -> String { "weeklySummary.model.\(connection)" }
        static func customModels(_ connection: String) -> String { "weeklySummary.customModels.\(connection)" }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = KanbanSummaryPreferences.store) {
        self.defaults = defaults
    }

    /// UI-test runs use a throwaway suite so they never change the user's real choices.
    static let store: UserDefaults = UITestSupport.isRunning ? UITestSupport.scratchDefaults : .standard

    // MARK: - Connection

    /// Defaults to the user's own ChatGPT sign-in.
    var connectionKind: String {
        get { defaults.string(forKey: Key.connection) ?? "chatgpt" }
        nonmutating set { defaults.set(newValue, forKey: Key.connection) }
    }

    var localServer: SummaryLocalServer {
        get { defaults.string(forKey: Key.localServer).flatMap(SummaryLocalServer.init(rawValue:)) ?? .ollama }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.localServer) }
    }

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
        case "chatgpt": .chatGPTAccount
        case "cli": .cliConfiguration
        default: .local(server: localServer, baseURL: localBaseURL.isEmpty ? nil : localBaseURL)
        }
    }

    // MARK: - Models (per connection)

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

    func customModelIDs(for connection: SummaryConnectionTarget) -> [String] {
        guard let json = defaults.string(forKey: Key.customModels(connection.storageKey)),
              let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return ids
    }

    func addCustomModelID(_ id: String, for connection: SummaryConnectionTarget) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var ids = customModelIDs(for: connection).filter { $0 != trimmed }
        ids.insert(trimmed, at: 0)
        if let data = try? JSONEncoder().encode(Array(ids.prefix(10))) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Key.customModels(connection.storageKey))
        }
    }

    // MARK: - Custom instructions (Kanban-specific)

    /// The user's own Kanban summary instructions, applied on top of the built-in rules.
    /// Stored under the key `kanbanSummary.instructions` (already in the backup model).
    var customInstructions: String {
        get { defaults.string(forKey: Key.instructions) ?? KanbanSummaryPrompt.defaultCustomInstructions }
        nonmutating set {
            let limited = String(newValue.prefix(KanbanSummaryPrompt.customInstructionsLimit))
            let isBlank = limited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            defaults.set(isBlank ? "" : limited, forKey: Key.instructions)
        }
    }

    private func setOrRemove(_ value: String, forKey key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(key == Key.instructions ? value : trimmed, forKey: key) }
    }
}
