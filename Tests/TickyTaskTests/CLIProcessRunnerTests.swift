import Foundation
import Darwin
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

    @Test func completedProcessDoesNotTimeOutDuringEOFGrace() async throws {
        let graceRunner = CLIProcessRunner(killGrace: .milliseconds(50), eofGrace: .milliseconds(300))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A system binary, not a freshly written script: endpoint-security scanning of
        // a brand-new executable can itself take longer than this 150 ms timeout.
        let invocation = CLIInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf done"],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .milliseconds(150)
        )

        let result = try await graceRunner.run(invocation)
        #expect(result.exitCode == 0)
        #expect(result.stdoutText == "done")
    }

    @Test func completedProcessCanDrainPastItsExecutionDeadline() async throws {
        let graceRunner = CLIProcessRunner(killGrace: .milliseconds(50), eofGrace: .milliseconds(300))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let start = Date()
        let result = try await graceRunner.run(CLIInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 0.8 & printf done"],
            workingDirectory: tempDir, environment: [:], timeout: .milliseconds(150)))
        #expect(result.exitCode == 0)
        #expect(result.stdoutText == "done")
        #expect(Date().timeIntervalSince(start) >= 0.25,
                "The inherited pipe must keep draining across the 150 ms execution deadline")
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test func descendantGetsKillGraceAfterRootExits() async throws {
        let graceRunner = CLIProcessRunner(killGrace: .milliseconds(500), eofGrace: .milliseconds(50))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let command = #"""
        /usr/bin/perl -e '
        $SIG{TERM} = sub {
            $SIG{TERM} = "IGNORE";
            select undef, undef, undef, 0.2;
            open my $done, ">", "cleanup" or die;
            print $done "done";
            close $done;
            exit 0;
        };
        open my $ready, ">", "ready" or die;
        print $ready "ready";
        close $ready;
        sleep 2;
        ' &
        wait
        """#
        let task = Task {
            try await graceRunner.run(CLIInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
                workingDirectory: tempDir, environment: [:], timeout: .seconds(5)))
        }
        let ready = tempDir.appendingPathComponent("ready")
        for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(600))
        #expect(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("cleanup").path),
                "A 200 ms descendant SIGTERM cleanup must get the configured 500 ms grace after the root exits")
    }

    @Test func boundsDrainAfterMainProcessExit() async throws {
        let graceRunner = CLIProcessRunner(killGrace: .milliseconds(50), eofGrace: .milliseconds(50))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let invocation = CLIInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 1 &\nprintf done\nexit 0\n"],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(3)
        )

        let start = Date()
        let result = try await graceRunner.run(invocation)
        #expect(result.exitCode == 0)
        #expect(result.stdoutText == "done")
        #expect(Date().timeIntervalSince(start) < 0.6, "A descendant retaining the pipes must not outlive the EOF drain bound")
    }

    @Test func stdoutOverflowTerminatesProcessPromptly() async throws {
        let limitedRunner = CLIProcessRunner(killGrace: .milliseconds(50), eofGrace: .milliseconds(50))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let invocation = CLIInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%0128d' 0\n/bin/sleep 1\n"],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(3),
            stdoutLimit: 32
        )

        let start = Date()
        do {
            _ = try await limitedRunner.run(invocation)
            Issue.record("Expected stdout overflow")
        } catch CLIProcessError.outputTooLarge(let limit) {
            #expect(limit == 32)
            #expect(Date().timeIntervalSince(start) < 0.6, "Overflow must stop execution rather than wait for the command or timeout")
        }
    }

    @Test func activeCancellationReturnsProcessCancellationError() async throws {
        let cancellationRunner = CLIProcessRunner(killGrace: .milliseconds(50), eofGrace: .milliseconds(50))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "cancel_me", "#!/bin/sh\nprintf ready > ready\n/bin/sleep 3\n")
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(5)
        )

        let task = Task { try await cancellationRunner.run(invocation) }
        let readyURL = tempDir.appendingPathComponent("ready")
        for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: readyURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: readyURL.path))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected process cancellation")
        } catch {
            #expect((error as? CLIProcessError) == .cancelled, "Active cancellation must honor the same error contract as pre-cancellation")
        }
    }

    @Test func cancellationDoesNotBlockCallingThreadForKillGrace() async throws {
        let cancellationRunner = CLIProcessRunner(killGrace: .seconds(1), eofGrace: .milliseconds(50))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "cancel_without_blocking", "#!/bin/sh\nprintf ready > ready\n/bin/sleep 3\n")
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(5)
        )

        let task = Task { try await cancellationRunner.run(invocation) }
        let readyURL = tempDir.appendingPathComponent("ready")
        for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: readyURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: readyURL.path))

        let start = Date()
        task.cancel()
        #expect(Date().timeIntervalSince(start) < 0.3, "Cancellation from a UI action must not sleep on its calling thread")
        _ = try? await task.value
    }

    @Test func cancellationKillsDescendantInSeparateProcessGroup() async throws {
        let cancellationRunner = CLIProcessRunner(killGrace: .milliseconds(50), eofGrace: .milliseconds(50))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "escaped_descendant", """
        #!/bin/sh
        /usr/bin/perl -MPOSIX -e 'POSIX::setpgid(0, 0); open my $file, ">", "child.pid" or die; print $file "$$\\n"; close $file; select undef, undef, undef, 0.3; open my $alive, ">", "survived" or die; print $alive "alive"; close $alive; sleep 3;' &
        wait
        """)
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(5)
        )

        let task = Task { try await cancellationRunner.run(invocation) }
        let pidURL = tempDir.appendingPathComponent("child.pid")
        var childPID: pid_t?
        for _ in 0 ..< 200 {
            if let contents = try? String(contentsOf: pidURL, encoding: .utf8),
               let parsedPID = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsedPID > 0 {
                childPID = parsedPID
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { if let childPID { kill(childPID, SIGKILL) } }
        task.cancel()
        _ = try? await task.value

        _ = try #require(childPID, "Fixture must create a descendant in its own process group")
        try await Task.sleep(for: .milliseconds(400))
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("survived").path),
                "Cancellation must stop descendants that escaped the original process group from continuing execution")
    }

    @Test func fractionalKillGraceAllowsSignalCleanup() async throws {
        let cancellationRunner = CLIProcessRunner(killGrace: .milliseconds(500), eofGrace: .milliseconds(50))
        let tempDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = createScript(in: tempDir, name: "signal_cleanup", """
        #!/usr/bin/perl
        $SIG{TERM} = sub {
            select undef, undef, undef, 0.1;
            open my $file, ">", "cleanup" or die;
            print $file "done";
            close $file;
            exit 0;
        };
        open my $ready, ">", "ready" or die;
        print $ready "ready";
        close $ready;
        sleep 3;
        """)
        let invocation = CLIInvocation(
            executableURL: script,
            arguments: [],
            workingDirectory: tempDir,
            environment: [:],
            timeout: .seconds(5)
        )

        let task = Task { try await cancellationRunner.run(invocation) }
        let readyURL = tempDir.appendingPathComponent("ready")
        for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: readyURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: readyURL.path))
        task.cancel()
        _ = try? await task.value

        #expect(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("cleanup").path),
                "A 500 ms kill grace must allow a 100 ms SIGTERM cleanup before SIGKILL")
    }
}
