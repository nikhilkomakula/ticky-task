import SwiftUI
import Foundation

/// Presents the Weekly Summary with a fresh session per opening.
struct WeeklySummarySheet: View {
    @State private var session: WeeklySummarySession

    init(weekAnchor: Date) {
        let dependencies = WeeklySummaryDependencies.make()
        _session = State(initialValue: WeeklySummarySession(
            weekAnchor: weekAnchor,
            generator: dependencies.generator,
            catalog: dependencies.catalog
        ))
    }

    var body: some View {
        WeeklySummaryView(session: session)
    }
}

/// Builds the generator + model catalog: the real CLIs normally, deterministic
/// stubs under `-uitest` so UI tests never call an AI provider.
enum WeeklySummaryDependencies {
    struct Bundle {
        var generator: SummaryGenerating
        var catalog: SummaryModelCatalogProviding
    }

    @MainActor
    static func make() -> Bundle {
        if UITestSupport.isRunning {
            return Bundle(generator: StubSummaryGenerator(failure: UITestSupport.summaryFailure, delay: UITestSupport.summaryDelay),
                          catalog: StubSummaryModelCatalog())
        }
        return live
    }

    /// Shared so the per-launch caches (CLI version, verified isolation flags,
    /// model lists) survive reopening the sheet.
    @MainActor static let live: Bundle = {
        let runner = CLIProcessRunner()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let resolve: @Sendable () async throws -> URL = {
            try await CLIExecutableResolver.resolve(name: "codex", override: SummaryPreferences().cliPathOverride,
                                                    probe: .system)
        }
        let environment: @Sendable (URL) async -> [String: String] = { executable in
            CLIChildEnvironment.make(for: executable, home: home)
        }
        let apiKey: @Sendable () -> String? = { SummaryKeychain().read() }
        LiveSummaryGenerator.removeStaleRuns()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return Bundle(
            generator: LiveSummaryGenerator(runner: runner, resolveExecutable: resolve, environment: environment,
                                            localAPIKey: apiKey),
            catalog: SummaryModelCatalog(
                runner: runner, resolveExecutable: resolve, environment: environment, localAPIKey: apiKey,
                cacheDirectory: caches.appendingPathComponent(Foundation.Bundle.main.bundleIdentifier ?? "com.tickytask.mac")
                    .appendingPathComponent("model-catalog", isDirectory: true)
            )
        )
    }()
}

/// The child environment for a CLI. The Homebrew/npm `codex` wrapper is a Node
/// script, so `node` must be on the child's PATH even though a GUI app doesn't
/// inherit the shell's.
enum CLIChildEnvironment {
    static func make(for executable: URL, home: String,
                     base: [String: String] = ProcessInfo.processInfo.environment,
                     isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                     listDirectory: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }) -> [String: String] {
        let nodeDirectory = CLIExecutableResolver.needsNode(executable)
            ? nodeDirectory(home: home, isExecutableFile: isExecutableFile, listDirectory: listDirectory)
            : nil
        return CLIExecutableResolver.childEnvironment(for: executable, nodeDirectory: nodeDirectory, base: base, home: home)
    }

    /// Common Node install locations, including the newest nvm-managed version.
    static func nodeDirectory(home: String,
                              isExecutableFile: (String) -> Bool,
                              listDirectory: (String) -> [String]) -> String? {
        var candidates = CLIExecutableResolver.candidatePaths(for: "node", home: home)
            .map { ($0 as NSString).deletingLastPathComponent }
        let nvmRoot = "\(home)/.nvm/versions/node"
        let versions = listDirectory(nvmRoot).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        candidates += versions.map { "\(nvmRoot)/\($0)/bin" }
        return candidates.first { isExecutableFile("\($0)/node") }
    }
}

// MARK: - UI-test stubs

/// Deterministic generator for XCUITests: echoes the selected task titles, or
/// fails with the requested error, after a short delay so Cancel is testable.
struct StubSummaryGenerator: SummaryGenerating {
    var failure: WeeklySummaryError?
    var delay: Duration = .milliseconds(600)

    func generate(_ request: SummaryRequest) async throws -> SummaryResult {
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        let root = (try? JSONSerialization.jsonObject(with: request.payload)) as? [String: Any]
        let groups = root?["taskGroups"] as? [[String: Any]] ?? []
        let titles = groups.flatMap { ($0["records"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String } }
        let text = """
        Summary

        Stub summary covering \(titles.count) selected task\(titles.count == 1 ? "" : "s").

        Progress & accomplishments

        \(titles.map { "- \($0)" }.joined(separator: "\n"))
        """
        return SummaryResult(text: text, config: request.config, resolvedModel: request.config.modelID,
                             duration: .seconds(1), usage: nil)
    }

    func authSetup(for connection: SummaryConnectionTarget) async -> SummaryAuthSetup {
        .customProvider(name: "Stub Gateway")
    }

    func accountStatus() async -> SummaryAccountStatus { .signedIn("Logged in using ChatGPT (stub)") }
    func signIn() async throws {}
}

struct StubSummaryModelCatalog: SummaryModelCatalogProviding {
    func models(for connection: SummaryConnectionTarget, refresh: Bool) async throws -> SummaryModelList {
        if connection.isLocal {
            return SummaryModelList(models: [
                .cliDefault,
                SummaryModelOption(id: "llama3.1:8b", label: "llama3.1:8b", source: .catalog, supportedEfforts: nil, defaultEffort: nil),
            ], refreshedAt: nil, sourceDescription: "UI test stub (local)")
        }
        return SummaryModelList(models: [
            .cliDefault,
            SummaryModelOption(id: "gpt-5.5", label: "GPT-5.5", source: .catalog,
                               supportedEfforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
            SummaryModelOption(id: "system.ai.glm-5-2", label: "GLM 5.2", source: .catalog,
                               supportedEfforts: ["high", "max"], defaultEffort: "max"),
        ], refreshedAt: nil, sourceDescription: "UI test stub")
    }
}
