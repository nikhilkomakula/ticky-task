import Foundation

/// Shared contract for launching a local command-line tool (the `claude` /
/// `codex` CLIs) and collecting its result. The live implementation is
/// `CLIProcessRunner`; tests and the catalog/generator code depend only on this
/// protocol so they can substitute a fake.
protocol CLICommandRunning: Sendable {
    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput
}

/// Everything needed to start one child process. Arguments are passed as an
/// array (never through a shell), and private input goes through `stdin`.
struct CLIInvocation: Sendable, Equatable {
    var executableURL: URL
    var arguments: [String]
    var stdin: Data = Data()
    var workingDirectory: URL
    /// The complete child environment (callers start from the parent's and adjust).
    var environment: [String: String]
    /// Wall-clock deadline after which the process group is terminated.
    var timeout: Duration
    /// Maximum stdout bytes retained; exceeding it fails with `.outputTooLarge`.
    var stdoutLimit: Int = 8 * 1024 * 1024
    /// Maximum stderr bytes retained; older bytes are dropped (the tail is kept).
    var stderrLimit: Int = 1024 * 1024
}

/// How a finished child process ended.
struct CLIProcessOutput: Sendable, Equatable {
    /// Exit status when the child exited normally; `nil` when it was killed by a signal.
    var exitCode: Int32?
    /// The terminating signal, when the child did not exit normally.
    var signal: Int32?
    var stdout: Data
    /// The retained tail of stderr (see `CLIInvocation.stderrLimit`).
    var stderr: Data
    var duration: Duration

    var succeeded: Bool { exitCode == 0 }
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Failures of the process machinery itself — distinct from a CLI that ran and
/// reported an error (that is a `CLIProcessOutput` with a non-zero exit).
enum CLIProcessError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(seconds: Int)
    case cancelled
    case outputTooLarge(limit: Int)
}

/// Executable discovery failures.
enum CLIResolutionError: Error, Equatable, Sendable {
    /// No executable named `name` was found in the known locations or the login-shell lookup.
    case notFound(name: String)
    /// An explicit user-chosen path is missing or not executable (no silent fallback).
    case invalidOverride(path: String)
}
