import Foundation
import Testing
@testable import TickyTask

@Suite("CLI Executable Resolver")
struct CLIExecutableResolverTests {
    // MARK: - Unit tests with injected Probe

    @Test func candidatePathsReturnsKnownDirs() {
        let home = "/Users/test"
        let candidates = CLIExecutableResolver.candidatePaths(for: "claude", home: home)

        #expect(candidates.contains("\(home)/.local/bin/claude"))
        #expect(candidates.contains("/opt/homebrew/bin/claude"))
        #expect(candidates.contains("/usr/local/bin/claude"))
        #expect(candidates.contains("\(home)/.claude/local/claude"))
    }

    @Test func resolvesOverrideWhenValid() async throws {
        let home = "/home/test"
        var called = false

        let probe = CLIExecutableResolver.Probe(
            home: home,
            isExecutableFile: { path in
                called = true
                return path == "/custom/claude"
            },
            loginShellLookup: { _ in nil }
        )

        let result = try await CLIExecutableResolver.resolve(name: "claude", override: "/custom/claude", probe: probe)
        #expect(result.path == "/custom/claude")
        #expect(called)
    }

    @Test func throwsOnInvalidOverride() async throws {
        let probe = CLIExecutableResolver.Probe(
            home: "/home/test",
            isExecutableFile: { _ in false },
            loginShellLookup: { _ in nil }
        )

        do {
            _ = try await CLIExecutableResolver.resolve(name: "claude", override: "/nonexistent", probe: probe)
            #expect(Bool(false), "Should have thrown invalidOverride")
        } catch CLIResolutionError.invalidOverride {
            // Expected.
        }
    }

    @Test func acceptsValidOverridePath() async throws {
        let probe = CLIExecutableResolver.Probe(
            home: "/Users/me",
            isExecutableFile: { path in
                path == "/custom/bin/claude"
            },
            loginShellLookup: { _ in nil }
        )

        let result = try await CLIExecutableResolver.resolve(name: "claude", override: "/custom/bin/claude", probe: probe)
        #expect(result.path == "/custom/bin/claude")
    }

    @Test func ignoresWhitespaceInOverride() async throws {
        let probe = CLIExecutableResolver.Probe(
            home: "/Users/me",
            isExecutableFile: { path in
                path == "/custom/bin/claude"
            },
            loginShellLookup: { _ in nil }
        )

        let result = try await CLIExecutableResolver.resolve(name: "claude", override: "  /custom/bin/claude  ", probe: probe)
        #expect(result.path == "/custom/bin/claude")
    }

    @Test func treatsEmptyOverrideAsNone() async throws {
        let home = "/Users/me"
        var probed = false

        let probe = CLIExecutableResolver.Probe(
            home: home,
            isExecutableFile: { _ in
                probed = true
                return false
            },
            loginShellLookup: { _ in nil }
        )

        do {
            _ = try await CLIExecutableResolver.resolve(name: "claude", override: "   ", probe: probe)
        } catch CLIResolutionError.notFound {
            #expect(probed)
        }
    }

    @Test func checksFirstExecutableCandidate() async throws {
        let home = "/Users/me"
        let probe = CLIExecutableResolver.Probe(
            home: home,
            isExecutableFile: { path in
                path == "\(home)/.local/bin/claude"
            },
            loginShellLookup: { _ in nil }
        )

        let result = try await CLIExecutableResolver.resolve(name: "claude", override: nil, probe: probe)
        #expect(result.path == "\(home)/.local/bin/claude")
    }

    @Test func fallsBackToLoginShellWhenNoCandidates() async throws {
        let home = "/Users/me"
        let probe = CLIExecutableResolver.Probe(
            home: home,
            isExecutableFile: { path in
                path == "/opt/homebrew/bin/claude"
            },
            loginShellLookup: { _ in "/opt/homebrew/bin/claude" }
        )

        let result = try await CLIExecutableResolver.resolve(name: "claude", override: nil, probe: probe)
        #expect(result.path == "/opt/homebrew/bin/claude")
    }

    @Test func rejectsRelativePathFromLoginShell() async throws {
        let home = "/Users/me"
        let probe = CLIExecutableResolver.Probe(
            home: home,
            isExecutableFile: { _ in false },
            loginShellLookup: { _ in "bin/claude" }  // Relative, should reject.
        )

        do {
            _ = try await CLIExecutableResolver.resolve(name: "claude", override: nil, probe: probe)
            #expect(Bool(false), "Should have thrown notFound")
        } catch CLIResolutionError.notFound {
            // Expected.
        }
    }

    @Test func rejectsEmptyLineFromLoginShell() async throws {
        let home = "/Users/me"
        let probe = CLIExecutableResolver.Probe(
            home: home,
            isExecutableFile: { _ in false },
            loginShellLookup: { _ in "" }  // Empty, should reject.
        )

        do {
            _ = try await CLIExecutableResolver.resolve(name: "claude", override: nil, probe: probe)
            #expect(Bool(false), "Should have thrown notFound")
        } catch CLIResolutionError.notFound {
            // Expected.
        }
    }

    @Test func acceptsFirstLineFromLoginShellMultiline() async throws {
        let home = "/Users/me"
        let probe = CLIExecutableResolver.Probe(
            home: home,
            isExecutableFile: { path in
                path == "/opt/homebrew/bin/claude"
            },
            loginShellLookup: { _ in
                "/opt/homebrew/bin/claude\njunk\nmore junk"
            }
        )

        let result = try await CLIExecutableResolver.resolve(name: "claude", override: nil, probe: probe)
        #expect(result.path == "/opt/homebrew/bin/claude")
    }

    @Test func rejectsNonExecutableFromLoginShell() async throws {
        let home = "/Users/me"
        let probe = CLIExecutableResolver.Probe(
            home: home,
            isExecutableFile: { _ in false },
            loginShellLookup: { _ in "/tmp/claude" }
        )

        do {
            _ = try await CLIExecutableResolver.resolve(name: "claude", override: nil, probe: probe)
            #expect(Bool(false), "Should have thrown notFound")
        } catch CLIResolutionError.notFound {
            // Expected.
        }
    }

    @Test func rejectsInvalidName() async throws {
        let probe = CLIExecutableResolver.Probe(
            home: "/home",
            isExecutableFile: { _ in true },
            loginShellLookup: { _ in nil }
        )

        do {
            _ = try await CLIExecutableResolver.resolve(name: "bad@name!", override: nil, probe: probe)
            #expect(Bool(false), "Should have thrown notFound")
        } catch CLIResolutionError.notFound {
            // Expected.
        }
    }

    @Test func acceptsValidNames() async throws {
        let probe = CLIExecutableResolver.Probe(
            home: "/home",
            isExecutableFile: { _ in true },
            loginShellLookup: { _ in nil }
        )

        for name in ["claude", "codex", "node", "my-tool", "my_tool", "my.tool", "python3"] {
            let result = try await CLIExecutableResolver.resolve(name: name, override: nil, probe: probe)
            #expect(!result.path.isEmpty)
        }
    }

    // MARK: - needsNode tests

    @Test func detectsNodeShebang() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("node-test-\(UUID().uuidString)")
        try "#!/usr/bin/env node\nconsole.log('hi');".write(toFile: tempFile.path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        #expect(CLIExecutableResolver.needsNode(tempFile))
    }

    @Test func ignoresNonNodeShebang() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-test-\(UUID().uuidString)")
        try "#!/bin/sh\necho hello".write(toFile: tempFile.path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        #expect(!CLIExecutableResolver.needsNode(tempFile))
    }

    @Test func handlesBinaryFiles() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("binary-test-\(UUID().uuidString)")
        try Data([0xFF, 0xFE, 0x00, 0x00]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        #expect(!CLIExecutableResolver.needsNode(tempFile))
    }

    @Test func handlesEmptyFiles() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("empty-test-\(UUID().uuidString)")
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        #expect(!CLIExecutableResolver.needsNode(tempFile))
    }

    // MARK: - childEnvironment tests

    @Test func constructsPathWithExeDir() {
        let exe = URL(fileURLWithPath: "/usr/local/bin/claude")
        let env = CLIExecutableResolver.childEnvironment(
            for: exe,
            nodeDirectory: nil,
            base: [:],
            home: "/Users/me"
        )

        let pathComponents = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(pathComponents.first == "/usr/local/bin")
    }

    @Test func includesNodeDirWhenNeeded() {
        let exe = URL(fileURLWithPath: "/usr/local/bin/codex")
        let env = CLIExecutableResolver.childEnvironment(
            for: exe,
            nodeDirectory: "/opt/homebrew/bin",
            base: [:],
            home: "/Users/me"
        )

        let pathComponents = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(pathComponents.contains("/opt/homebrew/bin"))
        #expect(pathComponents[0] == "/usr/local/bin")
        #expect(pathComponents[1] == "/opt/homebrew/bin")
    }

    @Test func includesStandardDirs() {
        let exe = URL(fileURLWithPath: "/usr/local/bin/claude")
        let env = CLIExecutableResolver.childEnvironment(
            for: exe,
            nodeDirectory: nil,
            base: [:],
            home: "/Users/me"
        )

        let pathComponents = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(pathComponents.contains("/opt/homebrew/bin"))
        #expect(pathComponents.contains("/usr/local/bin"))
        #expect(pathComponents.contains("/Users/me/.local/bin"))
    }

    @Test func preservesExistingPathVars() {
        let exe = URL(fileURLWithPath: "/usr/local/bin/claude")
        let env = CLIExecutableResolver.childEnvironment(
            for: exe,
            nodeDirectory: nil,
            base: ["PATH": "/custom/path:/another/path"],
            home: "/Users/me"
        )

        let pathComponents = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(pathComponents.contains("/custom/path"))
        #expect(pathComponents.contains("/another/path"))
    }

    @Test func deduplicatesPathComponents() {
        let exe = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        let env = CLIExecutableResolver.childEnvironment(
            for: exe,
            nodeDirectory: nil,
            base: ["PATH": "/opt/homebrew/bin:/usr/local/bin"],
            home: "/Users/me"
        )

        let pathComponents = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        let homebrewCount = pathComponents.filter { $0 == "/opt/homebrew/bin" }.count
        #expect(homebrewCount == 1)
    }

    @Test func preservesOtherEnvironmentVars() {
        let exe = URL(fileURLWithPath: "/usr/local/bin/claude")
        let base: [String: String] = [
            "USER": "testuser",
            "HOME": "/home/testuser",
            "CUSTOM_VAR": "value",
        ]
        let env = CLIExecutableResolver.childEnvironment(
            for: exe,
            nodeDirectory: nil,
            base: base,
            home: "/Users/me"
        )

        #expect(env["USER"] == "testuser")
        #expect(env["HOME"] == "/home/testuser")
        #expect(env["CUSTOM_VAR"] == "value")
        #expect(env["PATH"] != nil)
    }

    // MARK: - Integration test (system probe)

    @Test func systemProbeFindsShCommon() async throws {
        // System should have /bin/sh.
        let result = try await CLIExecutableResolver.resolve(name: "sh", override: nil, probe: .system)
        #expect(result.path == "/bin/sh")
    }
}
