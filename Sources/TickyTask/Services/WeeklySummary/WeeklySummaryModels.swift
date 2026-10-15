import Foundation

// Shared contracts for the Weekly Summary feature: which CLI to use, which
// model/effort, the request handed to a generator, its result, and the typed
// failures surfaced to the user. Pure value types so they cross actors freely.

/// The local AI command-line tool that writes the summary. Weekly Summary
/// uses the Codex CLI; how Codex reaches a model is a `SummaryConnectionTarget`.
enum SummaryProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex

    var id: String { rawValue }
    var displayName: String { "Codex" }
    /// The executable name looked up on disk.
    var executableName: String { "codex" }
    /// The product name used in user-facing messages.
    var cliName: String { "Codex CLI" }
}

/// One selectable model. `id` is passed verbatim to the CLI (`--model` / `-m`);
/// the empty id means "CLI default" — omit the flag and let the CLI decide.
struct SummaryModelOption: Identifiable, Hashable, Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case cliDefault       // omit the model flag
        case policy           // admin-managed settings (e.g. Claude `modelPicker`)
        case userSettings     // user-level CLI settings
        case builtInAlias     // e.g. Claude `opus`, `sonnet`
        case catalog          // e.g. `codex debug models`
        case custom           // typed in by the user
    }

    var id: String
    var label: String
    var source: Source
    /// Effort levels the catalog says this model supports; `nil` = unknown/unverified.
    var supportedEfforts: [String]?
    /// The model's recommended effort, when the catalog provides one.
    var defaultEffort: String?

    static let cliDefaultID = ""

    static let cliDefault = SummaryModelOption(
        id: cliDefaultID, label: "CLI default", source: .cliDefault,
        supportedEfforts: nil, defaultEffort: nil
    )

    var isCLIDefault: Bool { id == Self.cliDefaultID }
}

/// The effort the user picked, kept distinct from the raw string so "use the
/// CLI's own setting" and "explicitly apply the model's default" never blur.
enum EffortChoice: Hashable, Codable, Sendable {
    /// Omit the effort flag entirely.
    case cliDefault
    /// Explicitly apply the model's recommended level (Codex: prevents inheriting
    /// an incompatible global effort from the user's config).
    case modelDefault(String)
    /// A specific level chosen by the user.
    case level(String)

    /// The value to pass to the CLI, or `nil` to omit the flag.
    var cliValue: String? {
        switch self {
        case .cliDefault: nil
        case .modelDefault(let level), .level(let level): level
        }
    }
}

/// Connection + model + effort for one generation.
struct SummaryRunConfig: Hashable, Codable, Sendable {
    var provider: SummaryProvider = .codex
    var connection: SummaryConnectionTarget = .chatGPTAccount
    /// `nil` = CLI default (omit the model flag).
    var modelID: String?
    /// `nil` = CLI default (omit the effort flag).
    var effort: String?
}

/// Model lists for each provider, with an explicit refresh.
protocol SummaryModelCatalogProviding: Sendable {
    /// Returns the selectable models for `connection` (always beginning with
    /// `SummaryModelOption.cliDefault`). `refresh` forces re-reading the source;
    /// otherwise a cached list may be returned.
    func models(for connection: SummaryConnectionTarget, refresh: Bool) async throws -> SummaryModelList
}

/// A provider's model list plus when it was last refreshed.
struct SummaryModelList: Equatable, Codable, Sendable {
    var models: [SummaryModelOption]
    var refreshedAt: Date?
    /// Human-readable description of where the list came from (shown as a tooltip).
    var sourceDescription: String
    /// True when the latest refresh failed and this is the last good list.
    var isStale: Bool = false
}

/// What a generator needs: fixed instructions, the JSON payload of selected
/// tasks (never interpolated into a shell), and the provider/model/effort.
struct SummaryRequest: Sendable, Equatable {
    var instructions: String
    var payload: Data
    var config: SummaryRunConfig
}

/// Token accounting when the CLI reports it.
struct SummaryUsage: Sendable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
}

/// A successfully generated summary.
struct SummaryResult: Sendable, Equatable {
    var text: String
    var config: SummaryRunConfig
    /// The model the CLI reports it actually used, when available.
    var resolvedModel: String?
    var duration: Duration
    var usage: SummaryUsage?
}

/// Writes a summary for a request. The live implementation drives the CLIs;
/// UI tests inject a stub.
protocol SummaryGenerating: Sendable {
    func generate(_ request: SummaryRequest) async throws -> SummaryResult
    /// How the CLI authenticates for `connection` — consulted only after an
    /// auth-class failure, to pick the remediation that will actually help.
    func authSetup(for connection: SummaryConnectionTarget) async -> SummaryAuthSetup
    /// Whether the user's ChatGPT account is signed in to the Codex CLI.
    func accountStatus() async -> SummaryAccountStatus
    /// Runs `codex login` (opens the browser) and waits for it to finish.
    func signIn() async throws
}

extension SummaryGenerating {
    func authSetup(for connection: SummaryConnectionTarget) async -> SummaryAuthSetup { .unknown }
    func accountStatus() async -> SummaryAccountStatus { .unknown }
    func signIn() async throws {}
}

/// The ChatGPT sign-in state reported by `codex login status`.
enum SummaryAccountStatus: Equatable, Sendable {
    case signedIn(String)
    case signedOut
    case unknown
}

/// Raw diagnostics kept alongside a typed failure for the "Details" disclosure.
/// `message` is already redacted of credentials.
struct SummaryErrorDetail: Sendable, Equatable {
    var message: String
    var exitCode: Int32?
    var httpStatus: Int?
    var requestID: String?
    var cliVersion: String?
    var executablePath: String?

    init(message: String, exitCode: Int32? = nil, httpStatus: Int? = nil,
         requestID: String? = nil, cliVersion: String? = nil, executablePath: String? = nil) {
        self.message = message
        self.exitCode = exitCode
        self.httpStatus = httpStatus
        self.requestID = requestID
        self.cliVersion = cliVersion
        self.executablePath = executablePath
    }
}

/// Every failure the Weekly Summary can surface, each mapped to a friendly
/// title + remediation by `SummaryErrorPresenter`.
enum WeeklySummaryError: Error, Sendable, Equatable {
    case cliNotFound(SummaryProvider)
    case invalidCLIPath(SummaryProvider, path: String)
    case launchFailed(SummaryProvider, SummaryErrorDetail)
    case cancelled
    case timedOut(seconds: Int)
    case inputTooLarge(bytes: Int, limit: Int)
    case notSignedIn(SummaryProvider, SummaryErrorDetail)
    case authenticationRejected(SummaryProvider, SummaryErrorDetail)
    case authHelperFailed(SummaryProvider, SummaryErrorDetail)
    case accessDenied(SummaryProvider, SummaryErrorDetail)
    case modelUnavailable(SummaryProvider, model: String?, SummaryErrorDetail)
    case configurationRejected(SummaryProvider, SummaryErrorDetail)
    case rateLimited(SummaryProvider, SummaryErrorDetail)
    case providerUnavailable(SummaryProvider, SummaryErrorDetail)
    case networkFailure(SummaryProvider, SummaryErrorDetail)
    case cliIncompatible(SummaryProvider, SummaryErrorDetail)
    case invalidResponse(SummaryProvider, SummaryErrorDetail)
    case emptyResponse(SummaryProvider)
    case cliFailed(SummaryProvider, SummaryErrorDetail)

    /// Whether this is an authentication/authorization problem (drives the
    /// provider-aware remediation copy).
    var isAuthRelated: Bool {
        switch self {
        case .notSignedIn, .authenticationRejected, .authHelperFailed, .accessDenied: true
        default: false
        }
    }

    var detail: SummaryErrorDetail? {
        switch self {
        case .launchFailed(_, let d), .notSignedIn(_, let d), .authenticationRejected(_, let d),
             .authHelperFailed(_, let d), .accessDenied(_, let d), .modelUnavailable(_, _, let d),
             .configurationRejected(_, let d), .rateLimited(_, let d), .providerUnavailable(_, let d),
             .networkFailure(_, let d), .cliIncompatible(_, let d), .invalidResponse(_, let d),
             .cliFailed(_, let d):
            d
        case .cliNotFound, .invalidCLIPath, .cancelled, .timedOut, .inputTooLarge, .emptyResponse:
            nil
        }
    }
}
