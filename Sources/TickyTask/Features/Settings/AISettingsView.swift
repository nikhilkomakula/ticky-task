import SwiftUI
import AppKit

/// Settings › AI: how Weekly Summary connects to Codex (ChatGPT account, the
/// Codex CLI's own configuration, or a local model server), the user's custom
/// summary instructions, and where to find the `codex` executable.
struct AISettingsView: View {
    @State private var instructions = SummaryPreferences().customInstructions

    private var generator: SummaryGenerating { WeeklySummaryDependencies.make().generator }

    var body: some View {
        Form {
            Section {
                SummaryConnectionForm(
                    accountStatus: { await generator.accountStatus() },
                    signIn: { try await generator.signIn() }
                )
            } header: {
                Text("Codex connection")
            }

            Section {
                SummaryInstructionsEditor(instructions: $instructions)
                    .onChange(of: instructions) { _, value in SummaryPreferences().customInstructions = value }
            } header: {
                Text("Weekly Summary instructions")
            }

            Section {
                CodexPathRow()
            } header: {
                Text("Codex CLI")
            } footer: {
                Text("Weekly Summary runs your locally installed Codex CLI. Leave the path empty to search the usual install locations. “Check” confirms Codex can be found and started — it does not verify your sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The Weekly Summary sheet can change these too; refresh when Settings regains focus.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            let saved = SummaryPreferences().customInstructions
            if instructions != saved { instructions = saved }
        }
    }
}

private struct CodexPathRow: View {
    @State private var path = SummaryPreferences().cliPathOverride ?? ""
    @State private var status: String?
    @State private var isChecking = false
    @State private var statusIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Automatic", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityIdentifier("ai-path-codex")
                Button("Browse…", action: browse)
                Button("Check", action: check)
                    .disabled(isChecking)
            }
            if isChecking {
                ProgressView().controlSize(.small)
            } else if let status {
                Label(status, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .orange : .green)
                    .textSelection(.enabled)
            }
        }
        .onChange(of: path) { _, _ in save() }
    }

    private func save() {
        SummaryPreferences().cliPathOverride = path
        status = nil
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the codex executable"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            save()
        }
    }

    private func check() {
        save()
        isChecking = true
        let override = SummaryPreferences().cliPathOverride
        Task {
            defer { isChecking = false }
            do {
                let executable = try await CLIExecutableResolver.resolve(name: "codex", override: override, probe: .system)
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let output = try await CLIProcessRunner().run(CLIInvocation(
                    executableURL: executable, arguments: ["--version"],
                    workingDirectory: FileManager.default.temporaryDirectory,
                    environment: CLIChildEnvironment.make(for: executable, home: home),
                    timeout: .seconds(15), stdoutLimit: 16 * 1024
                ))
                let version = output.stdoutText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                statusIsError = !output.succeeded
                status = output.succeeded
                    ? "Found \(executable.path)\(version.isEmpty ? "" : " — \(version)")"
                    : "\(executable.path) exited with status \(output.exitCode.map(String.init) ?? "?")."
            } catch CLIResolutionError.invalidOverride(let bad) {
                statusIsError = true
                status = "“\(bad)” is missing or not executable."
            } catch is CLIResolutionError {
                statusIsError = true
                status = "Codex CLI not found. Install it (e.g. `brew install codex`) or choose its executable."
            } catch {
                statusIsError = true
                status = "Couldn't start it: \(error.localizedDescription)"
            }
        }
    }
}
