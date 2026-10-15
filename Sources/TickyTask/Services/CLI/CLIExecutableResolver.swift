import Foundation
import Darwin

enum CLIExecutableResolver {
    /// Encapsulates filesystem and shell operations for testing and DI.
    struct Probe: Sendable {
        var home: String
        var isExecutableFile: @Sendable (String) -> Bool
        var loginShellLookup: @Sendable (String) async -> String?

        static let system = Probe(
            home: NSHomeDirectory(),
            isExecutableFile: { path in
                let fileManager = FileManager.default
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
                    return false
                }

                do {
                    let attrs = try fileManager.attributesOfItem(atPath: path)
                    if let mode = attrs[FileAttributeKey.posixPermissions] as? Int {
                        return (mode & 0o111) != 0
                    }
                    return false
                } catch {
                    return false
                }
            },
            loginShellLookup: { name in
                await systemLoginShellLookup(name)
            }
        )
    }

    /// Known install directories, in priority order.
    static func candidatePaths(for name: String, home: String) -> [String] {
        [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.claude/local/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
        ]
    }

    /// Resolves an executable, checking override first, then candidates, then login shell.
    static func resolve(name: String, override: String?, probe: Probe) async throws -> URL {
        // Validate name.
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw CLIResolutionError.notFound(name: name)
        }

        // If override provided, use it (no fallback).
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            let expanded = NSString(string: override).expandingTildeInPath
            if probe.isExecutableFile(expanded) {
                return URL(fileURLWithPath: expanded)
            }
            throw CLIResolutionError.invalidOverride(path: override)
        }

        // Check candidate paths.
        for candidate in candidatePaths(for: name, home: probe.home) {
            if probe.isExecutableFile(candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        // Fall back to login shell lookup.
        if let shellPath = await probe.loginShellLookup(name) {
            let trimmed = shellPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.first == "/",
                  probe.isExecutableFile(trimmed),
                  trimmed.range(of: "\n") == nil else {
                throw CLIResolutionError.notFound(name: name)
            }
            return URL(fileURLWithPath: trimmed)
        }

        throw CLIResolutionError.notFound(name: name)
    }

    /// Whether a file starts with `#!/usr/bin/env node`.
    static func needsNode(_ executable: URL) -> Bool {
        // Read only the first line's worth, not the whole (possibly large) binary.
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32), data.count >= 16 else { return false }

        let header = String(bytes: data, encoding: .utf8) ?? ""
        return header.hasPrefix("#!/usr/bin/env node")
    }

    /// Builds child environment: PATH = exe's dir + node dir (if any) + standard dirs + inherited.
    static func childEnvironment(for executable: URL, nodeDirectory: String?, base: [String: String], home: String) -> [String: String] {
        var env = base

        let exeDir = executable.deletingLastPathComponent().path
        let standardDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        var pathComponents: [String] = []
        var seen = Set<String>()

        // Add exe dir
        if !seen.contains(exeDir) {
            pathComponents.append(exeDir)
            seen.insert(exeDir)
        }

        // Add node dir if provided
        if let nodeDir = nodeDirectory, !seen.contains(nodeDir) {
            pathComponents.append(nodeDir)
            seen.insert(nodeDir)
        }

        // Add standard dirs
        for dir in standardDirs {
            if !seen.contains(dir) {
                pathComponents.append(dir)
                seen.insert(dir)
            }
        }

        // Add inherited PATH entries
        let existingPath = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for p in existingPath {
            if !seen.contains(p) {
                pathComponents.append(p)
                seen.insert(p)
            }
        }

        env["PATH"] = pathComponents.joined(separator: ":")
        return env
    }
}

// MARK: - System Probe

private func systemLoginShellLookup(_ name: String) async -> String? {
    let runner = CLIProcessRunner(killGrace: .milliseconds(500), eofGrace: .milliseconds(200))
    let invocation = CLIInvocation(
        executableURL: URL(fileURLWithPath: "/bin/zsh"),
        arguments: ["-lc", "command -v \(name)"],
        stdin: Data(),
        workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
        environment: [:],
        timeout: .seconds(5),
        stdoutLimit: 4096,
        stderrLimit: 1024
    )

    do {
        let result = try await runner.run(invocation)
        guard result.succeeded else { return nil }
        let output = result.stdoutText
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    } catch {
        return nil
    }
}
