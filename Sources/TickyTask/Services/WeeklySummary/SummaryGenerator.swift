import Foundation

/// Drives the real `claude` / `codex` CLIs. Each run gets a fresh private
/// working directory; Codex runs are preceded by a model-free compatibility
/// check of the isolation flags, so a summary never runs with tools enabled.
struct LiveSummaryGenerator: SummaryGenerating {
    /// App policy: high-effort reasoning can be quiet for minutes, so there's no
    /// inactivity timeout — only this overall deadline.
    static let generationTimeout: Duration = .seconds(300)

    let runner: CLICommandRunning
    let resolveExecutable: @Sendable (SummaryProvider) async throws -> URL
    let environment: @Sendable (URL) async -> [String: String]
    let runRoot: URL
    let home: String
    private let cache = CLIInfoCache()

    init(runner: CLICommandRunning,
         resolveExecutable: @escaping @Sendable (SummaryProvider) async throws -> URL,
         environment: @escaping @Sendable (URL) async -> [String: String],
         runRoot: URL = LiveSummaryGenerator.defaultRunRoot,
         home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.runner = runner
        self.resolveExecutable = resolveExecutable
        self.environment = environment
        self.runRoot = runRoot
        self.home = home
    }

    static var defaultRunRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tickytask.mac")
            .appendingPathComponent("weekly-summary", isDirectory: true)
    }

    /// Removes run directories left behind by a crash or force-quit.
    static func removeStaleRuns(at root: URL = defaultRunRoot) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries { try? fm.removeItem(at: entry) }
    }

    func generate(_ request: SummaryRequest) async throws -> SummaryResult {
        let provider = request.config.provider
        let executable = try await resolve(provider)
        let env = await environment(executable)
        let version = await cache.version(for: executable) { await readVersion(executable, env: env) }
        let runDirectory = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        do {
            switch provider {
            case .claude:
                let output = try await runner.run(CLIInvocation(
                    executableURL: executable,
                    arguments: ClaudeSummaryAdapter.arguments(config: request.config, instructions: request.instructions),
                    stdin: request.payload,
                    workingDirectory: runDirectory,
                    environment: env,
                    timeout: Self.generationTimeout
                ))
                return try ClaudeSummaryAdapter.parse(output, config: request.config, cliVersion: version,
                                                      executablePath: executable.path).get()

            case .codex:
                let servers = try await codexMCPServers(executable, env: env, workingDirectory: runDirectory, version: version)
                try await verifyCodexIsolation(executable, env: env, workingDirectory: runDirectory,
                                               servers: servers, version: version)
                let lastMessage = runDirectory.appendingPathComponent("last-message.txt")
                let output = try await runner.run(CLIInvocation(
                    executableURL: executable,
                    arguments: CodexSummaryAdapter.arguments(config: request.config, lastMessagePath: lastMessage.path,
                                                             mcpServerNames: servers),
                    stdin: SummaryPrompt.codexStdin(payload: request.payload),
                    workingDirectory: runDirectory,
                    environment: env,
                    timeout: Self.generationTimeout
                ))
                let message = try? String(contentsOf: lastMessage, encoding: .utf8)
                return try CodexSummaryAdapter.parse(output, lastMessage: message, config: request.config,
                                                     cliVersion: version, executablePath: executable.path).get()
            }
        } catch let error as CLIProcessError {
            throw Self.map(error, provider: provider, executable: executable, version: version)
        }
    }

    func authSetup(for provider: SummaryProvider) async -> SummaryAuthSetup {
        switch provider {
        case .claude:
            guard let executable = try? await resolve(.claude) else { return .unknown }
            let env = await environment(executable)
            let status = try? await runner.run(CLIInvocation(
                executableURL: executable, arguments: ["auth", "status", "--json"],
                workingDirectory: FileManager.default.temporaryDirectory, environment: env,
                timeout: .seconds(15), stdoutLimit: 64 * 1024
            ))
            return SummaryAuthSetup.claude(authStatusJSON: status?.succeeded == true ? status?.stdout : nil,
                                           baseURL: ClaudeSettingsEnvironment.baseURL(home: home))
        case .codex:
            let config = try? String(contentsOfFile: "\(home)/.codex/config.toml", encoding: .utf8)
            return SummaryAuthSetup.codex(configTOML: config)
        }
    }

    // MARK: - Steps

    private func resolve(_ provider: SummaryProvider) async throws -> URL {
        do {
            return try await resolveExecutable(provider)
        } catch CLIResolutionError.invalidOverride(let path) {
            throw WeeklySummaryError.invalidCLIPath(provider, path: path)
        } catch is CLIResolutionError {
            throw WeeklySummaryError.cliNotFound(provider)
        }
    }

    private func readVersion(_ executable: URL, env: [String: String]) async -> String? {
        guard let output = try? await runner.run(CLIInvocation(
            executableURL: executable, arguments: ["--version"],
            workingDirectory: FileManager.default.temporaryDirectory, environment: env,
            timeout: .seconds(15), stdoutLimit: 16 * 1024
        )), output.succeeded else { return nil }
        let line = output.stdoutText.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.trimmingCharacters(in: .whitespaces)
    }

    /// Every configured MCP server, so each can be disabled for this run. A
    /// version that can't list them can't be isolated → incompatible.
    private func codexMCPServers(_ executable: URL, env: [String: String], workingDirectory: URL,
                                 version: String?) async throws -> [String] {
        let output = try await runner.run(CLIInvocation(
            executableURL: executable, arguments: CodexSummaryAdapter.mcpListArguments,
            workingDirectory: workingDirectory, environment: env, timeout: .seconds(30), stdoutLimit: 1024 * 1024
        ))
        guard output.succeeded else {
            throw WeeklySummaryError.cliIncompatible(.codex, Self.detail(output, prefix: "`codex mcp list --json` failed.",
                                                                         executable: executable, version: version))
        }
        return CodexSummaryAdapter.mcpServerNames(fromListJSON: output.stdout)
    }

    private func verifyCodexIsolation(_ executable: URL, env: [String: String], workingDirectory: URL,
                                      servers: [String], version: String?) async throws {
        let key = "\(executable.path)|\(version ?? "?")|\(servers.sorted().joined(separator: ","))"
        if await cache.isolationVerified(key) { return }
        let output = try await runner.run(CLIInvocation(
            executableURL: executable, arguments: CodexSummaryAdapter.preflightArguments(mcpServerNames: servers),
            workingDirectory: workingDirectory, environment: env, timeout: .seconds(30), stdoutLimit: 4 * 1024 * 1024
        ))
        guard output.succeeded else {
            throw WeeklySummaryError.cliIncompatible(.codex, Self.detail(output, prefix: "Codex rejected TickyTask's isolation options.",
                                                                         executable: executable, version: version))
        }
        await cache.markIsolationVerified(key)
    }

    private func makeRunDirectory() throws -> URL {
        let directory = runRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func detail(_ output: CLIProcessOutput, prefix: String, executable: URL, version: String?) -> SummaryErrorDetail {
        let message = ClaudeSummaryAdapter.joined(prefix, output.stderrText, fallback: prefix)
        return SummaryErrorDetail(message: SummaryRedactor.redact(String(message.prefix(4000))), exitCode: output.exitCode,
                                  cliVersion: version, executablePath: executable.path)
    }

    private static func map(_ error: CLIProcessError, provider: SummaryProvider, executable: URL, version: String?) -> WeeklySummaryError {
        switch error {
        case .cancelled: .cancelled
        case .timedOut(let seconds): .timedOut(seconds: seconds)
        case .outputTooLarge(let limit):
            .invalidResponse(provider, SummaryErrorDetail(message: "The CLI produced more than \(limit / 1024 / 1024) MB of output.",
                                                          cliVersion: version, executablePath: executable.path))
        case .launchFailed(let message):
            .launchFailed(provider, SummaryErrorDetail(message: message, cliVersion: version, executablePath: executable.path))
        }
    }
}

/// Per-launch memo of CLI versions and verified isolation flag sets.
private actor CLIInfoCache {
    private var versions: [String: String?] = [:]
    private var verified: Set<String> = []

    func version(for executable: URL, read: () async -> String?) async -> String? {
        if let cached = versions[executable.path] { return cached }
        let value = await read()
        versions[executable.path] = value
        return value
    }

    func isolationVerified(_ key: String) -> Bool { verified.contains(key) }
    func markIsolationVerified(_ key: String) { verified.insert(key) }
}

/// The Anthropic base URL configured for the Claude CLI (admin policy first,
/// then user settings) — signals a gateway setup for auth remediation.
enum ClaudeSettingsEnvironment {
    static let managedSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"

    static func baseURL(home: String, readFile: (String) -> Data? = { FileManager.default.contents(atPath: $0) }) -> String? {
        for path in [managedSettingsPath, "\(home)/.claude/settings.json"] {
            guard let data = readFile(path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let env = root["env"] as? [String: Any],
                  let url = env["ANTHROPIC_BASE_URL"] as? String, !url.isEmpty else { continue }
            return url
        }
        return nil
    }
}
