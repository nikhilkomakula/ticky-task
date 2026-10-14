import Foundation

/// Manages user preferences for Weekly Summary via UserDefaults.
/// Keys are safe for inclusion in portable backup (except CLI paths).
struct SummaryPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Provider

    var provider: SummaryProvider {
        get {
            let rawValue = defaults.string(forKey: "weeklySummary.provider") ?? "claude"
            return SummaryProvider(rawValue: rawValue) ?? .claude
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: "weeklySummary.provider")
        }
    }

    // MARK: - Model IDs (per provider)

    func modelID(for provider: SummaryProvider) -> String {
        let key = "weeklySummary.model.\(provider.rawValue)"
        return defaults.string(forKey: key) ?? ""
    }

    func setModelID(_ id: String, for provider: SummaryProvider) {
        let key = "weeklySummary.model.\(provider.rawValue)"
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    // MARK: - Efforts (per provider + model ID)

    func effort(for provider: SummaryProvider, modelID: String) -> EffortChoice? {
        guard let effortJSON = defaults.string(forKey: "weeklySummary.efforts") else {
            return nil
        }

        guard let data = effortJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let keyString = "\(provider.rawValue)|\(modelID)"
        guard let effortData = dict[keyString] as? [String: Any] else { return nil }

        // Decode EffortChoice from its Codable representation.
        if let choiceType = effortData["_type"] as? String {
            switch choiceType {
            case "cliDefault":
                return .cliDefault
            case "modelDefault":
                if let level = effortData["level"] as? String {
                    return .modelDefault(level)
                }
            case "level":
                if let level = effortData["level"] as? String {
                    return .level(level)
                }
            default:
                break
            }
        }
        return nil
    }

    func setEffort(_ effort: EffortChoice, for provider: SummaryProvider, modelID: String) {
        var dict = (defaults.string(forKey: "weeklySummary.efforts")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]

        let keyString = "\(provider.rawValue)|\(modelID)"

        // Encode EffortChoice.
        var effortData: [String: Any] = [:]
        switch effort {
        case .cliDefault:
            effortData["_type"] = "cliDefault"
        case .modelDefault(let level):
            effortData["_type"] = "modelDefault"
            effortData["level"] = level
        case .level(let level):
            effortData["_type"] = "level"
            effortData["level"] = level
        }

        dict[keyString] = effortData

        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: "weeklySummary.efforts")
        }
    }

    // MARK: - Custom Model IDs (per provider)

    func customModelIDs(for provider: SummaryProvider) -> [String] {
        let key = "weeklySummary.customModels.\(provider.rawValue)"
        return (defaults.array(forKey: key) as? [String]) ?? []
    }

    func addCustomModelID(_ id: String, for provider: SummaryProvider) {
        let key = "weeklySummary.customModels.\(provider.rawValue)"
        var ids = customModelIDs(for: provider)
        let trimmed = id.trimmingCharacters(in: .whitespaces)

        // Skip empty strings and duplicates.
        guard !trimmed.isEmpty, !ids.contains(trimmed) else { return }

        // Keep most recent at the front; cap at 10.
        ids.insert(trimmed, at: 0)
        if ids.count > 10 {
            ids = Array(ids.prefix(10))
        }

        defaults.set(ids, forKey: key)
    }

    // MARK: - CLI Path Overrides (per provider)

    func cliPathOverride(for provider: SummaryProvider) -> String? {
        let key = "weeklySummary.cliPath.\(provider.rawValue)"
        let path = defaults.string(forKey: key)
        return path?.isEmpty == false ? path : nil
    }

    func setCLIPathOverride(_ path: String?, for provider: SummaryProvider) {
        let key = "weeklySummary.cliPath.\(provider.rawValue)"
        let trimmed = path?.trimmingCharacters(in: .whitespaces)
        if trimmed?.isEmpty != false {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    // MARK: - Portable Backup Keys

    static let portableKeys = [
        "weeklySummary.provider",
        "weeklySummary.model.claude",
        "weeklySummary.model.codex",
        "weeklySummary.efforts",
        "weeklySummary.customModels.claude",
        "weeklySummary.customModels.codex"
    ]
}
