import Foundation
import Darwin

/// Spawns a child process via posix_spawn with robust stdin/stdout/stderr handling,
/// timeout enforcement, cancellation support, and exactly-once completion.
///
/// Lifecycle: the child leads its own process group. A timeout, cancellation, or
/// stdout overflow stops the run once, by tearing down the whole process tree
/// asynchronously (SIGTERM → `killGrace` → SIGKILL), never blocking the caller.
/// After the child exits, its pipes get at most `eofGrace` to reach EOF; a
/// leftover descendant still holding them is killed and the run returns anyway.
struct CLIProcessRunner: CLICommandRunning {
    var killGrace: Duration = .seconds(2)
    var eofGrace: Duration = .seconds(1)

    func run(_ invocation: CLIInvocation) async throws -> CLIProcessOutput {
        // Fail fast if already cancelled.
        if Task.isCancelled {
            throw CLIProcessError.cancelled
        }

        // Create pipes.
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)

        guard pipe(&stdinPipe) == 0,
              pipe(&stdoutPipe) == 0,
              pipe(&stderrPipe) == 0 else {
            // Close whichever pipes were created before the failure.
            (stdinPipe + stdoutPipe + stderrPipe).filter { $0 >= 0 }.forEach { close($0) }
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

        let lifecycle = RunLifecycle(pid: pid, killGrace: killGrace)
        let stdout = PipeReader(fd: stdoutRead, limit: invocation.stdoutLimit, keepTail: false, label: "cli.stdout") {
            lifecycle.stop(because: .outputTooLarge(limit: invocation.stdoutLimit))
        }
        let stderr = PipeReader(fd: stderrRead, limit: invocation.stderrLimit, keepTail: true, label: "cli.stderr") {}
        let stdin = PipeWriter(fd: stdinWrite, data: invocation.stdin)
        let pipes: [PipeEnd] = [stdout, stderr, stdin]
        lifecycle.pipes = pipes
        pipes.forEach { $0.start() }

        let timeoutSeconds = max(1, Int(invocation.timeout.components.seconds))
        let timeout = DispatchWorkItem { lifecycle.stopIfRunning(because: .timedOut(seconds: timeoutSeconds)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + invocation.timeout.timeInterval, execute: timeout)

        let eofGrace = eofGrace
        return try await withTaskCancellationHandler {
            let (exitCode, signal) = await lifecycle.waitForExit()
            timeout.cancel()

            let drainDeadline = DispatchWorkItem {
                // Something outside the reaped child still holds a pipe open.
                pipes.forEach { $0.finish() }
                lifecycle.killLeftoverGroup()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + eofGrace.timeInterval, execute: drainDeadline)
            let stdoutData = await stdout.value()
            let stderrData = await stderr.value()
            await stdin.value()
            drainDeadline.cancel()

            if let cause = lifecycle.cause { throw cause }
            let elapsed = Date().timeIntervalSince(startTime)
            return CLIProcessOutput(exitCode: exitCode, signal: signal, stdout: stdoutData, stderr: stderrData,
                                    duration: .milliseconds(Int64(elapsed * 1000)))
        } onCancel: {
            lifecycle.stop(because: .cancelled)
        }
    }

    private func closeAll(_ fds: Int32...) {
        fds.forEach { close($0) }
    }
}

// MARK: - Lifecycle

/// The single owner of a run's state: why it's ending early (first cause wins),
/// whether the child has been reaped, and the teardown of its process tree.
/// Reaping and signalling the child happen under one lock, so a signal is never
/// sent to a pid after `waitpid` has released it.
private final class RunLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private let killGrace: Duration
    private var reaped = false
    private var stopCause: CLIProcessError?
    /// Set once before the run starts; finished early when a stop arrives after exit.
    var pipes: [PipeEnd] = []

    init(pid: pid_t, killGrace: Duration) {
        self.pid = pid
        self.killGrace = killGrace
    }

    var cause: CLIProcessError? {
        lock.lock(); defer { lock.unlock() }
        return stopCause
    }

    /// Records `reason` (unless an earlier cause exists) and tears the process
    /// tree down. If the child has already exited, stops draining its pipes instead.
    func stop(because reason: CLIProcessError) {
        lock.lock()
        let isFirst = stopCause == nil
        if isFirst { stopCause = reason }
        let childRunning = !reaped
        let tree = isFirst && childRunning ? ProcessTree.snapshot(root: pid) : []
        if isFirst && childRunning { ProcessTree.signal(group: pid, members: tree, SIGTERM) }
        lock.unlock()

        guard isFirst else { return }
        if childRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace.timeInterval) { [self] in
                lock.lock(); defer { lock.unlock() }
                let survivors = reaped ? tree : tree + ProcessTree.snapshot(root: pid)
                ProcessTree.signal(group: pid, members: survivors, SIGKILL)
            }
        } else {
            pipes.forEach { $0.finish() }
            killLeftoverGroup()
        }
    }

    /// A timeout only applies while the child is still running.
    func stopIfRunning(because reason: CLIProcessError) {
        lock.lock()
        let running = !reaped
        lock.unlock()
        if running { stop(because: reason) }
    }

    /// Kills anything left in the child's process group after the child exited.
    /// The group id can't be reissued while any member is alive, so this only
    /// reaches our own leftovers.
    func killLeftoverGroup() {
        kill(-pid, SIGKILL)
    }

    /// Waits for the child to exit and reaps it; returns (exit code, signal).
    func waitForExit() async -> (Int32?, Int32?) {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "cli.waitpid")
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            let resumed = ResumedFlag()
            source.setEventHandler { [self] in
                guard !resumed.value else { return }
                lock.lock()
                var status: Int32 = 0
                let result = waitpid(pid, &status, 0)
                if result >= 0 { reaped = true }
                lock.unlock()
                guard result >= 0 else { return }
                resumed.value = true
                source.cancel()
                let exitCode: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
                let signal: Int32? = (status & 0x7f) != 0 ? status & 0x7f : nil
                continuation.resume(returning: (exitCode, signal))
            }
            source.resume()
        }
    }
}

/// Process-tree walking and identity-checked signalling.
private enum ProcessTree {
    struct Member: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    /// Every live descendant of `root`, recursively (a child that moved to its
    /// own process group is still found through its parent).
    static func snapshot(root: pid_t) -> [Member] {
        var members: [Member] = []
        var seen: Set<pid_t> = [root]
        var pending = [root]
        while let parent = pending.popLast() {
            let capacity = proc_listchildpids(parent, nil, 0)
            guard capacity > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(capacity) + 16)
            let count = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            for child in children.prefix(Int(max(0, count))) where child > 0 && seen.insert(child).inserted {
                if let member = identity(of: child) { members.append(member) }
                pending.append(child)
            }
        }
        return members
    }

    /// Signals the group and each recorded member that is still the same process
    /// (matching start time), so a recycled pid is never hit.
    static func signal(group: pid_t, members: [Member], _ signal: Int32) {
        kill(-group, signal)
        for member in members where identity(of: member.pid) == member {
            kill(member.pid, signal)
        }
    }

    private static func identity(of pid: pid_t) -> Member? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Member(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}

// MARK: - Pipes

/// One parent-side pipe end, serviced on its own serial queue. Every handler and
/// the final `close` run on that queue, so the fd is closed exactly once and never
/// while a handler is using it. `finish()` may be called from any thread.
private protocol PipeEnd: AnyObject, Sendable {
    func start()
    func finish()
}

/// Drains a pipe into memory. stdout keeps everything up to `limit` and reports
/// overflow; stderr keeps only the last `limit` bytes.
private final class PipeReader: PipeEnd, @unchecked Sendable {
    private let fd: Int32
    private let limit: Int
    private let keepTail: Bool
    private let onOverflow: @Sendable () -> Void
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private var data = Data()
    private var isClosed = false
    private var waiter: CheckedContinuation<Data, Never>?

    init(fd: Int32, limit: Int, keepTail: Bool, label: String, onOverflow: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.limit = limit
        self.keepTail = keepTail
        self.onOverflow = onOverflow
        queue = DispatchQueue(label: label)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    }

    func start() {
        source.setEventHandler { [self] in readAvailable() }
        source.setCancelHandler { [self] in
            close(fd)
            isClosed = true
            waiter?.resume(returning: data)
            waiter = nil
        }
        source.resume()
    }

    func finish() { source.cancel() }

    func value() async -> Data {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if isClosed { continuation.resume(returning: data) } else { waiter = continuation }
            }
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
            guard data.count > limit else { return }
            if keepTail {
                data.removeFirst(data.count - limit)
            } else {
                source.cancel()
                onOverflow()
            }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            source.cancel()
        }
    }
}

/// Feeds `data` to the child's stdin without blocking, then closes it (EOF).
/// A child that exits or stops reading ends the write instead of hanging it.
private final class PipeWriter: PipeEnd, @unchecked Sendable {
    private let fd: Int32
    private let data: Data
    private let queue = DispatchQueue(label: "cli.stdin")
    private let source: DispatchSourceWrite
    private var offset = 0
    private var isClosed = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(fd: Int32, data: Data) {
        self.fd = fd
        self.data = data
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    }

    func start() {
        source.setEventHandler { [self] in writeAvailable() }
        source.setCancelHandler { [self] in
            close(fd)
            isClosed = true
            waiter?.resume()
            waiter = nil
        }
        source.resume()
        if data.isEmpty { source.cancel() }
    }

    func finish() { source.cancel() }

    func value() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if isClosed { continuation.resume() } else { waiter = continuation }
            }
        }
    }

    private func writeAvailable() {
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                write(fd, bytes.baseAddress! + offset, data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                return  // pipe full; wait for the next writable event
            } else {
                break  // EPIPE (child closed stdin) or another error
            }
        }
        source.cancel()
    }
}

private final class ResumedFlag: @unchecked Sendable {
    var value = false
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
