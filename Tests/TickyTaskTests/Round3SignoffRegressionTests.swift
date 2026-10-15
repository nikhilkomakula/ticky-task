import Foundation
import Testing
@testable import TickyTask

@Suite("Codex round-3 sign-off regressions", .serialized)
struct Round3SignoffRegressionTests {
    @Test func concatenatedCredentialNamesAreRejected() {
        for name in ["authtoken", "clientsecret", "sessiontoken", "refreshtoken", "accesskey", "privatekey", "apisecret", "authkey"] {
            let endpoint = "https://models.example/v1?\(name)=round3-opaque-query-secret"
            #expect(SummaryConnectionArguments.containsCredentials(endpoint), "Credential query: \(name)")
            #expect(throws: SummaryConnectionArguments.ValidationError.self) {
                try SummaryConnectionArguments.validatedBaseURL(endpoint)
            }
        }
    }

    @Test("Codex's 86-name matrix: every credential-like name is refused, ordinary names pass")
    func queryNameMatrix() {
        let refused = [
            "max_tokens",
            "token_count",
            "tokenizer",
            "password_policy",
            "secretary",
            "credential_type",
            "authtoken",
            "clientsecret",
            "sessiontoken",
            "refreshtoken",
            "accesskey",
            "privatekey",
            "apisecret",
            "token",
            "secret",
            "password",
            "passwd",
            "credential",
            "credentials",
            "apikey",
            "access_key",
            "private-key",
            "api_key",
            "apiKey",
            "APIKEY",
            "X-Api-Key",
            "access_token",
            "clientSecret",
            "sessionToken",
            "X-Amz-Security-Token",
            "X-Amz-Signature",
            "X-Goog-Credential",
            "Ocp-Apim-Subscription-Key",
            "key",
            "pwd",
            "auth",
            "authorization",
            "sig",
            "signature",
            "x-auth",
            "client_auth",
            "clientSignature",
            "%74oken",
            "api%5Fkey",
            "client%73ecret",
            "t_o_k_e_n",
            "p-a-s-s-w-o-r-d",
            "?token",
            "token[]",
            "key1",
            "pwd1",
            "auth1",
            "sig1",
            "signature1",
            "authorization1",
            "authkey",
            "AUTHKEY",
            "sharedkey",
            "subscriptionkey",
            "authentication",
            "authcode",
            "clientauthorization",
            "clientsignature",
            "oauth",
        ]
        let ordinary = [
            "author",
            "design",
            "monkey",
            "keep_alive",
            "tenant",
            "region",
            "api-version",
            "deployment",
            "route",
            "model",
            "organization",
            "project",
            "authorName",
            "designMode",
            "monkeyCount",
            "keyboard",
            "keynote",
            "authentication_method",
            "significant",
            "assignment",
            "author2",
            "design2",
        ]
        for name in refused {
            #expect(SummaryConnectionArguments.containsCredentials("https://models.example/v1?\(name)=x"), "\(name)")
        }
        for name in ordinary {
            #expect(!SummaryConnectionArguments.containsCredentials("https://models.example/v1?\(name)=x"), "\(name)")
        }
    }

    @Test func ordinaryQueryNamesStillPass() {
        for name in ["author", "design", "monkey", "keep_alive", "tenant", "region"] {
            #expect(!SummaryConnectionArguments.containsCredentials("https://models.example/v1?\(name)=x"), "\(name)")
        }
    }

    @Test func concatenatedCredentialCannotReachDefaultsBackupOrArguments() throws {
        let suite = "Round3Signoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SummaryPreferences(defaults: defaults)
        let secret = "round3-opaque-query-secret"
        for endpoint in ["https://models.example/v1?authtoken=\(secret)", "https://models.example/v1?authkey=\(secret)"] {
            preferences.localBaseURL = endpoint
            #expect(preferences.localBaseURL.isEmpty)
            #expect(defaults.string(forKey: "weeklySummary.local.baseURL") == nil)
            let backup = AppSettingsDTO.capture(from: defaults)
            let encoded = try JSONEncoder().encode(backup)
            #expect(!String(decoding: encoded, as: UTF8.self).contains(secret))
            AppSettingsDTO(weeklySummary: ["weeklySummary.local.baseURL": endpoint]).apply(to: defaults)
            #expect(defaults.string(forKey: "weeklySummary.local.baseURL") == nil)
            #expect(throws: SummaryConnectionArguments.ValidationError.self) {
                try SummaryConnectionArguments.codexArguments(
                    for: .local(server: .openAICompatible, baseURL: endpoint), hasAPIKey: false)
            }
        }
    }

    @Test func postExitDrainJoinsDescendantCleanupBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drain-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = #"""
        pipe(my $readReady, my $writeReady) or die;
        my $child = fork();
        defined $child or die;
        if ($child) {
            close $writeReady;
            read($readReady, my $ready, 1) == 1 or die;
            print "done";
            exit 0;
        }
        close $readReady;
        $SIG{TERM} = sub {
            $SIG{TERM} = "IGNORE";
            select undef, undef, undef, 0.2;
            open my $done, ">", "cleanup" or die;
            print $done "done";
            close $done;
            exit 0;
        };
        syswrite($writeReady, "r", 1) == 1 or die;
        close $writeReady;
        sleep 3;
        """#
        let runner = CLIProcessRunner(killGrace: .milliseconds(450), eofGrace: .milliseconds(50))
        let started = ContinuousClock.now
        let output = try await runner.run(CLIInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", command],
            workingDirectory: directory, environment: [:], timeout: .seconds(5)))
        #expect(output.exitCode == 0)
        #expect(output.stdoutText == "done")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cleanup").path),
                "The descendant's delayed TERM cleanup must exist immediately when run returns")
        #expect(started.duration(to: .now) >= .milliseconds(450),
                "run must join the scheduled escalation rather than return after closing its pipes")
    }

    @Test func cancelledRunJoinsDescendantCleanupBeforeThrowing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
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
        sleep 3;
        ' &
        wait
        """#
        let runner = CLIProcessRunner(killGrace: .milliseconds(450), eofGrace: .milliseconds(50))
        let task = Task {
            try await runner.run(CLIInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
                workingDirectory: directory, environment: [:], timeout: .seconds(5)))
        }
        let ready = directory.appendingPathComponent("ready")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        let cancelled = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect((error as? CLIProcessError) == .cancelled)
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cleanup").path),
                "Cancellation must finish descendant cleanup before throwing, without a post-return sleep")
        #expect(cancelled.duration(to: .now) >= .milliseconds(450))
    }
}
