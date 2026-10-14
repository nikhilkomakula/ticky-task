import Foundation
import Darwin

/// Spawns a child process via posix_spawn with robust stdin/stdout/stderr handling,
/// timeout enforcement, cancellation support, and exactly-once completion.
/// Terminates process groups cleanly: SIGTERM → grace period → SIGKILL + recursive sweep.
struct CLIProcessRunner: CLICommandRunning {
    var killGrace: Duration = .seconds(2)
    var eofGrace: Duration = .seconds(1)

    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput {
        // Fail fast if already cancelled.
        if Task.isCancelled {
            throw CLIProcessError.cancelled
        }

        // Create pipes.
        var stdinPipe = [Int32](repeating: 0, count: 2)
        var stdoutPipe = [Int32](repeating: 0, count: 2)
        var stderrPipe = [Int32](repeating: 0, count: 2)

        guard pipe(&stdinPipe) == 0,
              pipe(&stdoutPipe) == 0,
              pipe(&stderrPipe) == 0 else {
            throw CLIProcessError.launchFailed("Failed to create pipes")
        }

        let stdinRead = stdinPipe[0], stdinWrite = stdinPipe[1]
        let stdoutRead = stdoutPipe[0], stdoutWrite = stdoutPipe[1]
        let stderrRead = stderrPipe[0], stderrWrite = stderrPipe[1]

        // Set up file actions and attributes.
        let fileActions = UnsafeMutablePointer<posix_spawn_file_actions_t?>.allocate(capacity: 1)
        fileActions.initialize(to: nil)
        guard posix_spawn_file_actions_init(fileActions) == 0 else {
            fileActions.deallocate()
            closeAll(stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite)
            throw CLIProcessError.launchFailed("Failed to init file actions")
        }
        defer { posix_spawn_file_actions_destroy(fileActions); fileActions.deallocate() }

        // Redirect pipes: stdin (read), stdout (write), stderr (write).
        _ = posix_spawn_file_actions_adddup2(fileActions, stdinRead, STDIN_FILENO)
        _ = posix_spawn_file_actions_adddup2(fileActions, stdoutWrite, STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(fileActions, stderrWrite, STDERR_FILENO)

        // Change working directory.
        _ = posix_spawn_file_actions_addchdir_np(fileActions, invocation.workingDirectory.path)

        // Set up attributes: process group, signals, etc.
        let attr = UnsafeMutablePointer<posix_spawnattr_t?>.allocate(capacity: 1)
        attr.initialize(to: nil)
        guard posix_spawnattr_init(attr) == 0 else {
            attr.deallocate()
            closeAll(stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite)
            throw CLIProcessError.launchFailed("Failed to init spawn attributes")
        }
        defer { posix_spawnattr_destroy(attr); attr.deallocate() }

        let flags: Int16 = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(attr, flags)

        // Set child to lead its own process group.
        posix_spawnattr_setpgroup(attr, 0)

        // Reset signal defaults: SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD.
        var sigdefset = sigset_t()
        sigemptyset(&sigdefset)
        sigaddset(&sigdefset, SIGPIPE)
        sigaddset(&sigdefset, SIGTERM)
        sigaddset(&sigdefset, SIGINT)
        sigaddset(&sigdefset, SIGHUP)
        sigaddset(&sigdefset, SIGQUIT)
        sigaddset(&sigdefset, SIGCHLD)
        posix_spawnattr_setsigdefault(attr, &sigdefset)

        // Set empty signal mask.
        var sigmask = sigset_t()
        sigemptyset(&sigmask)
        posix_spawnattr_setsigmask(attr, &sigmask)

        // Prepare argv and envp.
        let exePath = invocation.executableURL.path
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(exePath)]
        for arg in invocation.arguments {
            argv.append(strdup(arg))
        }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        let envArray = invocation.environment.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = []
        for envStr in envArray {
            envp.append(strdup(envStr))
        }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        let startTime = Date()

        // Spawn the child.
        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(&pid, exePath, fileActions, attr, argvBuffer.baseAddress, envpBuffer.baseAddress)
            }
        }

        // Close the parent's ends of pipes.
        close(stdinRead)
        close(stdoutWrite)
        close(stderrWrite)

        guard spawnResult == 0 else {
            closeAll(stdinWrite, stdoutRead, stderrRead)
            let errMsg = String(cString: strerror(spawnResult))
            throw CLIProcessError.launchFailed("\(exePath): \(errMsg)")
        }

        // State machine: guard against races (use class for reference semantics).
        let state = ProcessStateBox()

        // Set up timeout timer.
        let timeoutSeconds = Int(invocation.timeout.components.seconds)
        var timeoutTaskHandle: Task<Void, Never>? = nil

        // Set up readers for stdout and stderr.
        var stdoutTask: Task<Data, Never>? = nil
        var stderrTask: Task<Data, Never>? = nil
        var stdinTask: Task<Void, Never>? = nil
        var exitTask: Task<(Int32?, Int32?), Never>? = nil

        return try await withTaskCancellationHandler {
            // Set up timeout.
            timeoutTaskHandle = Task {
                try? await Task.sleep(for: invocation.timeout)
                state.recordCauseOnce(.timedOut(seconds: max(1, timeoutSeconds)))
                terminateProcessTree(pgid: pid)
            }

            // Set up readers for stdout and stderr.
            stdoutTask = Task {
                await drainStream(fd: stdoutRead, limit: invocation.stdoutLimit, isStderr: false, state: state)
            }

            stderrTask = Task {
                await drainStream(fd: stderrRead, limit: invocation.stderrLimit, isStderr: true, state: state)
            }

            // Write stdin on its own queue.
            stdinTask = Task {
                await writeStdinAsync(stdinWrite, invocation.stdin)
            }

            // Wait for the child process.
            exitTask = Task {
                await waitForChild(pid: pid)
            }

            // Await exit.
            let (exitCode, signal) = await exitTask!.value

            // Give readers a grace period for EOF.
            try await Task.sleep(for: eofGrace)

            // Collect results from readers.
            let stdout = await stdoutTask!.value
            let stderr = await stderrTask!.value
            _ = await stdinTask!.value

            let elapsedSeconds = Date().timeIntervalSince(startTime)
            let seconds = Int(elapsedSeconds)
            let attoseconds = Int64((elapsedSeconds - Double(seconds)) * 1e18)
            let duration = Duration(secondsComponent: Int64(seconds), attosecondsComponent: attoseconds)

            // Check for recorded errors.
            if let cause = state.cause {
                switch cause {
                case .cancelled:
                    throw CLIProcessError.cancelled
                case .timedOut(let seconds):
                    throw CLIProcessError.timedOut(seconds: seconds)
                case .outputTooLarge(let limit):
                    throw CLIProcessError.outputTooLarge(limit: limit)
                default:
                    break
                }
            }

            return CLIProcessOutput(exitCode: exitCode, signal: signal, stdout: stdout, stderr: stderr, duration: duration)
        } onCancel: {
            state.recordCauseOnce(.cancelled)
            terminateProcessTree(pgid: pid)
        }
    }

    // MARK: - Helpers

    /// Drains a stream (stdout or stderr) into a bounded buffer.
    private func drainStream(fd: Int32, limit: Int, isStderr: Bool, state: ProcessStateBox) async -> Data {
        var result = Data(capacity: min(limit, 64 * 1024))

        // Set non-blocking.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let queue = DispatchQueue(label: isStderr ? "cli.stderr" : "cli.stdout")

        return await withCheckedContinuation { cont in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let n = read(fd, &buffer, buffer.count)

                if n > 0 {
                    if isStderr {
                        // Keep tail for stderr.
                        result.append(&buffer, count: n)
                        if result.count > limit {
                            let excess = result.count - limit
                            result.removeFirst(excess)
                        }
                    } else {
                        // Fail fast for stdout overflow.
                        result.append(&buffer, count: n)
                        if result.count > limit {
                            state.recordCauseOnce(.outputTooLarge(limit: limit))
                            source.cancel()
                        }
                    }
                } else if n == 0 {
                    // EOF
                    source.cancel()
                }
            }

            source.setCancelHandler {
                close(fd)
                cont.resume(returning: result)
            }

            source.resume()
        }
    }

    /// Writes stdin asynchronously, handling EPIPE and partial writes.
    private func writeStdinAsync(_ fd: Int32, _ data: Data) async -> Void {
        return await withCheckedContinuation { cont in
            let queue = DispatchQueue(label: "cli.stdin")
            queue.async {
                self.writeStdin(fd, data)
                cont.resume(returning: ())
            }
        }
    }

    /// Writes stdin, handling EPIPE and partial writes.
    private func writeStdin(_ fd: Int32, _ data: Data) {
        guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            close(fd)
            return
        }

        var offset = 0
        while offset < data.count {
            let chunk = min(4096, data.count - offset)
            let bytes = Array(data.subdata(in: offset ..< offset + chunk))
            let written = write(fd, bytes, chunk)

            if written < 0 {
                if errno == EPIPE {
                    break  // Child closed stdin; stop writing.
                } else if errno != EINTR {
                    break
                }
            } else {
                offset += Int(written)
            }
        }

        close(fd)
    }

    /// Waits for child exit and returns (exitCode, signal).
    private func waitForChild(pid: pid_t) async -> (Int32?, Int32?) {
        return await withCheckedContinuation { cont in
            let queue = DispatchQueue(label: "cli.waitpid")
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            let resumed = ResumedFlag()

            source.setEventHandler { [resumed] in
                guard !resumed.value else { return }
                var status: Int32 = 0
                let result = waitpid(pid, &status, 0)

                if result >= 0 {
                    let exitCode: Int32? = (status & 0xff) == 0 ? Int32((status >> 8) & 0xff) : nil
                    let signal: Int32? = (status & 0x7f) != 0 ? Int32(status & 0x7f) : nil
                    resumed.value = true
                    source.cancel()
                    cont.resume(returning: (exitCode, signal))
                }
            }

            source.setCancelHandler { [resumed] in
                guard !resumed.value else { return }
                resumed.value = true
                source.setEventHandler {}
                cont.resume(returning: (nil, nil))
            }

            source.resume()
        }
    }

    /// Terminates a process group: SIGTERM, grace, SIGKILL, and recursive sweep.
    private func terminateProcessTree(pgid: pid_t) {
        // SIGTERM to the group.
        kill(-pgid, SIGTERM)

        // Grace period.
        let graceUsec = UInt32(killGrace.components.seconds * 1_000_000)
        usleep(graceUsec)

        // SIGKILL to the group.
        kill(-pgid, SIGKILL)

        // Recursive sweep of descendants.
        var count: UInt32 = 0
        let checkResult = proc_listchildpids(pgid, nil, 0)
        guard checkResult > 0 else { return }

        var pids = [pid_t](repeating: 0, count: Int(checkResult))
        let actualCount = proc_listchildpids(pgid, &pids, Int32(checkResult))

        for i in 0 ..< Int(actualCount) {
            let pid = pids[i]
            if pid > 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    private func closeAll(_ fds: Int32...) {
        fds.forEach { close($0) }
    }
}

// MARK: - ProcessStateBox

private final class ProcessStateBox {
    private let lock = NSLock()
    private(set) var cause: CLIProcessError? = nil

    func recordCauseOnce(_ newCause: CLIProcessError) {
        lock.lock()
        if cause == nil {
            cause = newCause
        }
        lock.unlock()
    }
}

// MARK: - ResumedFlag

private final class ResumedFlag {
    var value: Bool = false
}
