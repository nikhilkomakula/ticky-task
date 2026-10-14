import Foundation
import Testing
@testable import TickyTask

@Suite("CLI Process Runner")
struct CLIProcessRunnerTests {
    private let runner = CLIProcessRunner(killGrace: .milliseconds(500), eofGrace: .milliseconds(500))

    private static func makeTempDir() -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func createScript(in tempDir: URL, name: String, _ script: String) -> URL {
        let path = tempDir.appendingPathComponent(name)
        try? script.write(toFile: path.path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    // Test 1: Echo large stdin
    @Test func echosLargeStdin() async throws {
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "cat", "#!/bin/sh\ncat")
        let largeData = Data(repeating: UInt8(ascii: "x"), count: 4 * 1024 * 1024)
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            stdin: largeData,
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(10),
            stdoutLimit: 8 * 1024 * 1024
        )

        let result = try await runner.run(invocation)
        #expect(result.exitCode == 0)
        #expect(result.stdout == largeData)
    }

    // Test 2: Non-zero exit with stderr
    @Test func returnsNonZeroExitWithStderr() async throws {
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "fail", "#!/bin/sh\necho \"error message\" >&2\nexit 3\n")
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(5)
        )

        let result = try await runner.run(invocation)
        #expect(result.exitCode == 3)
        #expect(result.stderrText.contains("error message"))
    }

    // Test 3: Child exits without reading stdin (no SIGPIPE crash)
    @Test func handlesEarlyExitWithUnreadStdin() async throws {
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "noinput", "#!/bin/sh\nexit 0\n")
        let largeStdin = Data(repeating: UInt8(ascii: "z"), count: 4 * 1024 * 1024)
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            stdin: largeStdin,
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(5)
        )

        let result = try await runner.run(invocation)
        #expect(result.exitCode == 0)
    }

    // Test 4: Timeout terminates the process
    @Test func enforcesTimeout() async throws {
        let shortRunner = CLIProcessRunner(killGrace: .milliseconds(200), eofGrace: .milliseconds(100))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "sleep30", "#!/bin/sh\nsleep 30\n")
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .milliseconds(100)
        )

        let start = Date()
        do {
            _ = try await shortRunner.run(invocation)
            #expect(Bool(false), "Should have thrown timeout")
        } catch CLIProcessError.timedOut(let seconds) {
            let elapsed = Date().timeIntervalSince(start)
            #expect(seconds >= 1)
            #expect(elapsed < 2.0)
        }
    }

    // Test 5: Missing executable
    @Test func failsOnMissingExecutable() async throws {
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missing = tempDir.appendingPathComponent("nonexistent")
        let invocation = CLIInvocation(
            executableURL: missing,
            arguments: [],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(5)
        )

        do {
            _ = try await runner.run(invocation)
            #expect(Bool(false), "Should have thrown launchFailed")
        } catch CLIProcessError.launchFailed {
            // Expected.
        }
    }

    // Test 6: Working directory is honored
    @Test func honorsWorkingDirectory() async throws {
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let subdir = tempDir.appendingPathComponent("subdir")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let script = createScript(in: tempDir, name: "pwd_check", "#!/bin/sh\npwd\n")
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: subdir,
            environment: [:],
            timeout: .seconds(5)
        )

        let result = try await runner.run(invocation)
        let pwd = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pwd.hasSuffix(subdir.lastPathComponent))
    }

    // Test 7: Environment variables are passed
    @Test func passesEnvironmentVariables() async throws {
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "env_check", "#!/bin/sh\necho $TEST_VAR\n")
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: tempDir,
            environment: ["TEST_VAR": "hello_world"],
            timeout: .seconds(5)
        )

        let result = try await runner.run(invocation)
        #expect(result.stdoutText.contains("hello_world"))
    }

    // Test 8: Stdout exceeds limit
    @Test func failsOnStdoutOverflow() async throws {
        let limitedRunner = CLIProcessRunner(killGrace: .milliseconds(200), eofGrace: .milliseconds(100))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "big_output", "#!/bin/sh\nhead -c 2097152 </dev/zero | tr '\\0' 'x'\n")
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(5),
            stdoutLimit: 1024 * 1024  // 1 MB limit, script produces 2 MB
        )

        do {
            _ = try await limitedRunner.run(invocation)
            #expect(Bool(false), "Should have thrown outputTooLarge")
        } catch CLIProcessError.outputTooLarge(let limit) {
            #expect(limit == 1024 * 1024)
        }
    }

    // Test 9: Stderr keeps only tail
    @Test func keepsStderrTail() async throws {
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "stderr_tail", "#!/bin/sh\nhead -c 2097152 </dev/zero | tr '\\0' 'e' >&2\necho \"TAIL\" >&2\n")
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(5),
            stderrLimit: 1024  // 1 KB limit
        )

        let result = try await runner.run(invocation)
        #expect(result.stderr.count <= 1024)
        #expect(result.stderrText.contains("TAIL"))
    }

    // Test 10: Concurrent runs succeed
    @Test func handlesMultipleConcurrentRuns() async throws {
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var tasks: [Task<CLIProcessOutput, Error>] = []
        for i in 0 ..< 5 {
            let task = Task {
                let script = self.createScript(in: tempDir, name: "quick_\(i)", "#!/bin/sh\necho 'run_\(i)'; exit 0\n")
                let invocation = CLIInvocation(
                    executableURL: script,
                    arguments: [],
                    workingDirectory: tempDir,
                    environment: [:],
                    timeout: .seconds(5)
                )
                return try await self.runner.run(invocation)
            }
            tasks.append(task)
        }

        var results: [CLIProcessOutput] = []
        for task in tasks {
            let result = try await task.value
            results.append(result)
        }

        #expect(results.allSatisfy { $0.exitCode == 0 })
        #expect(results.count == 5)
    }
}
