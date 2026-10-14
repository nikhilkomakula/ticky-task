import SwiftUI
import AppKit

/// Settings › AI: where to find the `claude` / `codex` CLIs used by Weekly
/// Summary. Paths are optional — TickyTask searches the usual install locations.
struct AISettingsView: View {
    var body: some View {
        Form {
            Section {
                CLIPathRow(provider: .claude)
                CLIPathRow(provider: .codex)
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Weekly Summary runs your locally installed Claude Code or Codex CLI, using its own sign-in and provider settings. Leave a path empty to search the usual install locations. “Check” confirms the CLI can be found and started — it does not verify your sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CLIPathRow: View {
    let provider: SummaryProvider
    @State private var path = ""
    @State private var status: String?
    @State private var isChecking = false
    @State private var statusIsError = false

    private var preferences: SummaryPreferences { SummaryPreferences() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.cliName)
                Spacer()
                TextField("Automatic", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(save)
                    .accessibilityIdentifier("ai-path-\(provider.rawValue)")
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
        .onAppear { path = preferences.cliPathOverride(for: provider) ?? "" }
        .onChange(of: path) { _, _ in save() }
    }

    private func save() {
        preferences.setCLIPathOverride(path, for: provider)
        status = nil
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(provider.executableName) executable"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            save()
        }
    }

    private func check() {
        save()
        isChecking = true
        let provider = provider
        let override = preferences.cliPathOverride(for: provider)
        Task {
            defer { isChecking = false }
            do {
                let executable = try await CLIExecutableResolver.resolve(name: provider.executableName,
                                                                         override: override, probe: .system)
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
                status = "\(provider.cliName) not found. Install it or choose its executable."
            } catch {
                statusIsError = true
                status = "Couldn't start it: \(error.localizedDescription)"
            }
        }
    }
}
