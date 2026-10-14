import Foundation

/// Parsers for Claude and Codex model lists, agnostic of data source.
enum ClaudeModelCatalogParser {
    /// Assemble Claude options from managed-policy settings and user settings.
    /// Rules: start with `.cliDefault`; add `modelPicker.options` (policy first, then user);
    /// unless `modelPicker.replaceBuiltInOptions == true` in ANY source, append built-in aliases;
    /// add `availableModels` entries not already present. If the POLICY declares `availableModels`,
    /// use it as an allowlist (dropping built-in aliases and options not in it).
    static func options(policy: [[String: Any]], user: [[String: Any]]) -> [SummaryModelOption] {
        var result: [SummaryModelOption] = [.cliDefault]
        var seen = Set([SummaryModelOption.cliDefaultID])

        // Track whether any source sets replaceBuiltInOptions.
        var shouldReplaceBuiltInOptions = false
        var policyAllowlist: Set<String>? = nil

        // Process policy settings (applied in order).
        for dict in policy {
            if let modelPicker = dict["modelPicker"] as? [String: Any],
               let options = modelPicker["options"] as? [[String: Any]] {
                for opt in options {
                    let id = opt["model"] as? String ?? ""
                    let label = opt["label"] as? String ?? id
                    guard !id.isEmpty, !seen.contains(id) else { continue }
                    result.append(SummaryModelOption(
                        id: id, label: label, source: .policy,
                        supportedEfforts: nil, defaultEffort: nil
                    ))
                    seen.insert(id)
                }
            }
            if let modelPicker = dict["modelPicker"] as? [String: Any] {
                if modelPicker["replaceBuiltInOptions"] as? Bool == true {
                    shouldReplaceBuiltInOptions = true
                }
            }
            if let available = dict["availableModels"] as? [String] {
                policyAllowlist = Set(available)
            }
        }

        // Process user settings.
        for dict in user {
            if let modelPicker = dict["modelPicker"] as? [String: Any],
               let options = modelPicker["options"] as? [[String: Any]] {
                for opt in options {
                    let id = opt["model"] as? String ?? ""
                    let label = opt["label"] as? String ?? id
                    guard !id.isEmpty, !seen.contains(id) else { continue }
                    result.append(SummaryModelOption(
                        id: id, label: label, source: .userSettings,
                        supportedEfforts: nil, defaultEffort: nil
                    ))
                    seen.insert(id)
                }
            }
            if let modelPicker = dict["modelPicker"] as? [String: Any] {
                if modelPicker["replaceBuiltInOptions"] as? Bool == true {
                    shouldReplaceBuiltInOptions = true
                }
            }
        }

        // Add built-in aliases unless replaced.
        if !shouldReplaceBuiltInOptions {
            for (alias, label) in [
                ("opus", "Opus"),
                ("sonnet", "Sonnet"),
                ("haiku", "Haiku"),
                ("fable", "Fable")
            ] {
                guard !seen.contains(alias) else { continue }
                result.append(SummaryModelOption(
                    id: alias, label: label, source: .builtInAlias,
                    supportedEfforts: nil, defaultEffort: nil
                ))
                seen.insert(alias)
            }
        }

        // Process availableModels (not in allowlist scope if a policy allowlist exists).
        let availableToAdd = user.first.flatMap { $0["availableModels"] as? [String] } ?? []
        for id in availableToAdd {
            guard !id.isEmpty, !seen.contains(id) else { continue }
            result.append(SummaryModelOption(
                id: id, label: id, source: .userSettings,
                supportedEfforts: nil, defaultEffort: nil
            ))
            seen.insert(id)
        }

        // If a policy allowlist exists, filter to it (except cliDefault).
        if let allowlist = policyAllowlist {
            result = result.filter { $0.isCLIDefault || allowlist.contains($0.id) }
        }

        return result
    }
}

enum CodexModelCatalogParser {
    /// Parse Codex model catalog from `codex debug models` JSON output.
    /// Includes models with visibility `"list"` or absent (excludes `"hide"`).
    /// Errors on malformed top-level JSON.
    static func options(fromCatalogJSON data: Data) throws -> [SummaryModelOption] {
        var result: [SummaryModelOption] = [.cliDefault]

        // Use JSONSerialization to avoid decoding the huge `base_instructions`.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw WeeklySummaryError.cliFailed(.codex, SummaryErrorDetail(
                message: "Invalid Codex catalog JSON: missing or malformed `models` array"
            ))
        }

        for modelDict in models {
            guard let slug = modelDict["slug"] as? String, !slug.isEmpty else { continue }
            let visibility = modelDict["visibility"] as? String
            if visibility == "hide" { continue }

            let displayName = modelDict["display_name"] as? String ?? slug
            var supportedEfforts: [String]? = nil
            var defaultEffort: String? = nil

            // Parse supported_reasoning_levels (array of {effort: "x", ...} or bare strings).
            if let levels = modelDict["supported_reasoning_levels"] as? [Any] {
                var efforts: [String] = []
                for level in levels {
                    if let dict = level as? [String: Any], let effort = dict["effort"] as? String {
                        efforts.append(effort)
                    } else if let str = level as? String {
                        efforts.append(str)
                    }
                }
                if !efforts.isEmpty { supportedEfforts = efforts }
            }

            if let def = modelDict["default_reasoning_level"] as? String {
                defaultEffort = def
            }

            result.append(SummaryModelOption(
                id: slug, label: displayName, source: .catalog,
                supportedEfforts: supportedEfforts, defaultEffort: defaultEffort
            ))
        }

        return result
    }
}

/// Manages model lists for Claude and Codex, with caching and refresh.
final class SummaryModelCatalog: SummaryModelCatalogProviding, @unchecked Sendable {
    private let runner: CLICommandRunning
    private let resolveExecutable: @Sendable (SummaryProvider) async throws -> URL
    private let environment: @Sendable (URL) -> [String: String]
    private let readFile: @Sendable (String) -> Data?
    private let listDirectory: @Sendable (String) -> [String]
    private let home: String
    private let cacheDirectory: URL
    private let now: @Sendable () -> Date

    private var claudeCache: SummaryModelList?
    private var codexCache: SummaryModelList?
    private var codexDiskCacheDate: Date?

    init(runner: CLICommandRunning,
         resolveExecutable: @escaping @Sendable (SummaryProvider) async throws -> URL,
         environment: @escaping @Sendable (URL) -> [String: String],
         readFile: @escaping @Sendable (String) -> Data?,
         listDirectory: @escaping @Sendable (String) -> [String],
         home: String,
         cacheDirectory: URL,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.runner = runner
        self.resolveExecutable = resolveExecutable
        self.environment = environment
        self.readFile = readFile
        self.listDirectory = listDirectory
        self.home = home
        self.cacheDirectory = cacheDirectory
        self.now = now
    }

    func models(for provider: SummaryProvider, refresh: Bool) async throws -> SummaryModelList {
        switch provider {
        case .claude:
            return try await claudeModels(refresh: refresh)
        case .codex:
            return try await codexModels(refresh: refresh)
        }
    }

    private func claudeModels(refresh: Bool) async throws -> SummaryModelList {
        if !refresh, let cached = claudeCache {
            return cached
        }

        let homeExpanded = home.replacingOccurrences(of: "~", with: NSHomeDirectory())
        let policyPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
        let policyDropInDir = "/Library/Application Support/ClaudeCode/managed-settings.d"

        var policyDicts: [[String: Any]] = []

        // Main policy file.
        if let data = readFile(policyPath),
           let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            policyDicts.append(dict)
        }

        // Drop-in policy files (sorted by filename).
        let dropInFiles = listDirectory(policyDropInDir).sorted()
        for file in dropInFiles {
            let path = policyDropInDir + "/" + file
            if let data = readFile(path),
               let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                policyDicts.append(dict)
            }
        }

        // User settings.
        var userDicts: [[String: Any]] = []
        if let data = readFile("\(homeExpanded)/.claude/settings.json"),
           let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            userDicts.append(dict)
        }

        let options = ClaudeModelCatalogParser.options(policy: policyDicts, user: userDicts)
        var sourceDesc = "CLI default"
        if !policyDicts.isEmpty {
            sourceDesc = "Admin policy (managed-settings.json) + built-in aliases"
        }

        let list = SummaryModelList(
            models: options,
            refreshedAt: now(),
            sourceDescription: sourceDesc
        )
        claudeCache = list
        return list
    }

    private func codexModels(refresh: Bool) async throws -> SummaryModelList {
        // If not refreshing and in-memory cache exists, return it.
        if !refresh, let cached = codexCache {
            return cached
        }

        // Try to load disk cache if not refreshing and cache is available.
        if !refresh, let diskCache = try? loadCodexDiskCache() {
            codexCache = diskCache
            return diskCache
        }

        // Fetch from CLI.
        let url: URL
        do {
            url = try await resolveExecutable(.codex)
        } catch let error as CLIResolutionError {
            switch error {
            case .notFound:
                throw WeeklySummaryError.cliNotFound(.codex)
            case .invalidOverride(let path):
                throw WeeklySummaryError.invalidCLIPath(.codex, path: path)
            }
        }

        let invocation = CLIInvocation(
            executableURL: url,
            arguments: ["debug", "models"],
            workingDirectory: cacheDirectory,
            environment: environment(url),
            timeout: .seconds(30),
            stdoutLimit: 16 * 1024 * 1024
        )

        let output: CLIProcessOutput
        do {
            output = try await runner.run(invocation)
        } catch let error as CLIProcessError {
            // Try to load disk cache first.
            if codexCache == nil {
                codexCache = try? loadCodexDiskCache()
            }

            switch error {
            case .timedOut(let seconds):
                // If we have a stale cache, return it.
                if let cached = codexCache {
                    var staleCopy = cached
                    staleCopy.isStale = true
                    return staleCopy
                }
                throw WeeklySummaryError.timedOut(seconds: seconds)
            default:
                if let cached = codexCache {
                    var staleCopy = cached
                    staleCopy.isStale = true
                    return staleCopy
                }
                throw WeeklySummaryError.cliFailed(.codex, SummaryErrorDetail(
                    message: "Codex process error: \(error)"
                ))
            }
        }

        guard output.succeeded else {
            let stderr = output.stderrText.suffix(2048)
            // Try to load disk cache if we don't have it.
            if codexCache == nil {
                codexCache = try? loadCodexDiskCache()
            }

            if let cached = codexCache {
                var staleCopy = cached
                staleCopy.isStale = true
                return staleCopy
            }
            throw WeeklySummaryError.cliFailed(.codex, SummaryErrorDetail(
                message: String(stderr),
                exitCode: output.exitCode
            ))
        }

        // Parse and cache.
        let options = try CodexModelCatalogParser.options(fromCatalogJSON: output.stdout)

        let list = SummaryModelList(
            models: options,
            refreshedAt: now(),
            sourceDescription: "codex debug models"
        )
        codexCache = list

        // Write compact cache to disk.
        try saveCodexDiskCache(list)

        return list
    }

    private func loadCodexDiskCache() throws -> SummaryModelList? {
        let cachePath = cacheDirectory.appendingPathComponent("codex-models.json").path
        guard let data = readFile(cachePath) else { return nil }

        let decoder = JSONDecoder()
        let list = try decoder.decode(SummaryModelList.self, from: data)
        codexDiskCacheDate = now()
        return list
    }

    private func saveCodexDiskCache(_ list: SummaryModelList) throws {
        // Create cache directory if needed.
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(list)

        let cachePath = cacheDirectory.appendingPathComponent("codex-models.json")
        try data.write(to: cachePath, options: .atomic)
    }
}
