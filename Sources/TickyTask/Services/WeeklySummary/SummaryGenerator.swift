import Foundation

/// Drives the real `codex` CLI. Each run gets a fresh private working
/// directory and is preceded by a model-free compatibility check of the
/// isolation flags, so a summary never runs with tools enabled.
struct LiveSummaryGenerator: SummaryGenerating {
    /// App policy: high-effort reasoning can be quiet for minutes, so there's no
    /// inactivity timeout — only this overall deadline.
    static let generationTimeout: Duration = .seconds(300)
    /// `codex login` waits for the browser sign-in to complete.
    static let signInTimeout: Duration = .seconds(600)

    let runner: CLICommandRunning
    let resolveExecutable: @Sendable () async throws -> URL
    let environment: @Sendable (URL) async -> [String: String]
    /// The local server API key (from the Keychain), read at run time only.
    let localAPIKey: @Sendable () -> String?
    let runRoot: URL
    let home: String
    private let cache = CLIInfoCache()

    init(runner: CLICommandRunning,
         resolveExecutable: @escaping @Sendable () async throws -> URL,
         environment: @escaping @Sendable (URL) async -> [String: String],
         localAPIKey: @escaping @Sendable () -> String? = { nil },
         runRoot: URL = LiveSummaryGenerator.defaultRunRoot,
         home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.runner = runner
        self.resolveExecutable = resolveExecutable
        self.environment = environment
        self.localAPIKey = localAPIKey
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
        let executable = try await resolve()
        let connection = request.config.connection
        let apiKey = connection.isLocal ? localAPIKey() : nil
        var inherited = await environment(executable)
        if connection.isLocal { SummaryConnectionArguments.inheritedLocalOverrides.forEach { inherited[$0] = nil } }
        let env = inherited.merging(SummaryConnectionArguments.environment(for: connection, apiKey: apiKey)) { _, new in new }
        let version = await cache.version(for: executable) { await readVersion(executable, env: env) }
        let runDirectory = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        do {
            let servers = try await mcpServers(executable, env: env, workingDirectory: runDirectory, version: version)
            try await verifyIsolation(executable, env: env, workingDirectory: runDirectory, servers: servers, version: version)
            let lastMessage = runDirectory.appendingPathComponent("last-message.txt")
            let arguments: [String]
            do {
                arguments = try CodexSummaryAdapter.arguments(config: request.config, lastMessagePath: lastMessage.path,
                                                              mcpServerNames: servers, hasAPIKey: apiKey != nil)
            } catch {
                // Never fall back to a bare invocation: that would drop the isolation flags.
                throw WeeklySummaryError.configurationRejected(.codex, SummaryErrorDetail(
                    message: "The local server address isn't a valid http(s) URL. Check Settings › AI.",
                    cliVersion: version, executablePath: executable.path))
            }
            let output = try await runner.run(CLIInvocation(
                executableURL: executable,
                arguments: arguments,
                stdin: SummaryPrompt.codexStdin(instructions: request.instructions, payload: request.payload),
                workingDirectory: runDirectory,
                environment: env,
                timeout: Self.generationTimeout
            ))
            let message = try? String(contentsOf: lastMessage, encoding: .utf8)
            // The key is removed from the decoded failure text, so a provider echoing
            // it back can't put it in any part of the details.
            return try CodexSummaryAdapter.parse(output, lastMessage: message, config: request.config,
                                                 cliVersion: version, executablePath: executable.path,
                                                 secrets: [apiKey ?? ""]).get()
        } catch let error as CLIProcessError {
            throw Self.map(error, executable: executable, version: version)
        }
    }

    func authSetup(for connection: SummaryConnectionTarget) async -> SummaryAuthSetup {
        switch connection {
        case .chatGPTAccount:
            return .accountLogin
        case .local(let server, _):
            return .customProvider(name: server.displayName)
        case .cliConfiguration:
            let config = try? String(contentsOfFile: "\(home)/.codex/config.toml", encoding: .utf8)
            return SummaryAuthSetup.codex(configTOML: config)
        }
    }

    func accountStatus() async -> SummaryAccountStatus {
        guard let executable = try? await resolve() else { return .unknown }
        let env = await environment(executable)
        guard let output = try? await runner.run(CLIInvocation(
            executableURL: executable, arguments: CodexSummaryAdapter.loginStatusArguments,
            workingDirectory: FileManager.default.temporaryDirectory, environment: env,
            timeout: .seconds(20), stdoutLimit: 64 * 1024
        )) else { return .unknown }
        return CodexSummaryAdapter.accountStatus(from: output)
    }

    func signIn() async throws {
        let executable = try await resolve()
        let env = await environment(executable)
        let output: CLIProcessOutput
        do {
            output = try await runner.run(CLIInvocation(
                executableURL: executable, arguments: CodexSummaryAdapter.loginArguments,
                workingDirectory: FileManager.default.temporaryDirectory, environment: env,
                timeout: Self.signInTimeout, stdoutLimit: 1024 * 1024
            ))
        } catch let error as CLIProcessError {
            throw Self.map(error, executable: executable, version: nil)
        }
        guard output.succeeded else {
            throw WeeklySummaryError.notSignedIn(.codex, SummaryErrorDetail(
                message: SummaryRedactor.redact(CodexSummaryAdapter.joined(output.stderrText, output.stdoutText,
                                                                            fallback: "codex login did not complete.")),
                exitCode: output.exitCode, executablePath: executable.path))
        }
    }

    // MARK: - Steps

    private func resolve() async throws -> URL {
        do {
            return try await resolveExecutable()
        } catch CLIResolutionError.invalidOverride(let path) {
            throw WeeklySummaryError.invalidCLIPath(.codex, path: path)
        } catch is CLIResolutionError {
            throw WeeklySummaryError.cliNotFound(.codex)
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
    private func mcpServers(_ executable: URL, env: [String: String], workingDirectory: URL,
                            version: String?) async throws -> [String] {
        let output = try await runner.run(CLIInvocation(
            executableURL: executable, arguments: CodexSummaryAdapter.mcpListArguments,
            workingDirectory: workingDirectory, environment: env, timeout: .seconds(30), stdoutLimit: 1024 * 1024
        ))
        guard output.succeeded else {
            throw WeeklySummaryError.cliIncompatible(.codex, Self.detail(output, secret: env[SummaryConnectionArguments.apiKeyVariable], prefix: "`codex mcp list --json` failed.",
                                                                         executable: executable, version: version))
        }
        do {
            return try CodexSummaryAdapter.mcpServerNames(fromListJSON: output.stdout)
        } catch {
            throw WeeklySummaryError.cliIncompatible(.codex, Self.detail(output, secret: env[SummaryConnectionArguments.apiKeyVariable], prefix: "MCP server list has an unsupported schema.",
                                                                         executable: executable, version: version))
        }
    }

    private func verifyIsolation(_ executable: URL, env: [String: String], workingDirectory: URL,
                                 servers: [String], version: String?) async throws {
        let key = "\(executable.path)|\(version ?? "?")|\(servers.sorted().joined(separator: ","))"
        if await cache.isolationVerified(key) { return }
        let output = try await runner.run(CLIInvocation(
            executableURL: executable, arguments: CodexSummaryAdapter.preflightArguments(mcpServerNames: servers),
            workingDirectory: workingDirectory, environment: env, timeout: .seconds(30), stdoutLimit: 4 * 1024 * 1024
        ))
        guard output.succeeded else {
            throw WeeklySummaryError.cliIncompatible(.codex, Self.detail(output, secret: env[SummaryConnectionArguments.apiKeyVariable], prefix: "Codex rejected TickyTask's isolation options.",
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

    private static func detail(_ output: CLIProcessOutput, secret: String?, prefix: String,
                               executable: URL, version: String?) -> SummaryErrorDetail {
        let message = SummaryRedactor.redact(CodexSummaryAdapter.joined(prefix, output.stderrText, fallback: prefix),
                                             removing: [secret ?? ""])
        return SummaryErrorDetail(message: String(message.prefix(4000)), exitCode: output.exitCode,
                                  cliVersion: version, executablePath: executable.path)
    }

    private static func map(_ error: CLIProcessError, executable: URL, version: String?) -> WeeklySummaryError {
        switch error {
        case .cancelled: .cancelled
        case .timedOut(let seconds): .timedOut(seconds: seconds)
        case .outputTooLarge(let limit):
            .invalidResponse(.codex, SummaryErrorDetail(message: "The CLI produced more than \(limit / 1024 / 1024) MB of output.",
                                                        cliVersion: version, executablePath: executable.path))
        case .launchFailed(let message):
            .launchFailed(.codex, SummaryErrorDetail(message: message, cliVersion: version, executablePath: executable.path))
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
