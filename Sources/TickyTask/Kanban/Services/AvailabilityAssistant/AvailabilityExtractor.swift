import Foundation

protocol AvailabilityExtractorProcessRunning: Sendable {
    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput
}

/// Runs the LLM extraction for availability using the same Codex isolation as summaries.
struct AvailabilityExtractor {
    static let extractionTimeout: Duration = .seconds(300)

    let runner: AvailabilityExtractorProcessRunning
    let resolveExecutable: @Sendable () async throws -> URL
    let environment: @Sendable (URL) async -> [String: String]
    let localAPIKey: @Sendable () -> String?
    let runRoot: URL
    let home: String

    init(runner: AvailabilityExtractorProcessRunning,
         resolveExecutable: @escaping @Sendable () async throws -> URL,
         environment: @escaping @Sendable (URL) async -> [String: String],
         localAPIKey: @escaping @Sendable () -> String? = { nil },
         runRoot: URL = Self.defaultRunRoot,
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
            .appendingPathComponent("availability-extraction", isDirectory: true)
    }

    static func removeStaleRuns(at root: URL = defaultRunRoot) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries { try? fm.removeItem(at: entry) }
    }

    /// Extract availability from the request.
    func extract(_ request: AvailabilityPromptBuilder.Request,
                config: SummaryRunConfig) async throws -> AvailabilityExtractionContract {
        let executable = try await resolveExecutable()
        let connection = config.connection
        let apiKey = connection.isLocal ? localAPIKey() : nil
        var inherited = await environment(executable)
        if connection.isLocal { SummaryConnectionArguments.inheritedLocalOverrides.forEach { inherited[$0] = nil } }
        let env = inherited.merging(SummaryConnectionArguments.environment(for: connection, apiKey: apiKey)) { _, new in new }

        let runDirectory = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        do {
            let servers = try await mcpServers(executable, env: env, workingDirectory: runDirectory)
            try await verifyIsolation(executable, env: env, workingDirectory: runDirectory, servers: servers)

            // Stage images
            let stagedImages = try stageImages(request.imagePaths, into: runDirectory)

            let lastMessage = runDirectory.appendingPathComponent("last-message.json")
            let arguments = try buildArguments(config: config, lastMessagePath: lastMessage.path,
                                              mcpServerNames: servers, hasAPIKey: apiKey != nil,
                                              stagedImages: stagedImages)

            let prompt = AvailabilityPromptBuilder.build(request: request)

            let output = try await runner.run(CLIInvocation(
                executableURL: executable,
                arguments: arguments,
                stdin: prompt.data(using: .utf8) ?? Data(),
                workingDirectory: runDirectory,
                environment: env,
                timeout: Self.extractionTimeout
            ))

            let response = try? Data(contentsOf: lastMessage)
            return try parseResponse(output, responseData: response, config: config, executable: executable)
        }
    }

    private func buildArguments(config: SummaryRunConfig,
                               lastMessagePath: String,
                               mcpServerNames: [String],
                               hasAPIKey: Bool,
                               stagedImages: [String]) throws -> [String] {
        var args = ["exec", "--json", "--skip-git-repo-check", "--ephemeral",
                    "-s", "read-only", "--color", "never"]
        args += try SummaryConnectionArguments.codexArguments(for: config.connection, hasAPIKey: hasAPIKey)
        args += CodexSummaryAdapter.isolationArguments(mcpServerNames: mcpServerNames)
        if let model = config.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            args += ["-m", model]
        }
        if let effort = config.effort, CodexSummaryAdapter.isSafeConfigToken(effort) {
            args += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
        // Attach images
        for imagePath in stagedImages {
            args += ["-i", imagePath]
        }
        args += ["-o", lastMessagePath, "-"]
        return args
    }

    private func stageImages(_ paths: [String], into directory: URL) throws -> [String] {
        var staged: [String] = []
        for (i, path) in paths.enumerated() {
            let srcURL = URL(fileURLWithPath: path)
            let destName = "image-\(i + 1)\(srcURL.pathExtension.isEmpty ? "" : ".")\(srcURL.pathExtension)"
            let destURL = directory.appendingPathComponent(destName)
            try FileManager.default.copyItem(at: srcURL, to: destURL)
            staged.append(destURL.path)
        }
        return staged
    }

    private func parseResponse(_ output: CLIProcessOutput,
                              responseData: Data?,
                              config: SummaryRunConfig,
                              executable: URL) throws -> AvailabilityExtractionContract {
        guard output.succeeded else {
            let events = CodexSummaryAdapter.Events(jsonl: output.stdout)
            let message = events.turnFailure ?? events.lastError ?? "Extraction failed"
            throw AvailabilityExtractionError.extractionFailed(message)
        }

        guard let data = responseData else {
            throw AvailabilityExtractionError.emptyResponse
        }

        switch AvailabilityContractValidator.validate(data) {
        case .success(let result):
            // Reconstruct the contract for the caller
            return .init(schemaVersion: 1, entries: result.entries.map { entry in
                .init(sourceRef: entry.sourceRef, personText: entry.personText,
                      startDate: entry.startDate.key, endDate: entry.endDate.key,
                      portion: entry.portion.rawValue, kind: entry.kind.rawValue,
                      dateText: entry.dateText, evidence: entry.evidence,
                      confidence: entry.confidence.rawValue, issues: entry.issues)
            }, unresolved: result.unresolved.map { .init(sourceRef: $0.sourceRef, evidence: $0.evidence, issues: $0.issues) },
            warnings: result.issues)
        case .failure(let error):
            throw AvailabilityExtractionError.invalidContract(error.localizedDescription)
        }
    }

    // MARK: - Helpers (same as summary)

    private func mcpServers(_ executable: URL, env: [String: String], workingDirectory: URL) async throws -> [String] {
        let output = try await runner.run(CLIInvocation(
            executableURL: executable, arguments: CodexSummaryAdapter.mcpListArguments,
            workingDirectory: workingDirectory, environment: env, timeout: .seconds(30), stdoutLimit: 1024 * 1024
        ))
        guard output.succeeded else {
            throw AvailabilityExtractionError.cliIncompatible("MCP list failed")
        }
        return try CodexSummaryAdapter.mcpServerNames(fromListJSON: output.stdout)
    }

    private func verifyIsolation(_ executable: URL, env: [String: String], workingDirectory: URL,
                                servers: [String]) async throws {
        let output = try await runner.run(CLIInvocation(
            executableURL: executable, arguments: CodexSummaryAdapter.preflightArguments(mcpServerNames: servers),
            workingDirectory: workingDirectory, environment: env, timeout: .seconds(30), stdoutLimit: 4 * 1024 * 1024
        ))
        guard output.succeeded else {
            throw AvailabilityExtractionError.cliIncompatible("Isolation flags rejected")
        }
    }

    private func makeRunDirectory() throws -> URL {
        let directory = runRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func resolveExecutable() async throws -> URL {
        do {
            return try await resolveExecutable()
        } catch CLIResolutionError.invalidOverride(let path) {
            throw AvailabilityExtractionError.invalidCLIPath(path)
        } catch is CLIResolutionError {
            throw AvailabilityExtractionError.cliNotFound
        }
    }
}

enum AvailabilityExtractionError: LocalizedError, Sendable {
    case cliNotFound
    case invalidCLIPath(String)
    case cliIncompatible(String)
    case extractionFailed(String)
    case emptyResponse
    case invalidContract(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Codex CLI not found"
        case .invalidCLIPath(let path):
            return "Invalid Codex path: \(path)"
        case .cliIncompatible(let msg):
            return "Codex incompatible: \(msg)"
        case .extractionFailed(let msg):
            return "Extraction failed: \(msg)"
        case .emptyResponse:
            return "No response from extraction"
        case .invalidContract(let msg):
            return "Invalid response format: \(msg)"
        }
    }
}
