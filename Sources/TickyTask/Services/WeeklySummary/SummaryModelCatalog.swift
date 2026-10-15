import Foundation

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

/// Model lists per connection, with an explicit refresh. An actor, because the
/// in-memory cache is shared by concurrent refreshes from the sheet and Settings.
actor SummaryModelCatalog: SummaryModelCatalogProviding {
    private let runner: CLICommandRunning
    private let resolveExecutable: @Sendable () async throws -> URL
    private let environment: @Sendable (URL) async -> [String: String]
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let localAPIKey: @Sendable () -> String?
    private let cacheDirectory: URL
    private let now: @Sendable () -> Date
    private var memory: [String: SummaryModelList] = [:]
    private var latestFetch: [String: Int] = [:]

    init(runner: CLICommandRunning,
         resolveExecutable: @escaping @Sendable () async throws -> URL,
         environment: @escaping @Sendable (URL) async -> [String: String],
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         localAPIKey: @escaping @Sendable () -> String? = { nil },
         cacheDirectory: URL,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.resolveExecutable = resolveExecutable
        self.environment = environment
        self.fetch = fetch
        self.localAPIKey = localAPIKey
        self.cacheDirectory = cacheDirectory
        self.now = now
    }

    func models(for connection: SummaryConnectionTarget, refresh: Bool) async throws -> SummaryModelList {
        let key = connection.catalogKey
        if !refresh, let cached = memory[key] { return cached }
        if !refresh, !connection.isLocal, let disk = loadDisk(key) {
            memory[key] = disk
            return disk
        }
        // Fetches can overlap (the actor is reentrant across awaits); only the
        // newest one per list may update the cache.
        let fetchID = (latestFetch[key] ?? 0) + 1
        latestFetch[key] = fetchID
        do {
            let list = connection.isLocal ? try await fetchLocal(connection) : try await fetchCodex(connection)
            if latestFetch[key] == fetchID {
                memory[key] = list
                if !connection.isLocal { try? saveDisk(list, key: key) }
            }
            return list
        } catch {
            // A failed refresh keeps the last good list usable.
            // It stays marked stale until a refresh succeeds.
            if let previous = memory[key] ?? (connection.isLocal ? nil : loadDisk(key)) {
                var stale = previous
                stale.isStale = true
                if latestFetch[key] == fetchID { memory[key] = stale }
                return stale
            }
            throw error
        }
    }

    // MARK: - Codex catalog (ChatGPT account / CLI configuration)

    private func fetchCodex(_ connection: SummaryConnectionTarget) async throws -> SummaryModelList {
        let executable: URL
        do {
            executable = try await resolveExecutable()
        } catch CLIResolutionError.invalidOverride(let path) {
            throw WeeklySummaryError.invalidCLIPath(.codex, path: path)
        } catch {
            throw WeeklySummaryError.cliNotFound(.codex)
        }
        let connectionArgs = (try? SummaryConnectionArguments.codexArguments(for: connection, hasAPIKey: false)) ?? []
        let output: CLIProcessOutput
        do {
            output = try await runner.run(CLIInvocation(
                executableURL: executable,
                arguments: ["debug", "models"] + connectionArgs,
                workingDirectory: FileManager.default.temporaryDirectory,
                environment: await environment(executable),
                timeout: .seconds(30),
                stdoutLimit: 16 * 1024 * 1024
            ))
        } catch CLIProcessError.timedOut(let seconds) {
            throw WeeklySummaryError.timedOut(seconds: seconds)
        } catch {
            throw WeeklySummaryError.cliFailed(.codex, SummaryErrorDetail(message: "Couldn't run `codex debug models`: \(error)"))
        }
        guard output.succeeded else {
            throw WeeklySummaryError.cliFailed(.codex, SummaryErrorDetail(
                message: SummaryRedactor.redact(String(output.stderrText.suffix(2048))), exitCode: output.exitCode))
        }
        return SummaryModelList(
            models: try CodexModelCatalogParser.options(fromCatalogJSON: output.stdout),
            refreshedAt: now(),
            sourceDescription: connection == .chatGPTAccount ? "codex debug models (ChatGPT account)" : "codex debug models"
        )
    }

    // MARK: - Local server

    private func fetchLocal(_ connection: SummaryConnectionTarget) async throws -> SummaryModelList {
        guard let baseURL = connection.localBaseURL else {
            throw WeeklySummaryError.configurationRejected(.codex, SummaryErrorDetail(
                message: "Enter the server's base URL (for example http://localhost:8000/v1) in Settings › AI."))
        }
        let apiKey = localAPIKey()   // the key actually sent, so it's the one scrubbed from errors
        let ids: [String]
        do {
            let request = try LocalModelListing.request(baseURL: baseURL, apiKey: apiKey)
            let (data, response) = try await fetch(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let status = http.statusCode
                let redactedURL = SummaryRedactor.redact(baseURL)
                let message = "The local server at \(redactedURL) answered HTTP \(status) for /models."
                let detail = SummaryErrorDetail(message: message, httpStatus: status)
                switch status {
                case 401, 403: throw WeeklySummaryError.authenticationRejected(.codex, detail)
                case 429: throw WeeklySummaryError.rateLimited(.codex, detail)
                default: throw WeeklySummaryError.providerUnavailable(.codex, detail)
                }
            }
            do {
                ids = try LocalModelListing.parse(data)
            } catch {
                throw WeeklySummaryError.invalidResponse(.codex, SummaryErrorDetail(
                    message: "The local server's /models reply isn't an OpenAI-style model list."))
            }
        } catch let error as WeeklySummaryError {
            throw error
        } catch is SummaryConnectionArguments.ValidationError {
            let redactedURL = SummaryRedactor.redact(baseURL)
            throw WeeklySummaryError.configurationRejected(.codex, SummaryErrorDetail(
                message: "“\(redactedURL)” isn't a valid http(s) URL."))
        } catch {
            let redactedURL = SummaryRedactor.redact(baseURL)
            throw WeeklySummaryError.networkFailure(.codex, SummaryErrorDetail(
                message: "Couldn't reach the local server at \(redactedURL): "
                    + SummaryRedactor.redact(error.localizedDescription, removing: [apiKey ?? ""])))
        }
        let options = ids.map {
            SummaryModelOption(id: $0, label: $0, source: .catalog, supportedEfforts: nil, defaultEffort: nil)
        }
        let redactedURL = SummaryRedactor.redact(baseURL)
        return SummaryModelList(models: [.cliDefault] + options, refreshedAt: now(),
                                sourceDescription: "\(connection.label) at \(redactedURL)")
    }

    // MARK: - Compact disk cache

    private func cacheURL(_ key: String) -> URL {
        cacheDirectory.appendingPathComponent("codex-models-\(key).json")
    }

    private func loadDisk(_ key: String) -> SummaryModelList? {
        guard let data = try? Data(contentsOf: cacheURL(key)) else { return nil }
        return try? JSONDecoder().decode(SummaryModelList.self, from: data)
    }

    private func saveDisk(_ list: SummaryModelList, key: String) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: cacheURL(key), options: .atomic)
    }
}
